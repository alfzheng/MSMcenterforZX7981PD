# ZX 重启前代理启动项状态

日期：2026-07-27（Asia/Shanghai）  
实施与记录：[Codex@gpt-5.6-sol]

## 当前策略

ZX 当前使用 OpenClash。PassWall2 继续保留，便于以后随时切换；本次没有卸载
PassWall2，也没有删除其节点、规则或其他配置。

## 已复核的启动项

| 启动项 | 重启后状态 |
|---|---|
| `openclash-core-prepare` | 已启用 |
| `openclash` | 已启用 |
| `passwall2` | 已禁用 |
| `passwall2_server` | 已禁用 |
| `sing-box` | 已禁用 |
| `xray` | 已禁用 |

以上状态已在 LuCI“系统 → 启动项”页面设置，并在刷新页面后再次确认。

## 切换原则

以后切换回 PassWall2 时，应先完整停止并禁用 OpenClash，再按实际需要启用
PassWall2 及其所需组件。不要让两套透明代理同时运行，以避免 DNS、透明代理
端口和防火墙规则冲突。

本次只完成重启前设置，没有由代理执行整机重启。用户自行重启后仍需完成
OpenClash 冷启动、联网、DNS 和 Antigravity 分流验收。
