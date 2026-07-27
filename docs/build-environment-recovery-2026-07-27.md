# 构建环境恢复与前轮虚拟化失败说明

日期：2026-07-27（Asia/Shanghai）  
恢复与复核：[Codex@gpt-5.6-sol]

## 结论

前轮交接中“QEMU 虚拟化不可用、WHPX/TCG 均失败”的描述，只适用于当时未能
复现构建流程的会话，不能解释为本机虚拟化能力、QEMU 或
`.build-temp/alpine-build.qcow2` 已永久失效。

本轮已在同一 Windows 宿主上通过 QEMU WHPX 多次启动 Alpine Linux 3.23，
完成 OpenWrt SDK 的 ADB v3 打包，并生成、验证 `0.1.0-r2` 包组。因此原阻断
结论已被后续实测推翻。

## 证据

### 历史证据

- `docs/virtualization-benchmark-2026-07-26.md` 已记录同一 qcow2 在 TCG 和
  WHPX 下均成功完成冷编译；
- TCG 的 `BENCH_BUILD_RC=0`，耗时 231.23 秒；
- WHPX 的 `BENCH_BUILD_RC=0`，耗时 15.97 秒；
- `docs/development-environment-foundation-2026-07-26.md` 已记录
  `HypervisorPresent=True` 和 WHPX 引导 Alpine 至登录提示。

### 本轮证据

- QEMU `-accel whpx` 成功引导 Alpine Linux 3.23；
- 基础 qcow2 以 `snapshot=on` 挂载，构建没有改写基础虚拟磁盘；
- OpenWrt SDK 成功调用 apk-tools 3.0.5 生成三个 ADB v3 APK；
- `apk --allow-untrusted verify` 对三个包均返回 `OK`；
- `apk adbdump`、`apk extract` 和关键修复内容检查全部通过；
- 完整构建与离线核验记录已归档到 `artifacts/0.1.0-r2/`。

## 前轮失败的合理解释

前轮没有保存可复现的完整 QEMU 命令和对应失败日志，因此不能对每一次失败给出
唯一根因。结合本轮复现过程，可以确认问题集中在启动和构建编排，而非虚拟化
能力本身。

### 1. Windows 路径与 QEMU 固件搜索

仓库路径包含中文。Windows 版 QEMU、Git Bash 路径转换和 BIOS/固件搜索组合
使用时，可能出现路径解析不一致。本轮通过把仓库映射为 `Q:`，并显式指定
QEMU `share` 固件目录，稳定避开了该问题。

把文件复制到 Git Bash 的 `/tmp/...` 并不能自动保证 Windows 版 QEMU 能以
相同语义解释该路径，因此“复制到 `/tmp` 后仍失败”不是虚拟化失效证据。

### 2. Alpine Live 环境缺少 loopback 初始化

首次恢复构建时，SDK 已正常运行到 `apk mkpkg`，但 `fakeroot` 报：

```text
libfakeroot: connect: Network is unreachable
```

这不是外网、ADB v3 或 QEMU 故障，而是 Alpine Live 环境的 loopback 接口尚未
启用。执行 `ip link set lo up` 后，`fakeroot` 和 ADB v3 打包立即恢复。

### 3. QEMU 虚拟 FAT 交换盘使用方式

虚拟 FAT 实际以分区设备出现，应优先挂载 `/dev/vdb1`，而不是固定假设
`/dev/vdb` 可以直接挂载。

此外，持续把大体积构建日志写入 QEMU 虚拟 FAT 会造成不稳定。本轮改为先把
日志写入 Linux 磁盘，构建结束后再一次性复制 APK、日志和校验和到交换盘。

### 4. SDK 中 LuCI 的实际源路径

该 SDK 实际从以下位置选择 LuCI 包：

```text
feeds/luci/applications/luci-app-modem-sms
```

只把源码复制到 SDK 的 `package/luci-app-modem-sms` 不会替换被选中的 feed
包，会继续生成旧前端。同步到真实 feed 路径后，LuCI 正确生成
`luci-app-modem-sms-0.1.0-r2.apk`。

## SDK 与 ADB v3 的准确边界

- Windows 可以保存并使用工具解压 `.tar.zst`；
- SDK 内的 Linux x86_64 ELF 工具链不能由原生 Windows/Git Bash 可靠执行；
- ADB v3 不是构建阻断，Linux SDK 内的 apk-tools 可以正常生成和验证；
- Windows 上缺少 apk-tools 只会阻止手工重打包，而正式发布本来也不应依赖
  手工拼包。

因此，准确表述应为：

> 正式构建需要 Linux 执行环境；本机已有可工作的 QEMU WHPX Alpine 构建路径。
> 前轮失败属于构建编排未复现，不属于虚拟化永久失效。

## 当前收口状态

- 构建环境：已恢复；
- r2 SDK 构建：已完成；
- r2 ADB v3 离线核验：已完成；
- r2 真机安装：待执行；
- LuCI HTTP RPC、页面渲染及发送/删除真机回归：待执行；
- 正式发布标签：真机验收通过前不建立。
