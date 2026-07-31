# 短信中心 r7 Stage A PRD 阶段收口

日期：2026-07-31（Asia/Shanghai）

执行 Agent：`[Codex@gpt-5]`

状态：PRD 与对抗性审计完成；按用户要求暂停，A0/A1 尚未编码、构建或部署

## 1. 本阶段结论

下一功能版本应撰写并遵循独立的实施级 PRD。r7 只允许交付 Stage A，并拆分为：

- A0：默认关闭的存储、分页、搜索、容量、备份/恢复和 sysupgrade 技术门禁；
- A1：A0 全部通过后才启用的最小单条复制任务；
- Stage B：多选、当前页全选、全部筛选结果和批量复制；
- Stage C：移动及任何设备删除。

r7 不把批量、移动或设备删除与 A0/A1 合并。r6 的
`DEVICE_DELETE_DISABLED` 五层失败关闭继续作为安全基线。

实施规格：

- `docs/prd-sms-stage-a-r7-2026-07-31.md` 1.1；
- `docs/prd-sms-local-archive-batch-management-2026-07-31.md` 0.5；
- `PRD.md` 1.6。

对应提交：

```text
af622aa [Codex@gpt-5] Define audited r7 Stage A delivery gates
```

## 2. 独立对抗性审计

使用两位独立 agent 完成首轮审计，并由其中一位对修订稿进行两轮闭环复核。

已关闭的主要阻断项：

1. Stage A 单条复制与 Stage B 异步任务边界矛盾；
2. SQLite/绑定尚未在目标 SDK 和 UBIFS 上验证；
3. 原有 64 位指纹不能承担归档来源身份；
4. 单条任务缺少 `request_namespace/request_id/job_id` 与重启收敛；
5. `source_token` 未绑定主体、操作、版本、epoch、generation、分片和过期时间；
6. 备份/恢复、降级、卸载和 sysupgrade 生命周期不完整；
7. sysupgrade 不能用“先外部备份”替代冻结、checkpoint、目录同步、校验和失败中止；
8. overlay、WAL、事务峰值和 12 MiB 安全余量缺少确定门禁；
9. ACL 主体委托、正文搜索 oracle、cursor 主体/API 绑定不完整；
10. Stage C 缺少全局 CPMS 唯一所有者和租约，必须继续禁用。

最终窄复核确认：重启恢复、`source_token` 和 sysupgrade 三类 P0 已在 PRD 中闭环。

## 3. 目标机只读证据

本阶段使用用户新增的任务专用 Ed25519 公钥进行只读探测，未安装包、未修改配置、
未读取短信正文、未发送或删除短信。

目标机：

- OpenWrt 25.12.5 `r33051-f5dae5ece4`；
- 架构 `aarch64_cortex-a53`；
- `/overlay` 为 UBIFS；
- 总计 47,592 KiB，已用 20,400 KiB，可用 24,724 KiB；
- 已安装 `modem-smsd/luci-app-modem-sms 0.1.0-r6`；
- `modem-smsd` 正常运行；
- `features.delete=false`；
- `delete_error_code=DEVICE_DELETE_DISABLED`。

存储依赖：

- 目标机当前没有 SQLite CLI 或 SQLite 绑定；
- OpenWrt 25.12.5 软件源提供 `libsqlite3-0 3.53.1-r1`，安装体积约 1,068 KiB；
- 提供 `lsqlite3 0.9.5-r1`，安装体积约 44 KiB；
- 目标机已有 Lua 5.1、`libubus-lua` 和 ucode 环境。

这些结果只证明 A0 技术路线可进行，不证明 SQLite/UBIFS 耐久性、掉电恢复或
sysupgrade 门禁已经通过。

## 4. 暂停状态

- A0 编码 agent 已停止并关闭；
- 主工作区中尚未完成的 Makefile、配置、procd、keep.d 和后端代码草稿已全部清理；
- 未生成 r7 APK；
- 未安装 SQLite 依赖；
- 未修改目标机 r6；
- Git 工作树在本收口文档提交前保持干净；
- 任务专用私钥仅位于被 Git 忽略的
  `.device-backups/zx-sms-stage-a-20260731/id_ed25519`；
- 公钥指纹：
  `SHA256:HVXqOeHxAHyYW31tfTwJKzmoiwqW2xozSkHJ/rBlyug`。

## 5. 明日续作顺序

1. 从本收口提交确认工作树、r6 目标状态和公钥连接；
2. 只实现 A0 隔离存储样机，保持 `archive_enabled=0`；
3. 使用 Lua 5.1、`libubus-lua`、`lsqlite3` 和参数绑定，不使用 shell 拼 SQL；
4. 先在目标 SDK/QEMU 完成 schema、权限、分页、搜索、cursor、空间和崩溃测试；
5. 构建 r7 候选包并归档依赖体积、`apk verify`、`adbdump` 和解包证据；
6. 真机先安装默认关闭的 A0，测量精确 overlay 增量和 UBIFS 行为；
7. 完成备份/恢复、降级、卸载及 sysupgrade 失败中止门禁；
8. A0 全部门禁通过后，另行决定是否进入 A1 单条复制；
9. A1 真机只能复制用户明确指定的测试短信；
10. Stage B/C 不在 A0/A1 中提前实现。

## 6. 明日禁止误判

- “SQLite 包可安装”不等于存储引擎已验收；
- “外部备份成功”不等于 sysupgrade 一致性快照已验收；
- “单条复制非破坏性”不等于可以省略持久请求、来源复核和重启收敛；
- “本地已有安全副本”不等于 Stage C 可以删除设备短信；
- 未通过真实 UBIFS 故障注入和 sysupgrade 中止门禁，不得启用 A0/A1。

