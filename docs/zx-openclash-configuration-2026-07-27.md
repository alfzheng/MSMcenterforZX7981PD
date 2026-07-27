# ZX OpenClash 配置与 Antigravity 分流记录

日期：2026-07-27（Asia/Shanghai）<br>
设备：ZX7981PD<br>
系统：OpenWrt 25.12.5，mediatek/filogic，Linux 6.12.94<br>
实施与记录：[Codex@gpt-5.6-sol]

## 最终状态

ZX 已参考 Photonicat 2 的当前实机配置启用 OpenClash，同时保留 ZX
自身固件和接口差异：

| 项目 | 最终值 |
|---|---|
| OpenClash | `v0.47.110`，启用并开机自启 |
| Mihomo | Meta `v1.19.29 linux arm64` |
| 运行模式 | Fake-IP 增强 |
| 代理模式 | 规则 |
| 当前配置 | `/etc/openclash/config/iGG-iGuge.yaml` |
| 主策略组 | `♻️ 自动选择 - JP` |
| `openAI` | `SG - 新加坡 01` |
| 自动订阅更新 | 关闭，保留手动订阅条目 |
| PassWall2 | 停止、禁用、不开机自启 |
| IPv6 代理 | 关闭 |

Antigravity 的关键自定义规则已启用：

```yaml
- DOMAIN,antigravity-unleash.goog,openAI
```

订阅原有的 `aida.googleapis.com` 和
`generativelanguage.googleapis.com` 规则继续进入 `openAI`。

## 与 P2 的必要差异

P2 的 Mihomo 二进制为 44,236,926 字节，而 ZX 配置前只有约
43.3 MiB 可写空间。直接复制未压缩核心会把持久闪存几乎写满，因此
ZX 使用以下小闪存方案：

1. 官方 gzip 资产持久保存到
   `/root/codex-openclash-core/mihomo-linux-arm64-v1.19.29.gz`。
2. `S98openclash-core-prepare` 在 `S99openclash` 之前放置核心包装器。
3. 包装器在需要时校验压缩包与解压后二进制的 SHA-256，并解压到
   `/tmp/codex-mihomo-runtime/clash`。
4. OpenClash 继续使用其 `small_flash_memory=1` 模式。

官方压缩包 SHA-256：

```text
9a868b5e4e0ad91d9d71e1b41b0cfce78aaba44360c30df74a723f8e3926a86c
```

解压后二进制 SHA-256：

```text
8e02308f672e89c076bfc2fa1b03379bd54e58b0bafa81ffb01113fcf6da348d
```

对应的非敏感实现保存在：

- `scripts/zx-openclash/clash-meta-wrapper.sh`
- `scripts/zx-openclash/openclash-core-prepare.init`

## 备份与权限

配置前设备备份：

```text
/root/codex-backups/openclash-preconfig-20260727-020355
```

备份归档 SHA-256：

```text
607930187975a75fca04eac623c3009d8839facb979ca8fd34847700bb8a659f
```

电脑侧另存一份相同归档，位于 Git 忽略的 `.device-backups` 目录。
备份可能包含设备配置与认证信息，不得提交或分享。

以下敏感文件权限均为 `0600`：

- `/etc/config/openclash`
- `/etc/openclash/config/iGG-iGuge.yaml`
- 持久核心压缩包

实施期间使用300秒自动回滚保护；管理链路、DNS、HTTPS、防火墙和
核心检查通过后批准保留，回滚未触发。

## 验证结果

完成的检查：

- OpenClash开关和开机自启均生效；
- PassWall2开关为0、不开机自启且无残留进程；
- Mihomo只有一个运行实例；
- 配置离线语法测试成功；
- 冷启动模拟成功：删除全部临时核心后，仅依靠持久缓存恢复运行；
- Fake-IP DNS正常，`openwrt.org` 返回 `198.18.0.0/15` 地址；
- `fw4 check` 通过，nftables 中存在 OpenClash规则；
- ZX默认上游仍为 `usb0`，没有改动LAN管理地址；
- Gstatic和Google返回HTTP 204，Cloudflare和百度返回HTTP 200；
- 电脑通过ZX的认证混合代理完成客户端侧HTTPS测试；
- 三个Google AI域名均从电脑成功建立HTTPS连接。

路由日志明确记录：

```text
antigravity-unleash.goog -> openAI -> SG - 新加坡 01
aida.googleapis.com -> openAI -> SG - 新加坡 01
generativelanguage.googleapis.com -> openAI -> SG - 新加坡 01
```

最终资源余量：

```text
持久闪存可用：约 24.4 MiB
tmpfs 可用：约 169.7 MiB
系统 available 内存：约 248 MiB
```

## 验收边界

本次没有执行整机断电重启。冷启动模拟覆盖了最关键的“临时核心丢失后
能否从持久缓存恢复”路径，但首次计划内重启后仍应复查
`S98openclash-core-prepare`、`S99openclash`、DNS和实际HTTPS。

Windows当前默认网络仍是P2 Wi-Fi，电脑没有管理员权限添加临时路由，
所以没有把Windows全局透明流量切到ZX。客户端侧验证使用ZX的认证混合
代理完成。将电脑或手机真正以ZX为默认网关后，还应：

1. 确认没有同时启用其它VPN、系统代理或私人DNS；
2. 完整退出并重启 Antigravity；
3. 新建会话发送最小生成请求；
4. 在MetaCubeXD中确认三个Google AI域名仍命中同一个`openAI`出口。

不要同时重新启用 PassWall2 和 OpenClash。
