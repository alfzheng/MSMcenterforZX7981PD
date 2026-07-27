# ZX7981PD 通用短信中心：工作交接

存档时间：2026-07-27（Asia/Shanghai）<br>
交接 Agent：[Codex@gpt-5.6-sol]，前手 [Reasonix@reasoning-default]、[Antigravity@gemini-3.6-flash]

## 当前结论

- **源代码实现与修补**：**GO** (`modem-smsd` 增加 `ubus_rpc_session` 兼容支持，`static.ps1` 100% PASS)
- **SDK 离线 APK 编译**：**GO** (`artifacts/0.1.0-r2/` 下 3 个 ADB v3 APK、构建日志及 `SHA256SUMS` 已就绪)
- **r1 真机安装与读取链路**：**GO** (在 ZX7981PD 上安装成功，`capabilities/summary/list` 返回正常，读取 33 条短信)
- **r2 离线包内容核验**：**GO** (`apk verify`、`adbdump`、解包和关键修复内容检查全部通过)
- **r2 真机安装与 LuCI Web 验证**：**PENDING** (尚未部署到 ZX7981PD，真实 LuCI 会话仍待验收)

---

## 本轮工作 (Reasonix, 2026-07-27)

### 前端 RPC 兼容性修复

- **根因分析**：LuCI 26 `rpc.js` 的 `handleCallReply` 函数中，`expect: { '': {} }` 参数在边界情况下（RPCD 返回非标准响应帧、或 `ret` 为 `null`/`undefined` 时）会将实际 ubus 响应数据替换为 `expect` 中的空对象 `{}`，导致前端收到 `{ ok: undefined, backend_available: undefined }`，触发 `unavailable = true` 并显示"短信后端当前不可用"。
- **修复**：在 `sms.js` 中：
  - 从全部 7 个 `rpc.declare(...)` 调用中移除了 `expect: { '': {} }`，让 LuCI 26 原样透传 ubus 响应数据
  - 将 `load()` 中的 `L.resolveDefault(...)` 替换为显式 `.catch()` + `console.error('modem-sms: ...')` 日志，便于浏览器 F12 控制台诊断
  - 在 `render()` 中添加防御性空值检查：`this.capabilities = (data && data[0]) || {}`
  - 后端不可用时在警告下方显示具体 `error_code`（如 `SERVICE_UNAVAILABLE`、`BACKEND_UNAVAILABLE`）
- **静态检查**：`static.ps1` — 2 JSON files, 85 translations and package invariants passed
- **代码审查**：通过，无回归风险，语义等价
- **Git 提交**：`2d5113c [Reasonix@reasoning-default] Fix LuCI frontend RPC compatibility and error handling`（已合入 `main` 分支）

## 本轮工作 (Codex, 2026-07-27)

### 构建环境恢复与 r2 发布候选

- 通过 `Q:` 盘符规避中文宿主路径，使用 QEMU WHPX 成功启动 Alpine Linux 3.23。
- 以 `snapshot=on` 挂载 `.build-temp/alpine-build.qcow2`，基础构建磁盘未被改写。
- 启用 Alpine Live 的 loopback，恢复 SDK `fakeroot`/ADB v3 打包所需本地 IPC。
- 确认 LuCI 必须同步到 SDK 的 `feeds/luci/applications/luci-app-modem-sms`；只复制到 `package/` 不会替换实际选中的 feed 包。
- 将两个主包修订号提升为 `0.1.0-r2`，避免与真机现有旧 r1 同版本冲突。
- 生成并归档：
  - `modem-smsd-0.1.0-r2.apk`
  - `luci-app-modem-sms-0.1.0-r2.apk`
  - `luci-i18n-modem-sms-zh-cn-0.260721.25342.apk`
- 使用 SDK 自带 apk-tools 3.0.5 完成 ADB v3 完整性、元数据、解包与内容验证。
- 解包确认：
  - 后端包含 `ubus_rpc_session`；
  - 前端包含 `modem-sms: capabilities RPC failed` 诊断；
  - 前端不再包含旧 RPC `expect` 配置；
  - 简体中文 LMO 存在且非空。

---

## 遗留问题状态

### LuCI Web 显示异常 — 代码已修复，待真机验证

修复后的 `sms.js` 已包含在 `luci-app-modem-sms-0.1.0-r2.apk` 中并通过离线解包检查，
但**尚未部署到路由器进行真实 LuCI 会话验证**。

部署时应使用 `artifacts/0.1.0-r2/` 的完整包组和 `SHA256SUMS`，不要继续使用 r1，
也不要用直接覆盖单个 JS 文件替代正式升级。

---

## 排查要点（真机验证时关注）

修改后的前端代码在 `load()` 中输出了 `console.error` 日志。浏览器 F12 Console 中应能看到以下任一情况：

| 日志内容 | 含义 |
|----------|------|
| `modem-sms: capabilities RPC failed <Error>` | RPCD 返回了 JSON-RPC 错误帧（检查会话、ACL、rpcd 日志） |
| `modem-sms: list RPC failed <Error>` | `modem.sms` 对象可达但 list 方法失败（检查后端日志 `logread -e modem-smsd`） |
| 无日志但页面仍报错 | 问题在 `render()` 的数据处理，检查 Network 标签中 `/ubus` 请求的响应内容 |
| 无日志、页面正常 | 修复生效 |

**重要**：若 console.error 输出 `RPC call to modem.sms/capabilities failed with ubus code 2: Invalid argument`，
说明路由器仍在运行旧版后端。应确认已升级到 `modem-smsd-0.1.0-r2.apk` 并重启服务。

---

## 建议后续接入步骤

1. **连接路由器**：获取有效的 SSH 凭据或配置密钥。
2. **校验 r2 产物**：在上传前后分别执行 `sha256sum -c SHA256SUMS`。
3. **完整升级包组**：安装 r2 后端、r2 LuCI 主包和对应简体中文包，重启 `modem-smsd` 与 `rpcd`。
4. **浏览器验证**：清理 LuCI/浏览器缓存，打开 F12 Console + Network 验证 `/ubus` 响应和页面渲染。
5. **功能回归**：复测 capabilities、summary、list，并在受控条件下补测 send/status/delete。
6. **验收归档**：保存真机日志，全部通过后再建立正式发布标签。

---

## 交付物与提交记录

- 前端修复提交：`2d5113c [Reasonix@reasoning-default] Fix LuCI frontend RPC compatibility and error handling`
- 上一轮提交：`5258f57 [Antigravity@gemini-3.6-flash]` — RPCD 兼容修复 + HANDOFF
- 上上轮提交：`7a697b4 [Antigravity@gemini-3.6-flash]` — `ubus_rpc_session` 参数声明
- 验证日志：[VERIFY-ZX7981PD.log](artifacts/0.1.0-r1/VERIFY-ZX7981PD.log)
- 构建日志：[BUILD.log](artifacts/0.1.0-r1/BUILD.log)
- r2 发布候选：[artifacts/0.1.0-r2/](artifacts/0.1.0-r2/)
- r2 构建日志：[BUILD.log](artifacts/0.1.0-r2/BUILD.log)
- r2 离线核验：[OFFLINE-VERIFY.log](artifacts/0.1.0-r2/OFFLINE-VERIFY.log)
- r2 部署状态：[DEPLOYMENT-PENDING.txt](artifacts/0.1.0-r2/DEPLOYMENT-PENDING.txt)
- 设备备份：`.device-backups/sysupgrade-before-20260727.tar.gz`
- 构建环境 VM：`.build-temp/alpine-build.qcow2`（24 GB 虚拟磁盘，Alpine Linux 3.23）
- SDK 归档：`.build-temp/openwrt-sdk-25.12.5-mediatek-filogic_gcc-14.3.0_musl.Linux-x86_64.tar.zst`

**r2 已完成构建和离线核验；剩余门禁是真机升级与 LuCI/发送删除回归。**
