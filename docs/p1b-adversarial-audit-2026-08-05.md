# P1B 独立对抗性审计记录 — 2026-08-05

## 审计范围与结论

独立 agent Mencius 对当前 P1B broker 工作区进行只读审计，未修改文件、未连接
ZX7981PD、未部署。审计在本轮后续状态机修复之前完成，因此下表明确区分
“已修复但待复审”和“仍然阻断”。

总体结论：**NO-GO**。SDK 编译/打包是 GO；目标切换、短信快照授权和删除
启用仍是 NO-GO。

## 发现与处置状态

| 等级 | 发现 | 证据/风险 | 当前状态 |
|---|---|---|---|
| P0 | `scan_begin` 后零读取即可 `scan_end(stable=true)` | 会把空列表或不完整列表误报完整快照 | 已修复：broker 现在要求两轮顺序读取并在结束时检查 `complete`；需复审 |
| P0 | 通用 `ERROR/+CME ERROR/+CMS ERROR` 被当作空槽 | 调制解调器错误可能被伪装成空短信，破坏 `used` 计数 | 已修复：统一返回 `BROKER_EMPTY_UNCERTAIN`；目标空槽格式仍待设备验证 |
| P0/P1 | PDU 只做十六进制长度下限检查 | “部分 PDU + OK”可能进入缓存 | 已修复：校验 CMGR 声明长度、SMSC 长度和完整字节数；已加入 fake-serial 回归 |
| P1 | 重复/乱序 index 未在 broker 层阻断 | 上层可能重复读、漏读或混入 index 复用结果 | 已修复：每个 scan 强制 `1..total` 单调顺序，并保存第一遍记录比较第二遍 |
| P1 | scan lease 无超时 | 调用方崩溃或不结束会长期持有 TTY | 部分修复：默认 300 秒 uloop watchdog、成功读取刷新；调用方身份绑定/断连审计仍待补齐 |
| P0 | broker 尚未提供完整 `lteat` 数据面兼容层 | 直接抢占 `/dev/ttyUSB2` 会影响 LTE 数据面 | 未修复，部署阻断；当前包默认禁用 |
| P1 | `flock` 不能证明与现有 lteat 共享所有权协议 | advisory lock 不是完整 owner handoff | 未修复；必须替换为唯一 owner 或取得官方原子委托接口 |
| P1 | 私有 `modem.smsat` ACL 尚未完成 | LuCI/普通 SSH/非授权本地进程的 PDU 边界未证明 | 未修复，集成阻断 |
| P1 | capabilities/schema 与 send/delete 设计承诺不完整 | 缺少明确 supported storage/health/send 能力；删除仍需独立门禁 | 未修复；删除和发送不可在本阶段启用 |
| P2 | 配置 baud 曾未生效 | 配置与实际 termios 不一致 | 已修复并纳入后续构建；需复审 |

## 已执行验证

- OpenWrt 25.12.5 aarch64 SDK 构建成功，成功哨兵为
  `__P1B_BROKER_BUILD_OK__`；最新隔离构建端口为 4526。
- 最新 broker APK 本地 SHA-256：
  `47ca950ca45bd6a0001e099e8becb77beddccc203a6ede7a1554f5e169bdf437`。
- `tests/broker-package.js`：通过；检查默认禁用、依赖、独占 TTY、lease watchdog、
  PDU/错误 fail-closed 和 send/delete gate。
- `tests/broker-serial.js`：通过；覆盖完整帧、缺失终止符、响应超限、通用 AT 错误、
  PDU 截断和声明长度不一致。
- `tests/broker-snapshot.js`：通过；覆盖 partial union、index reuse、状态变化、
  容量变化和传输失败。
- 既有 `frontend-errors.js`、`frontend-storage.js`、`static.ps1`：通过。
- 测试仍是 host-side 模型/帧解析测试，尚未驱动交叉编译后的 C broker，也尚未做
  fake PTY + ubus 端到端测试。

## 尚未证实的事项

以下不是已确认漏洞，必须在下一阶段用设备手册、fake PTY 或目标只读实验确认：

1. RM500U-CNV 空槽 `AT+CMGR` 的确切响应，能否安全实现 model-specific empty classifier；
2. 目标 `lteat` 是否使用同一把 `flock` 以及全部数据面 ubus 方法清单；
3. CMGR 响应是否总是包含可用于 PDU 长度校验的最后一个数字字段；
4. broker lease 的 ubus 调用方身份、断连通知与 ACL 机制在目标固件上的可用方式。

## 下一步放行条件

1. 对当前修复版重新运行独立对抗审计，确认上述 P0 数据完整性问题不再复现；
2. 完成 fake PTY + C broker/ubus 测试，覆盖 lease 超时、重启、CPMS 切换、索引复用和
   帧截断；
3. 盘点并实现 `lteat` 的完整数据面兼容层，或取得现有 owner 的原子委托接口；
4. 完成最小权限 ACL 和非授权访问测试；
5. 只有全部通过后，才允许在新的备份和可回滚 canary 下讨论目标 owner 切换。

在这些条件满足前，继续保留已部署 r17 的 fail-closed 行为：不启用 broker、不启用
设备短信删除、不以部分列表覆盖已有缓存。
