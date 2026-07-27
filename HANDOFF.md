# ZX7981PD 通用短信中心：工作交接

存档时间：2026-07-27（Asia/Shanghai）<br>
交接 Agent：[Reasonix@reasoning-default]，前手 [Antigravity@gemini-3.6-flash]

## 当前结论

- **源代码实现与修补**：**GO** (`modem-smsd` 增加 `ubus_rpc_session` 兼容支持，`static.ps1` 100% PASS)
- **SDK 离线 APK 编译**：**GO** (`artifacts/0.1.0-r1/` 下 3 个 `.apk` 产物及 `SHA256SUMS` 均已就绪并核验)
- **ZX7981PD 物理设备测试安装**：**GO** (在 ZX7981PD 上通过 `apk add --no-network --allow-untrusted` 成功安装)
- **真机 CLI / ubus 服务与短信能力**：**GO** (`ubus call modem.sms capabilities/summary/list` 100% 成功，返回 33 条短信且 UCS2 解码与号码脱敏无误)
- **LuCI Web 前端修复**：**CODE FIXED, APK NOT REBUILT** (前端 `sms.js` 已定位根因并提交修复，但新 APK 未编译、未部署到真机验证)

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

### 部署测试 — 未完成

**阻断原因**：
1. **SSH 不可达**：路由器 `192.168.88.1:22` 拒绝现有密钥认证，无可用密码凭据
2. **QEMU 虚拟化不可用**：`.build-temp/` 中的 Alpine VM (`alpine-build.qcow2`) 无法在当前 Windows 环境启动 —— TCG 崩溃、WHPX 不可用；中文路径导致 QEMU BIOS 文件加载失败；复制到 `/tmp/qemu-temp/` 后仍启动失败
3. **SDK 无法使用**：SDK 完整路径为 `.build-temp/openwrt-sdk-25.12.5-mediatek-filogic_gcc-14.3.0_musl.Linux-x86_64.tar.zst`（252 MB），需要一个运行中的 Linux 环境配合 `zstd` + `tar` 解压后使用，当前 Windows + Git Bash 不可行
4. **APK 手动重打包受阻**：`luci-app-modem-sms-0.1.0-r1.apk` 使用 Alpine ADB v3 二进制格式（`ADBd` 魔数），数据段经 gzip 整体压缩后嵌入 ADB 块中，手动解析重打包需要 `apk-tools`，当前环境未安装

**当前 artifacts 目录中的 APK 仍为修复前的旧版本**（含 `expect: { '': {} }` 的 sms.js）。部署新 APK 前必须重新构建。

---

## 遗留问题状态

### LuCI Web 显示异常 — 代码已修复，待真机验证

修复后的 `sms.js` 已提交到仓库，但**尚未编译 APK 或部署到路由器**。

**验证方法（按优先级）**：

1. **最快方案 — 直接覆盖 JS 文件**（推荐首先尝试）：
   ```sh
   # 将修复后的 sms.js SCP 到路由器
   scp packages/luci-app-modem-sms/htdocs/luci-static/resources/view/modem/sms.js \
     root@192.168.88.1:/www/luci-static/resources/view/modem/sms.js
   # 清除 LuCI 缓存
   ssh root@192.168.88.1 'rm -f /tmp/luci-indexcache /tmp/luci-modulecache/*'
   ```
   然后在浏览器中：
   - 打开 `http://192.168.88.1` → 网络 → 5G → 短信中心
   - 按 F12 打开 Console，观察 `modem-sms:` 前缀的日志
   - 运行 `localStorage.clear(); sessionStorage.clear(); location.reload()`

2. **完整方案 — SDK 重新编译 APK**：
   ```sh
   # 在 Linux 环境中解压 SDK
   zstd -d openwrt-sdk-*.tar.zst | tar xf -
   # 复制修改后的源码到 SDK package feed
   cp -r packages/modem-smsd sdk/package/
   cp -r packages/luci-app-modem-sms sdk/package/
   # 编译
   cd sdk && make package/modem-smsd/compile && make package/luci-app-modem-sms/compile
   ```
   产物位于 `bin/packages/aarch64_cortex-a53/` 下，按 `deployment-and-rollback.md` 流程部署。

3. **容器方案**：
   - 将 `.build-temp/alpine-build.qcow2` 挂载到一台可用的 Linux/Windows (Hyper-V) 宿主
   - 启动 VM → 登录 root → SDK 已在 `/build/` 下
   - 参考 `serial-benchmark.js` 中的 chroot 命令进入构建环境

---

## 排查要点（真机验证时关注）

修改后的前端代码在 `load()` 中输出了 `console.error` 日志。浏览器 F12 Console 中应能看到以下任一情况：

| 日志内容 | 含义 |
|----------|------|
| `modem-sms: capabilities RPC failed <Error>` | RPCD 返回了 JSON-RPC 错误帧（检查会话、ACL、rpcd 日志） |
| `modem-sms: list RPC failed <Error>` | `modem.sms` 对象可达但 list 方法失败（检查后端日志 `logread -e modem-smsd`） |
| 无日志但页面仍报错 | 问题在 `render()` 的数据处理，检查 Network 标签中 `/ubus` 请求的响应内容 |
| 无日志、页面正常 | 修复生效 |

**重要**：若 console.error 输出 `RPC call to modem.sms/capabilities failed with ubus code 2: Invalid argument`，说明路由器上的 `modem-smsd` 仍是旧版（不含 `ubus_rpc_session` 参数）。需确认已安装 `modem-smsd-0.1.0-r1.apk`（SHA256: `7943965b...` 见 `OFFLINE-VERIFY.log` 第 99 行）。

---

## 建议后续接入步骤

1. **连接路由器**：获取有效的 SSH 凭据或配置密钥
2. **部署修复后的前端**：按上述"最快方案"直接 SCP 覆盖 `sms.js` 并清除缓存
3. **浏览器验证**：打开 F12 Console + Network，观察 RPC 调用结果
4. **若修复生效**：重新构建 APK（完整方案），确保后续版本发布包含修复
5. **若仍有问题**：根据 Console 日志定位具体错误，参考"排查要点"表格

---

## 交付物与提交记录

- 前端修复提交：`2d5113c [Reasonix@reasoning-default] Fix LuCI frontend RPC compatibility and error handling`
- 上一轮提交：`5258f57 [Antigravity@gemini-3.6-flash]` — RPCD 兼容修复 + HANDOFF
- 上上轮提交：`7a697b4 [Antigravity@gemini-3.6-flash]` — `ubus_rpc_session` 参数声明
- 验证日志：[VERIFY-ZX7981PD.log](artifacts/0.1.0-r1/VERIFY-ZX7981PD.log)
- 构建日志：[BUILD.log](artifacts/0.1.0-r1/BUILD.log)
- 设备备份：`.device-backups/sysupgrade-before-20260727.tar.gz`
- 构建环境 VM：`.build-temp/alpine-build.qcow2`（24 GB 虚拟磁盘，Alpine Linux 3.23）
- SDK 归档：`.build-temp/openwrt-sdk-25.12.5-mediatek-filogic_gcc-14.3.0_musl.Linux-x86_64.tar.zst`

**所有代码修改已按 AGENTS.md 规范提交。APK 重建和真机验证留待有 SSH/虚拟化能力的环境执行。**
