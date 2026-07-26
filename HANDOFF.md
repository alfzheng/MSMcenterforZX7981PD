# ZX7981PD 通用短信中心：工作交接

存档时间：2026-07-21（Asia/Shanghai）

## 当前结论

- 源代码实现：**GO**
- ZX7981PD 源码与集成实测：**GO**
- 正式 APK 部署：**NO-GO**

正式部署唯一未关闭的门禁是：尚未通过 OpenWrt 25.12.5 `mediatek/filogic` 官方 SDK 生成并核验：

- `modem-smsd-*.apk`
- `luci-app-modem-sms-*.apk`
- `SHA256SUMS`

不得手工拼装 APK，也不得把源码复制测试当成正式安装。

## 已完成工作

### 代码修复

- 拒绝 `CMGL` 返回中的非法或重复物理索引，防止逻辑短信映射到错误记录。
- 冷缓存 `get` 会先加载存储，不再错误返回 `MESSAGE_NOT_FOUND`。
- 修复 6/7 位号码脱敏区间重叠泄露。
- `analyse` 增加 8192 字符上限。
- CLI 拒绝未知、重复、缺值及越界参数，并在无服务时也能先返回参数错误。
- UCI 后端配置不再硬编码为 `lteat` section。
- 修复目标 ucode 无法解析动态拼接 `require()` 的问题：先对白名单后端名校验，再通过绝对路径 `loadfile()` 加载适配器。

核心文件：

- `packages/modem-smsd/files/usr/sbin/modem-smsd`
- `packages/modem-smsd/files/usr/bin/modem-smsctl`
- `packages/modem-smsd/files/usr/share/modem-sms/core.uc`
- `packages/modem-smsd/files/usr/share/modem-sms/backend-lteat.uc`

### 测试与安全验证

- `tests/static.ps1`：PASS（2 个 JSON、85 条翻译和包不变量）。
- `tests/frontend-storage.js`：PASS。
- ZX7981PD `tests/core.uc`：PASS。
- ZX7981PD `tests/backend.uc`：PASS。
- CLI 编译及非法参数：PASS；未知/缺值参数返回 `INVALID_ARGUMENT`、退出码 2。
- `tests/daemon-integration.sh`：目标机真实 `modem-smsd + ubus` 运行 **12/12 PASS**，使用 fake backend，没有真实短信发送。
- `tests/daemon-live-read.sh`：真实 `lteat` 只读 PASS，`SM=true`、`ME=true`、`stale=false`、存在短信记录；没有发送或删除，但读取可能把未读状态改为已读。

12 项 daemon 测试覆盖冷 list/get、单存储失败、并发容量预留、终态重启、正常 purge、`SUBMIT_UNKNOWN`、接受后 `kill -9`、第二分段中途崩溃、删除客户端断线后重试同一删除验证锁释放，以及 purge 中断恢复和发送封锁。

最后一轮审计结论：代码 GO、目标机实测 GO；未发现残留 P0/P1。正式部署仅因 APK 与哈希缺失保持 NO-GO。

详细证据：

- `docs/test-report-2026-07-21.md`
- `docs/deployment-and-rollback.md`
- `docs/rollback.md`
- `docs/development.md`

## 设备与密钥清理状态

- 设备 `/tmp/modem-sms-audit-20260721` 已删除。
- 设备 `/etc/config/modem-sms`、`/usr/share/modem-sms` 测试路径均已确认不存在。
- 两个 Codex 临时 SSH 公钥注释均不在 LuCI 公钥列表中。
- 公钥撤销后 SSH 复验返回 255：`Permission denied (publickey,password)`。
- 本地临时私钥、公钥和 `.codex-temp-ssh-20260721` 目录已删除。
- 设备未正式安装本项目。

如继续做目标机核验，需要重新生成一次性密钥、由用户登录 LuCI 后添加，结束时重复上述清理流程。

## APK 构建准备进度

已确认官方 SDK 文件名：

`openwrt-sdk-25.12.5-mediatek-filogic_gcc-14.3.0_musl.Linux-x86_64.tar.zst`

官方 `sha256sums` 中的 SDK 哈希：

`ff4a38a397caa2cfe1c39e18f84ddede14878221b3593c3f2c4cfe24e3ec4c25`

当前 Windows 没有可用的 WSL 发行版、Docker、VirtualBox 或已安装 QEMU，且固件虚拟化未启用。因此开始准备一个完全放在工作目录、使用 TCG 软件模拟的临时 Alpine Linux 构建环境。

`.build-temp` 当前包含：

| 文件 | 大小 | 状态 |
|---|---:|---|
| `qemu-setup.exe` | 198,897,616 bytes | 已下载，未安装/未执行；来源为 QEMU 官网链接的 Stefan Weil Windows build |
| `alpine.iso` | 71,303,168 bytes | Alpine virt 3.23.5 x86_64；SHA-256 已验证 |
| `alpine.iso.sha256` | 96 bytes | 官方校验文件 |
| `sdk.sha256sums` | 253,863 bytes | OpenWrt 25.12.5 filogic 官方清单 |

Alpine ISO SHA-256，期望值与实算值一致：

`06df31436dc9ada6330a3d2ee561a70143569e9d1896627c2138c0c9fb4c9a76`

尚未完成：

- QEMU 安装器真实性/发布来源的进一步记录与安装。
- OpenWrt SDK 下载及 SHA-256 核验。
- Alpine/QEMU 临时 VM 启动。
- SDK 构建、APK 导出与目标机验证。

## 建议续作步骤

1. 在继续之前重新检查 `.build-temp` 文件大小与哈希，不信任中断前的进程状态。
2. 将 QEMU 安装到工作区内的临时目录，不写入系统级默认路径；若安装器无法可靠隔离，停止并改用经用户批准的 Linux/GitHub Actions 构建环境。
3. 使用 Alpine VM 的 TCG 模式和临时虚拟磁盘；不要依赖 WHPX，因为固件虚拟化显示为关闭。
4. 在 VM 内从 OpenWrt 官方地址下载 SDK并验证：

   ```text
   ff4a38a397caa2cfe1c39e18f84ddede14878221b3593c3f2c4cfe24e3ec4c25
   ```

5. 将 `packages/modem-smsd` 放入 SDK 的自定义 package 目录。
6. LuCI 包的 Makefile 使用 `include ../../luci.mk`。必须把 `packages/luci-app-modem-sms` 放入具有完整 LuCI feed 结构的位置（例如更新官方 25.12 LuCI feed后置于其 `applications/` 下），不能直接放在 SDK 根 `package/` 后假设 `luci.mk` 存在。
7. 执行 SDK 包编译并保存完整日志：

   ```sh
   make defconfig
   make package/modem-smsd/compile V=sc
   make package/luci-app-modem-sms/compile V=sc
   find bin -type f -name '*.apk'
   ```

   实际 make target 以 SDK 中生成的 package 路径为准；如目标名不同，先用 `make menuconfig` 或 `make info` 核实，不要盲目修改源码。

8. 只把两个本项目 APK复制到 `artifacts/0.1.0-r1/`，生成 `SHA256SUMS`、SDK 清单、构建日志和源代码哈希。
9. 先在目标机执行 `apk verify`、`apk adbdump` 和 `apk extract`。检查包名、版本、架构、依赖、文件路径、权限、init 脚本、ACL、菜单及 conffile。
10. 在安装前按 `docs/deployment-and-rollback.md` 把系统备份下载到路由器之外。
11. 临时安装两个 APK，运行只读验收、LuCI 页面检查和 CLI 检查；完成卸载回滚并验证服务、ubus、菜单、ACL、动态日志与配置残留。
12. 安装/卸载证据全部通过后，再做一次最终短审计；未经用户明确指示，不要把测试安装保留为正式部署。

## 交付物完成定义

最终目录至少应包含：

```text
artifacts/0.1.0-r1/
  modem-smsd-*.apk
  luci-app-modem-sms-*.apk
  SHA256SUMS
  BUILD-ENVIRONMENT.txt
  BUILD.log
  VERIFY-ZX7981PD.log
```

验收必须证明：

- APK 哈希可重复核对。
- `apk verify/adbdump/extract` 全部成功。
- 安装后 `modem.sms` 正常、CLI 与 LuCI 可用。
- 卸载后 init、ubus、菜单、ACL 和包文件消失。
- conffile/幂等日志按文档归档或清理。
- 没有临时 SSH 密钥、VM、下载服务或设备暂存目录残留。
