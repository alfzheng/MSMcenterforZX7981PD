# ZX7981PD 修复后实测报告（2026-07-21）

## 环境

- 设备：ZX7981PD
- 固件：OpenWrt 25.12.5 r33051-f5dae5ece4
- 内核：6.12.94
- 平台：mediatek/filogic，ARMv8
- 短信后端：固件 `lteat` ubus 对象

测试使用一次性 SSH 公钥和 `/tmp/modem-sms-audit-20260721` 暂存目录。正式包未安装；测试结束后已删除设备暂存目录、本地私钥并撤销设备公钥，撤销后的 SSH 验证返回 255（publickey denied）。

## 结果

| 测试 | 结果 | 说明 |
|---|---:|---|
| `tests/static.ps1` | PASS | 2 个 JSON、85 条翻译和包不变量 |
| `tests/frontend-storage.js` | PASS | 多标签页 request ID 存储 |
| `tests/core.uc` | PASS | PDU、分段、长度限制、6/7 位脱敏边界 |
| `tests/backend.uc` | PASS | lteat 解析、重复物理索引拒绝、回调路径 |
| CLI 编译与非法参数 | PASS | 未知参数、缺值参数均返回 `INVALID_ARGUMENT`，退出码 2 |
| fake backend daemon/ubus | PASS 12/12 | 未调用真实短信发送 |
| live lteat 只读 | PASS | SM=true，ME=true，stale=false，存在短信记录 |

12 组 daemon/ubus 用例覆盖：冷 list、冷 get、单存储失败保留快照、冷 send 容量门禁、并发容量预留、终态重启、正常 purge、提交结果未知、接受后强制崩溃、多分段中途崩溃、删除客户端断线后重试同一删除以验证锁释放、purge 中断恢复。

## 实测发现并修复

原守护进程使用动态拼接的 `require('backend-' + id)`；目标 ucode 无法据此解析模块，daemon 会在启动阶段报告找不到后端。现改为先对白名单后端名做正则校验，再通过绝对路径 `loadfile('/usr/share/modem-sms/backend-' + id + '.uc')()` 加载。fake daemon 12/12 和 live lteat 读取均证明加载路径可用。

## 安全说明

- fake 测试中的 `10010` 只传给内存后端，没有进入 `lteat.send_sms`。
- live 测试只调用 capabilities/list，没有发送或删除；固件读取接口仍可能把 `REC UNREAD` 标记为 `REC READ`。
- 两个脚本检测到正式配置、正式文件或现有 `modem.sms` 对象时会拒绝运行。
- 测试期间应独占软件安装操作，避免“检查路径不存在”后另一进程并发创建同名文件。

## 当前发布结论

源代码修复和目标机实测已完成。正式部署仍须由 OpenWrt 25.12.5 mediatek/filogic SDK 生成两个 APK，提供 `SHA256SUMS`，并按 `docs/deployment-and-rollback.md` 完成安装前外部备份；在这些交付物出现前，正式 APK 部署保持 NO-GO。
