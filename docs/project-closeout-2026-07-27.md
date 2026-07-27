# ZX7981PD 项目收口与归档记录

日期：2026-07-27（Asia/Shanghai）<br>
状态：离线开发与环境配置阶段收口<br>
收口与归档：[Codex@gpt-5.6-sol]

> 本文记录的是 2026-07-27 10:27 建立 `archive-2026-07-27` 标签时的历史状态。
> 此后已完成 r1 真机安装与读取验证，并在当前主线生成、离线核验
> `artifacts/0.1.0-r2/`。最新状态以 `HANDOFF.md` 为准；本文的“已知验收边界”
> 不应再作为当前项目结论引用。前轮虚拟化失败记录的更正与恢复证据见
> `docs/build-environment-recovery-2026-07-27.md`。

## 归档范围

本次归档覆盖：

- ZX7981PD通用短信中心源码、LuCI页面、ACL、翻译和测试；
- OpenWrt 25.12.5 mediatek/filogic SDK编译产物；
- 离线包校验、构建环境和待真机验证清单；
- Windows虚拟化环境与性能对比记录；
- ZX OpenClash、Mihomo小闪存启动方案及Antigravity分流记录；
- Git历史、Agent署名规则和离线恢复包。

归档标签：

```text
archive-2026-07-27
```

该标签是本轮收口状态的权威Git入口。

## 已完成

### 短信中心

- `modem-smsd`、`luci-app-modem-sms`和简体中文包编译成功；
- 三个APK的SHA-256与`artifacts/0.1.0-r1/SHA256SUMS`一致；
- 静态检查通过：2个JSON文件、85条翻译及包不变量；
- 离线包结构、依赖、权限和目标架构验证通过；
- 构建环境、日志、回滚说明和真机清单已归档。

### 开发环境

- BIOS硬件虚拟化和Windows Hypervisor Platform已启用；
- QEMU通过WHPX成功启动Alpine Linux；
- 同一冷编译样本从TCG的231.23秒降至WHPX的15.97秒；
- 当前QEMU、Alpine虚拟磁盘和SDK环境保留在Git忽略的`.build-temp`中。

### ZX OpenClash

- OpenClash已启用并开机自启；
- PassWall2已停止、禁用且无残留进程；
- 主策略为`♻️ 自动选择 - JP`；
- `openAI`固定为`SG - 新加坡 01`；
- Antigravity、AIDA和Gemini域名统一命中`openAI`；
- Mihomo持久压缩缓存和冷启动准备服务验证通过；
- 临时SSH公钥已撤销，本地临时私钥及订阅副本已删除。

## 已知验收边界

以下事项不属于本轮“已验证完成”，后续恢复开发时必须继续：

1. 三个短信APK尚未在ZX上实际安装。
2. `procd`、`ubus`、LuCI页面、ACL及短信收取、解码、发送和删除仍待真机测试。
3. OpenClash配置后尚未执行整机断电重启。
4. Windows默认网络仍为P2 Wi-Fi，尚未完成以ZX为默认网关的Antigravity真实应用验收。
5. APK尚未接入正式签名仓库，受控真机安装可能需要本地不受信任包流程。

不得将“离线构建通过”表述为“真机发布验收通过”。

## 恢复入口

### 源码与Git

本地仓库：

```text
D:\Projects\ZX7891PD 优化
```

离线Git bundle保存在Git忽略的`.device-backups`目录。恢复示例：

```powershell
git clone .\ZX7891PD-archive-2026-07-27.bundle ZX7891PD-恢复
```

恢复后以`archive-2026-07-27`标签核对收口版本。

### ZX设备配置

设备侧备份：

```text
/root/codex-backups/openclash-preconfig-20260727-020355
```

电脑侧敏感备份：

```text
.device-backups/zx-openclash-preconfig-20260727-020355.tar.gz
```

设备备份SHA-256：

```text
607930187975a75fca04eac623c3009d8839facb979ca8fd34847700bb8a659f
```

电脑侧备份包含设备配置和认证材料，不得提交、分享或放入公共云盘。

## 后续启动顺序

恢复开发时按以下顺序执行：

1. 检查`git status`和`archive-2026-07-27`标签。
2. 阅读`VERIFY-ZX7981PD-PENDING.txt`和本收口记录。
3. 下载ZX最新系统备份并确认回滚路径。
4. 核对固件版本、目标架构和可用空间。
5. 受控安装APK并保存完整真机验证日志。
6. 单独安排OpenClash计划内重启验收。
7. 真机全部通过后再建立正式发布标签。

## 安全状态

- Git不跟踪`.build-temp`、`.device-backups`、私钥或订阅副本；
- 未发现项目跟踪文件中包含私钥、密码、Token或订阅URL；
- 当前没有项目创建的临时SSH授权；
- 当前归档只是本地Git和本地bundle，尚未配置远程仓库。
