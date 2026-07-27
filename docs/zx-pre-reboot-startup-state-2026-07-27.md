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

## 整机重启验收结果

用户完成整机重启后，[Codex@gpt-5.6-sol] 于 2026-07-27 进行了实时复核：

- LuCI 显示系统运行时间约 3 分钟，确认不是旧会话或服务级重启；
- `/tmp/codex-mihomo-runtime/clash` 已由持久压缩缓存方案自动恢复并运行；
- 仅发现 Mihomo 和 OpenClash watchdog，没有 PassWall2、sing-box 或 xray
  运行进程；
- 重启后启动项仍保持 `openclash-core-prepare`、`openclash` 启用，其余四个
  备用代理相关启动项禁用；
- OpenClash 为 Meta 运行中、Fake-IP 增强模式、规则模式，配置文件仍为
  `iGG-iGuge.yaml`；
- 主策略仍使用 `♻️ 自动选择 - JP`，`openAI` 仍选择
  `SG - 新加坡 01`；
- 运行时规则表已加载
  `antigravity-unleash.goog` 的 `Domain :: openAI` 规则；
- ZX DNS 对 `antigravity-unleash.goog`、`openwrt.org`、`github.com`
  分别返回 `198.18.0.72`、`198.18.0.73`、`198.18.0.48`，Fake-IP 正常；
- OpenClash 路由器侧百度、网易云音乐、GitHub、YouTube 访问检查均为
  “连接正常”；
- 可用内存约 286.53 MiB，持久磁盘占用 19.69 / 46.48 MiB，临时空间占用
  43.03 / 242.16 MiB。

启动初期大陆 IP 白名单下载曾因 DNS 尚未就绪失败一次，随后自动重试、下载、
替换成功并完成 OpenClash 重启。最终运行状态稳定，因此不构成验收阻断。

## ZX Antigravity 最终验收

2026-07-27，[Codex@gpt-5.6-sol] 在 P16V 以 ZX 为默认网关的条件下完成
最终验收：

- `openAI` 固定选择 `SG - 新加坡 01`；
- `antigravity-unleash.goog` 和
  `daily-cloudcode-pa.googleapis.com` 的精确规则均已加载；
- `aida.googleapis.com` 和 `generativelanguage.googleapis.com`
  继续由订阅规则转入 `openAI`；
- 四个关键域名均完成 HTTPS 往返，且未发现 IPv6 绕行；
- 实时连接显示 Antigravity 的功能开关和生成服务流量均使用
  `openAI -> SG - 新加坡 01`；
- 实测 AI 出口位于新加坡，Cloudflare 机房代码为 `SIN`；
- 用户完成 Antigravity 最小生成请求并正常收到回复，日志记录两次
  `streamGenerateContent` 成功响应，没有地区不支持错误。

ZX 的冷启动、联网、DNS、透明代理、AI 分流和 Antigravity 端到端生成现已
全部验收通过。
