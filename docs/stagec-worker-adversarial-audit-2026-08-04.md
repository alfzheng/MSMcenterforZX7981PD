# Stage C worker adversarial audit record — 2026-08-04

## Scope and boundary

This audit covers the database-only Stage C worker, CPMS lease protocol,
startup recovery, legacy schema migration and the destructive-state guards.
It does not approve device SMS deletion. The target remained configured with
`archive_enabled=0`, `archive_copy_enabled=0`, and
`stage_c_delete_enabled=false`; no real SMS list, read, send or delete was
performed.

The first independent audit was performed by subagent Godel
(`019fcbe9-bb50-7df3-86e9-fcdc8d2ac73b`) against the uncommitted worker and
schema. It was read-only: the agent made no edits, made no commit, did not
connect to the target and did not call an SMS interface.

The report headline said “3 P1、5 P2”, but the body listed seven P2 findings.
This record preserves the body-level count: three P1 and seven P2 findings.

## Findings and disposition

| ID | Severity | Finding | Disposition and evidence |
|---|---|---|---|
| P1-1 | P1 | An active lease could be changed in `storage` through direct SQL, and `acquired_at` was not immutable in the active transition. | Fixed in `archive_schema.sql`: active owner, nonce, storage, generation and acquisition time are immutable; the SQL test attempts storage and acquisition-time rewrites and rejects both. |
| P1-2 | P1 | Caller-supplied time could create a future lease and extend denial of service. | Fixed in `stagec_worker.lua`: production calls use `os.time()`; tests may inject only a callable clock provider. Numeric `now` is ignored and an invalid clock is rejected. The target worker test covers both cases. |
| P1-3 | P1 | Delete jobs and delete claims were not bound to the enable gate and the active lease identity. | Fixed in schema columns/triggers: delete job insertion, delete item insertion, destructive state transitions and delete claims require gate `1` plus matching owner, nonce digest, storage and generation. The public daemon and backend delete gate remain disabled. |
| P2-1 | P2 | `move_local` could enter `deleting`. | Fixed by job and item operation-state triggers; SQL tests reject both transitions. |
| P2-2 | P2 | Recovery ran on the first archive RPC rather than before service registration. | Fixed in `modem-sms-archived`: when archive is enabled, store open, recovery and verification run before `connection:add`; failure aborts startup. The lazy path remains as a safety net. |
| P2-3 | P2 | Recovery selected all pending rows without a bounded work set. | Fixed with 5,000-item and 5,000-job limits. Exceeding a limit records `RECOVERY_LIMIT`, sets `recovery_incomplete=1` and fails closed without mass mutation. |
| P2-4 | P2 | SQLite errors were too coarsely classified. | Improved with explicit mappings for busy/locked, full, I/O, constraint and Stage C state errors. The mapping is intentionally conservative and never converts a database error into a modem operation. |
| P2-5 | P2 | Lua `unpack` was used as a global. | Fixed with `table.unpack or unpack` compatibility binding. |
| P2-6 | P2 | The target-runtime worker test was not part of the static required-file set. | Fixed: `tests/stagec-worker.lua` is required by `tests/static.ps1`; it was run successfully on the target runtime, including after package installation. |
| P2-7 | P2 | `modem-smsd` had a release bump without source changes. | Fixed by returning `modem-smsd` to r7. Only `modem-sms-archived` was released for this change. |
| P2-8 | P2 (conditional) | The delete job snapshot did not explicitly store and compare the lease `acquired_at` value. | Fixed in r6 with `stage_jobs.lease_acquired_at`, migration support, immutable identity checks and active-lease comparisons in all delete job/item gates. The local SQL and installed target Lua/migration tests passed. |

## Defects found during remediation

The adversarial findings also led to two test-driven corrections before the
final deployment:

1. Recovery first marks an active lease `lost`, so its safe terminal update of
   a delete item to `unknown` must not be blocked by the active-delete lease
   guard. The item trigger now permits only the safe `unknown/blocked` terminal
   state in that condition; it does not permit a destructive state or a new
   delete claim without an active matching lease. The target worker test
   initially caught this mismatch and passed after the correction.
2. Existing databases with the old `stage_jobs` columns must receive the four
   lease-binding columns before new triggers are parsed. `archive_store.lua`
   now performs that narrow pre-schema migration, and the migration test
   applies the full schema after a legacy Stage C table has been upgraded.

## Verification evidence

Local checks passed after the final source changes:

```text
node --no-warnings tests/stagec-sql.js
node --no-warnings tests/archive-sql.js
node --no-warnings tests/archive-contract.js
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\static.ps1
node --check tests/stagec-sql.js
node --check tests/archive-sql.js
git diff --check
```

Target OpenWrt 25.12.5 / aarch64 checks passed with the installed r6 files:

```text
lua tests/stagec-worker.lua
lua tests/stagec-fault-injection.lua
lua tests/archive-migration.lua
```

The target package transaction upgraded `modem-sms-archived` from r5 to r6
after the explicit lease-acquisition binding fix. The r6 APK SHA-256 is
`89adb99e530315a804f558e72ac463dc103eaa96288821708b915ee855e9a130`; the
target-side hash matched before installation.

The post-deployment read-only state was:

```text
modem-sms-archived: 0.1.0-r6
archive_enabled=0
archive_copy_enabled=0
stage_c_delete_enabled=false
archive database absent
archive capabilities: ARCHIVE_DISABLED
public delete safety probe: DEVICE_DELETE_DISABLED
modem-smsd and modem-sms-archived processes present
```

The installation backup is retained locally under the ignored deployment
evidence directory. Its SHA-256 is
`6ef8eb37eb449a8d354f6425e284758605ff6f63307058b597c80a1e8df61154`.

## Second-agent re-audit status

A fresh completed re-audit was performed by subagent Erdos
(`019fcc40-39db-7b70-b7cb-57dc2944fbc9`) after the first remediation. It found
no P0 or P1 issue and one conditional P2: the missing explicit
`lease_acquired_at` binding recorded above. That item was fixed in r6 and then
verified by local SQL/static checks and the installed target Lua/migration
tests. The agent made no edits, commits, target connections or SMS calls.

An earlier attempted re-audit by Halley
(`019fcbfb-8058-7eb3-ad25-28f9dac7e403`) timed out and is retained as an
incomplete, non-gating attempt; it is not counted as a passing audit.

The follow-up fault-injection review by subagent Dewey
(`019fcc59-0533-7672-8c49-42a9b10628f0`) found one P1 in the test harness:
the fixed temporary SQLite path could delete an unrelated file. It also found
two P2 coverage gaps: lock-failure state preservation and exact/idempotent
recovery-event assertions. The harness now uses `os.tmpname()`, verifies the
separate `LEASE_LOST`/`RECOVERY_BLOCKED` counts, and calls recovery twice to
verify no duplicate events. The target fault-injection test passed after
these changes; no runtime package change was needed.

## Audit conclusion

The independent audit findings are addressed and backed by local SQL, target
Lua and post-deployment safety checks. The result is a durable,
database-only recovery/lease foundation with fail-closed delete semantics.
It is not a release of device deletion: no public Stage C worker RPC, CLI,
LuCI action or modem delete call exists, and the two independent gates remain
closed.

The completed second-agent review found no unresolved P0/P1 issue. This still
does not expose device deletion: any future enablement requires separate
approval and additional modem fault-injection evidence.
