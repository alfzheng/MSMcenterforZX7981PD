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
| P1 | `modem-smsd` 尚未消费 broker 私有 scan 契约 | broker 单独可编译不等于现有读服务可安全接入 | 已加入候选 `backend-smsat.uc`；默认仍为 lteat，需 target ucode/ubus 复审 |

## 已执行验证

- OpenWrt 25.12.5 aarch64 SDK 构建成功，成功哨兵为
  `__P1B_BROKER_BUILD_OK__`；最新隔离构建端口为 4526。
- 最新集成候选构建同时产出 `modem-smsd-0.1.0-r18.apk` 和 broker r1，
  成功哨兵为 `__P1C_INTEGRATION_BUILD_OK__`；r18 本地 SHA-256 为
  `6eb39734513f5f6bfa826c62321fd8af3ce178517da634c07186f79c74087f90`。
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
- 集成构建发现 SDK 只有 target-architecture `ucode`，x86 构建主机无法直接执行
  `tests/backend-smsat.uc`；因此该 ucode 测试被明确标记 skipped，不能算通过。

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

## Independent P1C re-audit and remediation checkpoint - 2026-08-06

The independent read-only re-audit of the `backend-smsat.uc` integration returned
NO-GO. It found two P0 issues and several P1 issues: the adapter was not installed
by the `modem-smsd` package, release was not confirmed on all begin/read failure
paths, `scan_id` was stringified before an int64 ubus call, generation/phase fields
were not checked, empty/PDU/status semantics were too permissive, and the adapter's
`restore_storage()` reported failure after a successful broker scan.

The source remediation in this checkpoint covers all of those findings:

1. `backend-smsat.uc` is now installed by `modem-smsd` r20.
2. Every scan failure attempts `scan_end`; a failed or malformed release returns
   `BROKER_SCAN_RELEASE_UNCONFIRMED` instead of hiding the release result.
3. The adapter preserves numeric scan tokens, checks schema version and generation,
   enforces phase/pass-complete/complete transitions, validates `pdu_bytes` and the
   SMSC-length boundary, accepts only known storage statuses, and rejects mixed
   `empty`/error/PDU replies.
4. Broker-backed `restore_storage()` is an explicit no-op because `scan_end` already
   performs the CPMS recheck and serial release. The legacy `lteat` adapter now
   exposes an explicit `send_available()` capability separate from read availability.
5. Each read scan now performs a broker capabilities handshake, requiring the
   expected schema, backend/transport identity, exclusive-owner flag, indexed-read
   flag, disabled device deletion, and a numeric owner nonce before `scan_begin`.
   The broker now reports `ok=true` while idle and exposes `serial_ready` separately,
   so a normal pre-scan capabilities probe does not falsely fail before the TTY is
   opened.

Local JS/static gates and the isolated OpenWrt build passed. The latest candidate
artifacts are `modem-smsd-0.1.0-r20.apk` (SHA-256
`C9B42A1EECE7307B295415B8AAEE0E01A2FCB987B9E5F10A34399DD6384A4611`) and
`modem-sms-broker-0.1.0-r5.apk` (SHA-256
`A57D1CF8D9D716D6FF250121F82DA813BD8043379FB5A39C5A37C961EF926182`).
The target-only `ucode` runtime was not available on the x86 build host, so
`tests/backend-smsat.uc` remains explicitly skipped rather than counted as passed.
The target owner switch, ACL validation, fake-PTY/ubus end-to-end test, and any
send/delete enablement remain NO-GO.

## Independent adversarial audit - 2026-08-06 (Newton)

This was a fresh read-only audit of HEAD `c7a975a` plus the then-uncommitted
working-tree changes. The agent did not modify files, deploy, authenticate to the
target, or switch the serial owner. The result was **NO-GO**.

### Findings

1. **P0 - empty-slot count path was still unsafe.** The new configurable
   `empty_cms_error_code` was disabled by default, which correctly kept unknown
   modem errors fail-closed, but the C broker still incremented
   `nonempty_count` for an explicitly classified empty slot. A `used=1,
   total=2` scan would therefore end in `BROKER_COUNT_MISMATCH`. This was fixed
   in the follow-up working-tree change by incrementing only for non-empty
   records and returning `empty=true` without PDU/status fields.
2. **P0 - no owner/data-plane deployment closure.** The broker opens and locks
   `/dev/ttyUSB2`, while the installed `lteat` owner and its LTE data-plane
   methods remain in place. No atomic owner handoff, complete compatibility
   object, stop/restore procedure, or canary evidence exists. Enabling the broker
   remains prohibited.
3. **P1 - target Ucode contract is unexecuted.** `tests/backend-smsat.uc` uses
   fake Ubus callbacks only; the isolated build explicitly skips target-only
   Ucode on the x86 host. Cross-compilation is not target runtime evidence.
4. **P1 - no C broker + fake PTY + real Ubus end-to-end test.** CPMS switching,
   real empty-slot responses, lease timeout/restart, release on callback/error,
   and actual broker output into the adapter are not exercised together.
5. **P1 - private broker ACL and negative access test are absent.** The public
   LuCI ACL covers `modem.sms` only, but there is no target proof that ordinary
   LuCI sessions, non-root SSH, or other local Ubus clients cannot reach
   `modem.smsat` and its PDU-bearing methods.
6. **P1 - owner fields were too optimistic and scan calls lacked nonce binding.**
   The broker previously reported `serial_owner=true` even when no TTY lock was
   held, and scan calls did not carry the capability nonce. The follow-up change
   makes `serial_owner` track the held descriptor and binds `owner_nonce` across
   `scan_begin`, `scan_read`, and `scan_end`; target verification is still needed.
7. **P1 - host/worktree/release metadata could diverge.** At audit time the
   worktree was ahead of HEAD and the audit artifact text still mentioned an
   older broker release. The follow-up release must be rebuilt from a clean,
   committed state and its hashes/docs updated together.

### Audit evidence and remaining gates

The agent confirmed host/static tests and `BUILD_RC=0` only establish source and
cross-build health. They do not cover target Ucode, real Ubus, fake PTY, empty
slots, ACLs, LTE owner arbitration, or data-plane compatibility. The remaining
deployment gates are therefore: target Ucode execution, C broker/fake-PTY/Ubus
integration, private ACL negative tests, exact RM500U-CNV empty-slot response
verification, complete `lteat` data-plane inventory/compatibility or an official
atomic delegation interface, and a reversible canary with fresh backup. Until
all pass, the default `lteat` backend and broker-disabled baseline remain in
force; send/delete and owner switching remain disabled.

## Independent follow-up audit - 2026-08-06 (Chandrasekhar, provisional)

This second read-only audit was run against the repaired working tree before the
source commit `da4a8d3`. The agent did not modify files, deploy, authenticate to
the target, or switch the serial owner. It returned **Provisional NO-GO**.

### Confirmed by source/build evidence

- `empty_cms_error_code` defaults to disabled; the C broker has exact CMS-error
  parsing, separate empty/non-empty counting, and an empty reply without PDU or
  status fields.
- `owner_nonce` is present in the broker capability and scan policies, validated
  on begin/read/end, and propagated and checked by `backend-smsat.uc`.
- Broker r5 and smsd r20 hashes match the isolated OpenWrt build outputs.
- Host/static tests and cross-build pass, while the build log explicitly records
  `UCODE_HOST_TEST_SKIPPED=target-only-ucode`.

### Remaining blockers

1. **P0:** No verified `lteat` data-plane compatibility, unique-owner protocol,
   or atomic handoff exists. The broker still opens `/dev/ttyUSB2` while `lteat`
   remains the default backend.
2. **P0:** The target's real empty-slot `AT+CMGR` response and CMS error code are
   unverified; with the classifier disabled, non-full storage remains fail-closed.
3. **P1:** Target UCode execution, real C broker + fake-PTY + ubus end-to-end
   tests, private `modem.smsat` ACL/negative access tests, and target-side
   `owner_nonce`/`serial_owner` behavior are not verified.

The audit therefore rates host/static/build as GO and the disabled-state
candidate as conditional GO, but installation/enabling, owner switching, real
SMS reading, sending, and deletion remain NO-GO. The untracked user file
`4d4yapi.md` was not touched.

## Deployment attempt - 2026-08-06

The deployment request was advanced through read-only preflight only. The target
`192.168.88.1` responds on HTTP and TCP/22, but the SSH probe for `root` returned
`Permission denied (publickey,password)`. The LuCI root page returned HTTP 200,
while `/cgi-bin/luci/` returned HTTP 403 with `x-luci-login-required: yes`.

No package upload, installation, service restart, configuration change, serial
owner switch, backup overwrite, or SMS operation was attempted. Without an
authenticated management channel, the required target-side backup, owner/data-
plane inspection, reversible install, and rollback verification cannot be
performed safely. The deployment state therefore remains **BLOCKED / NO-GO**;
the broker-disabled baseline is unchanged.
## Disabled-state target deployment - 2026-08-06

After the target SSH key was installed, the candidate packages were deployed in
the fail-closed, disabled state. The target matched the build contract:
ZX7981PD, OpenWrt 25.12.5 `r33051-f5dae5ece4`, `mediatek/filogic`, and
`aarch64_cortex-a53`.

### Actions and evidence

- Created `/root/modem-sms-predeploy-20260806.tar.gz` and a manifest before
  mutation. The backup SHA-256 is
  `6A46BBE036FC18198BF8964FB63E8AF890AAB34A02977CEC180B2F7A6D7F1FE5`.
- Uploaded and verified broker r5
  (`A57D1CF8D9D716D6FF250121F82DA813BD8043379FB5A39C5A37C961EF926182`) and
  smsd r20
  (`C9B42A1EECE7307B295415B8AAEE0E01A2FCB987B9E5F10A34399DD6384A4611`).
- Upgraded `modem-smsd` r17 to r20 and installed `modem-sms-broker` r5 using
  the local APK files. The existing `/etc/config/modem-sms` remained
  `enabled=1`, `backend=lteat`.
- Confirmed `/etc/config/modem-sms-broker` has `enabled=0`, the broker init
  service is disabled/inactive, no broker process exists, and `modem.smsat` is
  absent from the ubus object list.
- Confirmed `modem-smsd` is running and the existing `lteat` process still owns
  the modem path. Overlay free space remained approximately 23.3 MB.

### Safety boundary

This is a package deployment only, not an owner switch or feature activation.
The default `lteat` backend, SMS send/delete gates, and broker disabled state
are unchanged. Target-side UCode execution, empty-slot verification, private
ACL testing, and LTE owner/data-plane compatibility remain required before any
broker start, backend change, SMS read through the new adapter, send, or delete.

## Target runtime verification - 2026-08-06

- The installed `/usr/share/modem-sms/backend-smsat.uc` passed
  `tests/backend-smsat.uc` under the target's real UCode runtime. This closes the
  target-UCode adapter contract gate for the disabled package deployment.
- The target ACL file grants LuCI access to selected `modem.sms` methods only;
  it contains no `modem.smsat` entry. The unauthenticated ACL exposes only
  session login/access methods.
- `ubus list modem.smsat` returned `Command failed: Not found`, as expected
  while the broker remains disabled. Therefore this is source/ACL evidence, not
  a claim that broker-started private-object negative access has passed.

The remaining activation blockers are the real C broker + fake-PTY/ubus loop,
target empty-slot response verification, broker-started ACL negative testing,
and LTE owner/data-plane compatibility. No broker start or SMS operation was
performed during this verification.
