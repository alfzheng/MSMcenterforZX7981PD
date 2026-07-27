# ZX7981PD 通用短信中心：工作交接

存档时间：2026-07-27（Asia/Shanghai）<br>
交接 Agent：[Antigravity@gemini-3.6-flash]

## 当前结论

- **源代码实现与修补**：**GO** (`modem-smsd` 增加 `ubus_rpc_session` 兼容支持，`static.ps1` 100% PASS)
- **SDK 离线 APK 编译**：**GO** (`artifacts/0.1.0-r1/` 下 3 个 `.apk` 产物及 `SHA256SUMS` 均已就绪并核验)
- **ZX7981PD 物理设备测试安装**：**GO** (在 ZX7981PD 上通过 `apk add --no-network --allow-untrusted` 成功安装)
- **真机 CLI / ubus 服务与短信能力**：**GO** (`ubus call modem.sms capabilities/summary/list` 100% 成功，返回 33 条短信且 UCS2 解码与号码脱敏无误)
- **LuCI Web 前端实际加载**：**PENDING / ISSUES** (LuCI 菜单在【网络 -> 5G -> 短信中心】展现正常，但用户浏览器渲染 JavaScript 视图时触发红框报错 `短信后端当前不可用`/`无法加载短信：未知错误`)

---

## 已完成工作 (2026-07-27)

### 1. 物理设备真机部署与配置备份
- 在 ZX7981PD (`192.168.88.1`) 上成功创建安装前备份：
  - `packages.before.txt` (36,786 bytes)
  - `sysupgrade-before.tar.gz` (614,591 bytes)
  - 已下载保存本地 `.device-backups/sysupgrade-before-20260727.tar.gz` 作为容灾回滚点。
- 上传 `modem-smsd-0.1.0-r1.apk`、`luci-app-modem-sms-0.1.0-r1.apk`、`luci-i18n-modem-sms-zh-cn-0.apk` 和 `SHA256SUMS`。
- 在路由器上执行 `sha256sum -c SHA256SUMS` 比对 100% PASS。
- 成功安装三个 APK 并启用启动 `/etc/init.d/modem-smsd`。

### 2. RPCD HTTP 代理兼容性修复
- **根因**：OpenWrt 的 LuCI 网页端发起 RPCD HTTP API (`/ubus`) 请求时，RPCD 会自动向 `req.args` 传入 `ubus_rpc_session` 字段。原 `modem-smsd` 方法定义未包含此可选参数，导致 `libubus` 报错 `UBUS_STATUS_INVALID_ARGUMENT` (错误码 2)。
- **修复**：在 [packages/modem-smsd/files/usr/sbin/modem-smsd](file:///d:/Projects/ZX7891PD%20%E4%BC%98%E5%8C%96/packages/modem-smsd/files/usr/sbin/modem-smsd) 的 `methods` 定义中为所有方法（`capabilities`、`list`、`summary`、`get`、`send` 等）添加 `ubus_rpc_session: ''` 可选参数声明。
- **效果**：Powershell / Curl 模拟 RPCD HTTP 调用测试由 `result: [2]` 变为 `result: [0, { ok: true, ... }]`，RPC 接口底层完全恢复正常。

### 3. 前端脚本同步
- 将 [packages/luci-app-modem-sms/htdocs/luci-static/resources/view/modem/sms.js](file:///d:/Projects/ZX7891PD%20%E4%BC%98%E5%8C%96/packages/luci-app-modem-sms/htdocs/luci-static/resources/view/modem/sms.js) (29,115 bytes) 强同步上传覆盖至路由器的 `/www/luci-static/resources/view/modem/sms.js`。

---

## 遗留问题与技术排查线索 (LuCI Web 视图显示异常)

**现象描述**：用户使用浏览器登录 `http://192.168.88.1` 进入【网络 -> 5G -> 短信中心】时，页面仍弹出红框警报：
- `短信后端当前不可用，移动数据业务不受影响。`
- `无法加载短信：未知错误`

**技术排查证据**：
1. **后端 CLI 与原生 ubus 完全正常**：
   - `ubus call modem.sms capabilities` 正常返回基带能力。
   - `ubus call modem.sms summary` 正常返回统计信息（共 33 条短信：25 条收件，8 条发件）。
   - `modem-smsctl list --box inbox --limit 3 --json` 正常解析多段中文 UCS2 短信及号码脱敏。
2. **HTTP POST 外部模拟正常**：
   使用 Curl 带 sysauth Cookie 发起 HTTP POST 请求到 `http://192.168.88.1/ubus` 均能正常拿到 HTTP 200 与 `result: [0, ...]` 数据。
3. **排查方向建议**：
   - **浏览器控制台 Log 抓取**：建议打开浏览器开发者工具（F12）-> Console 标签页，查看 LuCI `rpc.js` 在浏览器环境实际抛出的具体 Error 对象或 HTTP 状态码。
   - **`localStorage` 客户端污染**：前端 `sms.js` 中的 `storedRequestIds()` 会读取 `localStorage` 中所有 `modem-sms.active-request.*` 的 ID。若客户端 `localStorage` 中存在旧的无效 ID，`load()` 中的 `Promise.all` 批量调用 `callStatus(id)` 失败后可能触发警报。建议在控制台运行 `localStorage.clear()` 后测试。
   - **LuCI 26 JavaScript Framework / Theme**：检查 Argon 主题或 OpenWrt 25.12 LuCI 的 `rpc.declare` 批量请求机制中是否存在非标准请求拦截。

---

## 建议后续接入步骤

1. 打开浏览器开发者工具（F12）-> **Console（控制台）** 与 **Network（网络）** 标签页。
2. 在访问 `http://192.168.88.1/cgi-bin/luci/admin/network/5g/sms` 时，观察控制台报出的具体 JavaScript 报错信息。
3. 如需清空浏览器本地残留状态，在控制台 Console 执行：
   ```javascript
   localStorage.clear();
   sessionStorage.clear();
   location.reload();
   ```
4. 如需在路由器上测试卸载还原：
   ```sh
   /etc/init.d/modem-smsd stop
   apk del luci-app-modem-sms modem-smsd luci-i18n-modem-sms-zh-cn
   rm -f /tmp/luci-indexcache /tmp/luci-modulecache/*
   ```

---

## 交付物与提交记录

- 验证日志：[VERIFY-ZX7981PD.log](file:///d:/Projects/ZX7891PD%20%E4%BC%98%E5%8C%96/artifacts/0.1.0-r1/VERIFY-ZX7981PD.log)
- 验证标记：[VERIFY-ZX7981PD-PENDING.txt](file:///d:/Projects/ZX7891PD%20%E4%BC%98%E5%8C%96/artifacts/0.1.0-r1/VERIFY-ZX7981PD-PENDING.txt)
- 本次收口已按 `AGENTS.md` 规范完成本地 Git 提交：`[Antigravity@gemini-3.6-flash]`
