# ZX7981PD 开发与测试基础环境优化评估

日期：2026-07-26（Asia/Shanghai）

## 结论

这台电脑适合长期承担 ZX7981PD/OpenWrt 开发。当前最大的短板不是 CPU、内存、
磁盘或模型，而是固件虚拟化未开启、WSL2 尚未安装、项目尚未纳入 Git，以及
构建和设备验收还没有完全自动化。

建议采用以下稳定主线：

1. 开启 AMD-V，安装稳定版 WSL2 和 Debian。
2. 源码继续由 Windows/Codex 管理，但把 SDK、`build_dir`、`staging_dir`、
   `dl` 和编译缓存放在 WSL 的 Linux 文件系统中。
3. 使用官方 OpenWrt SDK、固定 SHA-256 和 feed commit；用脚本一键生成 APK、
   日志、校验和与元数据。
4. 使用 Git 和 Linux CI 做第二个独立构建源。
5. 建立专用设备测试网络、串口恢复能力、外部备份和可重复验收脚本。

WSL Container 公测版可以作为后续实验项，但目前不应成为正式构建的唯一依赖。
稳定 WSL2 已经足以显著改善 SDK 构建。

## 本机实测基线

| 项目 | 当前状态 | 判断 |
|---|---|---|
| 电脑 | ThinkPad P16v Gen 1，Type 21FE | 合适 |
| CPU | Ryzen 5 7640HS，6 核 12 线程 | 支持 AMD-V、SLAT |
| 内存 | 27.7 GiB | 足够 |
| 固件虚拟化 | BIOS 已开启，Windows Hypervisor 已运行 | 已完成 |
| BIOS | N3VET65W 1.65 | 已是联想当前版本，不需升级 |
| Windows | Windows 11 Pro 25H2，26200.8894 | 满足 WSL2 |
| 系统盘 | 512 GB NVMe，约 376 GB 可用 | 正常 |
| 数据盘 | 2 TB NVMe，约 1.77 TB 可用 | 正常 |
| TRIM | NTFS/ReFS 均启用 | 正常 |
| 网络 | Wi-Fi 6E + Realtek USB 千兆网卡 | 可建立专用设备链路 |
| WSL | 启动器存在，组件/发行版未安装 | 待安装 |
| Docker/Podman | 未安装 | 当前并非必需 |
| Git | 2.55.0；系统 `core.autocrlf=true` | 需由仓库属性覆盖 |
| Windows 长路径 | 已启用 | 正常 |
| Defender | 实时、行为、下载扫描及防篡改均启用 | 保持开启 |
| 当前 QEMU | WHPX 硬件加速冒烟测试通过 | 可作为当前主构建环境 |

2026-07-26 18:23 复核：`VirtualizationFirmwareEnabled=True`、
`HypervisorPresent=True`，QEMU 的 `whpx` 后端成功引导 Alpine Linux 3.23
至登录提示。冒烟测试仅从只读 ISO 启动，未挂载或写入现有构建虚拟磁盘。

同日 A/B 实测显示，LuCI `csstidy` 冷编译由 TCG 的 231.23 秒降至 WHPX 的
15.97 秒，WHPX 加速 14.48 倍、耗时减少 93.1%。详见
[`virtualization-benchmark-2026-07-26.md`](virtualization-benchmark-2026-07-26.md)。

联想发布页确认 1.65 是 Type 21FE/21FF 当前 BIOS：
[ThinkPad P16v Gen 1 BIOS 1.65](https://pcsupport.lenovo.com/id/en/downloads/ds565314)。

## P0：一次重启内完成

### 1. 开启 AMD-V

操作前先确认 BitLocker/设备加密恢复密钥已安全保存在本机磁盘之外。固件或启动
环境变化可能触发恢复；微软建议对非 Windows 渠道的固件变更先准备恢复能力：
[BitLocker 恢复流程](https://learn.microsoft.com/en-us/windows/security/operating-system-security/data-protection/bitlocker/recovery-process)。

建议步骤：

1. 接通电源，关闭正在写盘的程序。
2. 重启，在 Lenovo 标志出现时按 `F1`。
3. 在 `Security`/`Virtualization` 下找到 AMD 虚拟化选项（联想命名通常为
   `AMD V(TM) Technology`），设为 Enabled。
4. `F10` 保存退出。
5. 回到 Windows 后检查任务管理器“虚拟化：已启用”，并再次检查
   `VirtualizationFirmwareEnabled=True`。

联想的 ThinkPad BIOS 参考说明 AMD 平台对应 AMD-V：
[Lenovo ThinkPad Virtualization settings](https://docs.lenovocdrt.com/ref/bios/settings/thinkpad/virtualization/)。

### 2. 安装稳定版 WSL2

在管理员 PowerShell 中安装 Debian；按提示重启：

```powershell
wsl --install -d Debian
wsl --update
wsl --set-default-version 2
wsl --list --verbose
```

WSL2 需要 `Windows Subsystem for Linux` 和 `Virtual Machine Platform` 两个组件，
并依赖 BIOS 虚拟化。微软当前推荐 `wsl --install`：
[安装 WSL](https://learn.microsoft.com/en-us/windows/wsl/install)、
[WSL2 FAQ](https://learn.microsoft.com/en-us/windows/wsl/faq)。

Debian 首次启动后使用普通用户构建，不用 root 运行 SDK。按 OpenWrt 25.xx 的
Debian/Trixie依赖清单安装工具：
[OpenWrt build system setup](https://openwrt.org/docs/guide-developer/toolchain/install-buildsystem)。

### 3. 设定 WSL 资源边界

建议从以下 `%UserProfile%\.wslconfig` 起步：

```ini
[wsl2]
memory=12GB
processors=8
swap=8GB
networkingMode=mirrored
dnsTunneling=true
firewall=true

[experimental]
autoMemoryReclaim=gradual
sparseVhd=true
```

应用配置：

```powershell
wsl --shutdown
```

说明：

- 12 GB/8 线程给 OpenWrt 包编译留足余量，同时给 Windows/Codex 保留资源。
- mirrored 网络有 IPv6、组播、VPN 兼容和 localhost 互通优势，适合发现和访问
  局域网设备；若特定 VPN/网卡出现回归，退回默认 NAT。
- 不创建“允许所有入站”的 Hyper-V 防火墙规则；仅在实际需要服务入站时按端口
  建规则。
- `sparseVhd` 主要影响新建 VHD；仍应定期备份而不是依赖稀疏盘本身。

参考：
[WSL 高级配置](https://learn.microsoft.com/en-us/windows/wsl/wsl-config)、
[WSL mirrored networking](https://learn.microsoft.com/en-us/windows/wsl/networking)。

## P1：构建环境一次性标准化

### 1. Linux 文件系统布局

不要在 `/mnt/d/...` 内展开和编译 OpenWrt SDK。推荐：

```text
/home/<user>/zx7981pd/
  src/                  # 从 Windows 工作区导出的源码快照或 Git clone
  sdk/25.12.5-filogic/  # SDK、build_dir、staging_dir
  cache/dl/             # 下载缓存
  out/                  # APK、日志、SHA256SUMS
```

Windows 工作区可继续作为编辑入口，但构建脚本应把小体积源码同步到 WSL ext4
后再运行。微软明确建议 Linux 命令行工作负载把文件放在 Linux 文件系统，而非
`/mnt/c`/`/mnt/d`：
[WSL 文件系统性能建议](https://learn.microsoft.com/en-us/windows/wsl/filesystems)。

### 2. 固定构建输入

脚本必须固定并核验：

- OpenWrt `25.12.5`、`mediatek/filogic` SDK 文件名；
- SDK SHA-256：
  `ff4a38a397caa2cfe1c39e18f84ddede14878221b3593c3f2c4cfe24e3ec4c25`；
- OpenWrt/base、packages、LuCI feed commit；
- 包版本、release、构建命令和并行度；
- 产物 APK、完整日志、`SHA256SUMS`、构建环境与源代码 commit。

OpenWrt 官方要求二进制包由 Buildroot/SDK 从包定义生成，反对手工拼包：
[OpenWrt package policy](https://openwrt.org/docs/guide-developer/package-policies)。

### 3. 缓存策略

优先级从高到低：

1. 保留已准备好的 SDK/`staging_dir/host*`，避免每次重编主机工具。
2. 持久化 `dl` 下载缓存，并以 SDK 版本和目标架构隔离。
3. 启用 `ccache`；修改频繁的 C/C++ 依赖会受益，但本项目自身主要是 ucode、
   JavaScript 和静态资源，收益小于前两项。
4. 不缓存密钥、设备备份、短信数据或访问令牌。

### 4. 版本控制与换行

当前目录还不是 Git 仓库，而系统 Git 默认 `core.autocrlf=true`。这会给 shell、
Makefile、ucode 和 LuCI 文件带来换行风险。项目已新增：

- `.gitattributes`：Linux/Makefile 文件强制 LF，APK/压缩包标记为 binary；
- `.gitignore`：排除 VM、SDK 下载、私钥和本地临时文件；
- `.editorconfig`：统一 UTF-8、换行和 Makefile tab。

下一步应初始化 Git，默认分支使用 `main`，完成一次基线提交，并至少配置一个
异机远端备份。`.gitattributes` 比依赖每台电脑的 `core.autocrlf` 更可靠：
[Git gitattributes](https://git-scm.com/docs/gitattributes)。

### 5. 第二构建源与供应链记录

建议 Git 远端建立 Linux CI：

- 对每次 push/PR 运行静态测试；
- 下载并验证固定 SDK 哈希；
- 构建三个 APK；
- 保存 APK、日志、环境清单和 `SHA256SUMS` 为 workflow artifacts；
- 缓存 `dl`，缓存键包含 SDK 哈希和 feed commits；
- 发布构建可增加 artifact attestation。

GitHub 明确区分缓存（可再生依赖）和产物（APK/日志），也提醒缓存不可存敏感
信息：
[Actions dependency caching](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching)、
[Workflow artifacts](https://docs.github.com/en/actions/concepts/workflows-and-actions/workflow-artifacts)、
[Artifact attestations](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations)。

正式分发时再建立私有 APK repository、离线保管签名私钥并发布签名索引。当前
自编 APK 的直接设备测试继续显式使用 `--allow-untrusted`，这符合 OpenWrt
25.12 的本地包说明：
[OpenWrt apk guide](https://openwrt.org/docs/guide-user/additional-software/apk)。

## P2：设备测试实验台

### 1. 专用网络

本机已有 USB 千兆网卡，可将它专用于 ZX7981PD：

- 路由器测试口与该网卡直连或通过独立小交换机连接；
- 使用单独的 RFC1918 子网和固定地址；
- 不启用 Windows 网络桥接或 Internet Connection Sharing；
- Wi-Fi 保留为互联网下载路径，设备测试流量走有线；
- 只为测试子网建立最小防火墙规则，不把 LuCI/SSH 暴露到公共网络。

### 2. 恢复与断电保护

在做固件级工作前准备：

- 经确认是 3.3 V 电平且 pinout 正确的 USB-TTL 串口线；
- 串口启动日志采集；
- 确认 ZX7981PD 实际 U-Boot/TFTP 恢复方法后再配置 TFTP；
- 设备外保存配置备份、包清单、分区布局与校验和；
- 有条件时使用 UPS 或可控电源，但禁止在写 flash 时强制断电。

TFTP/串口恢复依赖具体 bootloader，不能仅凭同 SoC 经验猜测：
[OpenWrt TFTP recovery](https://openwrt.org/docs/guide-user/troubleshooting/tftpserver)、
[OpenWrt recovery methods](https://openwrt.org/docs/guide-user/installation/recovery_methods/start)。

### 3. 测试身份与日志

- 为路由器测试使用一次性 SSH key；验收结束撤销并删除。
- 首次连接记录并人工核对 SSH host key 指纹，避免长期使用
  `StrictHostKeyChecking=no`。
- 使用专用测试 SIM、明确的接收手机和发送额度，避免误发和费用失控。
- 日志默认脱敏号码、短信正文、IMSI/IMEI、IP 和令牌。
- 保存 `logread`、ubus 响应、包清单、配置哈希、网络基线和测试时间戳。
- 长稳测试可把日志发送到开发机；OpenWrt 默认 RAM ring buffer 重启即丢：
  [OpenWrt logging](https://openwrt.org/docs/guide-user/base-system/log.essentials)。
- 网络回归可从路由器把 pcap 流式传给开发机分析：
  [OpenWrt tcpdump/Wireshark](https://openwrt.org/docs/guide-user/firewall/misc/tcpdump_wireshark)。

### 4. WSL USB 接入（按需）

如果后续需要在 Linux 中直接使用 USB-TTL、USB 恢复设备或烧录器，可安装
`usbipd-win`。它不是本轮 SDK 编译的前置条件；安装后应收紧其默认本地子网
防火墙范围：
[Microsoft WSL USB guide](https://learn.microsoft.com/windows/wsl/connect-usb)。

## 不建议现在做

- 不把 WSL Container 公测版设为唯一构建环境。
- 不安装 Docker Desktop；当前需求用 WSL2 直接构建更简单。
- 不把整个 `D:\Projects` 加入 Defender 排除项。
- 不关闭 Windows Firewall、Defender、Secure Boot 或 TPM。
- 不将 2 TB 的 D 盘整体改成 Dev Drive/ReFS。
- 不使用 `apk upgrade` 更新整台路由器。OpenWrt 25.12 的官方迁移说明警告，
  盲目整机包升级可能破坏系统：
  [OpenWrt opkg-to-apk cheat sheet](https://openwrt.org/docs/guide-user/additional-software/opkg-to-apk-cheatsheet)。
- 不在尚未确认分区布局与恢复路径时刷固件或读取/写入猜测的 MTD 分区。

Dev Drive 只适合 Windows 原生源码、缓存和中间文件。微软说明 WSL Linux 构建
仍应使用 WSL VHD 内文件系统，而且 Dev Drive 的 ReFS 不支持 WSL `metadata`
挂载选项。因此本机当前 NTFS D 盘和充足空间无需为本项目改造：
[Microsoft Dev Drive](https://learn.microsoft.com/en-us/windows/dev-drive/)。

## 建议执行顺序与时间

| 阶段 | 工作 | 预计人工时间 |
|---|---|---:|
| A | 恢复密钥确认、开启 AMD-V、安装/更新 WSL2 Debian | 30–60 分钟 |
| B | 安装 OpenWrt 依赖、配置 `.wslconfig`、迁移 SDK 与缓存 | 45–90 分钟 |
| C | 固化一键构建、离线验包、产物清单和 WSL 导出备份 | 2–4 小时 |
| D | Git 基线、远端和 Linux CI/attestation | 2–4 小时 |
| E | 专用网、串口/TFTP 恢复、测试 SIM 与日志接收 | 半天，取决于硬件 |

其中 A+B 是最高回报的一次性改造；C+D 会让后续模型强度和人工经验对“能否
稳定构建”的影响显著下降；E 是连接 ZX7981PD 后降低测试与回滚风险的关键。
