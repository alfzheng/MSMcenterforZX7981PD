# ZX7981PD 通用短信中心

这是面向 OpenWrt 25.12 / LuCI 26 的短信收发实现。当前版本只提供通用短信能力，不包含中国联通流量查询、运营商指令模板或 App 私有接口。

## 组成

- `packages/modem-smsd`：常驻 ucode/ubus 服务、PDU 编解码、串行发送队列、`ME/SM` 合并、`lteat` 适配器和 SSH JSON CLI。
- `packages/luci-app-modem-sms`：LuCI JavaScript 页面、菜单、最小权限 ACL 和简体中文资源。
- `tests`：目标 ucode 编解码测试及本地静态检查。
- `docs`：API 与开发/上机验证说明。

LuCI 与公开 `modem.sms` API 不包含模块型号、固定 TTY 或 `lteat` 私有结构。更换模块时保留前端和核心服务，只需复用或新增 `backend-<id>.uc` 适配器；这不等于承诺所有 5G 模块无需适配即可使用短信。

## 本地检查

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\static.ps1
```

目标机/SDK 上还必须执行 `tests/core.uc` 和 `docs/development.md` 中的 ucode 编译检查，然后才能安装和进行真实短信回归。

## SSH JSON 接口

```sh
modem-smsctl list --box inbox --limit 50 --refresh --json
modem-smsctl get '<message_id>' --json
modem-smsctl send --to '+8613800000000' --text 'test' --confirm --request-id 'caller-unique-id' --json
modem-smsctl status 'caller-unique-id' --wait 120 --json
modem-smsctl summary --json
# 仅在历史已归档且确认接受旧 request ID 失去防重复保护时：
modem-smsctl history-clear --confirm --json
```

`sent` 表示全部短信段已被模块后端接受，并不等同于手机最终送达。超时状态为 `unknown`，服务不会自动重发。

r5 安全热修暂时禁用设备短信删除：LuCI 不显示删除入口，公开 ACL 不授权删除，
`capabilities.features.delete=false`，旧 `modem.sms.delete` 只返回
`DEVICE_DELETE_DISABLED`，不会读取或修改模组。读取和发送仍通过现有 `lteat`
契约工作。

当前 `lteat` 契约把 `CPMS` 切换与随后读取/发送拆成独立 ubus 调用。除
`modem-smsd` 外，不得有其他页面、脚本或守护进程并发调用 `lteat` 的短信/`CPMS`
方法。只有未来的唯一传输代理能够持续强制独占租约后，Stage C 才可重新开放设备
删除。

## 设备维护记录

- [ZX OpenClash 配置与 Antigravity 分流记录（2026-07-27）](docs/zx-openclash-configuration-2026-07-27.md)
- [项目收口与归档记录（2026-07-27）](docs/project-closeout-2026-07-27.md)
