# Stage C foundation milestone — 2026-08-04

This milestone implements the durable state foundation for the future safe SMS
move/delete workflow. It does **not** enable device deletion, expose a Stage C
RPC, add a CLI or LuCI action, or call the modem delete backend.

## Implemented

- Archive schema version 2 with forward migration for existing
  `message_sources` rows.
- Durable `stage_jobs`, `stage_job_items`, `stage_tombstones`,
  `stage_cpms_leases`, append-only lease history and redacted `stage_events`
  tables.
- Digest-only identity fields for request, selection, token, source, content,
  and raw PDU data. Bodies, numbers, raw PDUs and opaque tokens are excluded.
- SQLite triggers that reject invalid state transitions, resuming terminal or
  unknown work, deleting tombstones, and resetting a claimed physical delete.
- Insert and update guards bind jobs, items and tombstones to their immutable
  parent identity; Stage C audit detail is restricted to short uppercase
  machine codes.
- Foreign-key enforcement and digest integrity are verified before an archive
  store is considered usable; invalid legacy identity rows fail closed.
- Independent backend capability checks: read/send availability no longer
  requires the unused `del_sms` method; a future Stage C owner must check
  delete capability separately.

## Deliberate gates

- `modem.sms` continues to advertise `features.delete=false` and return
  `DEVICE_DELETE_DISABLED`.
- The archive service advertises `stage_c_delete_enabled=false` and
  `STAGE_C_NOT_IMPLEMENTED`.
- No Stage C public RPC, ACL, CLI or UI entry is present.
- `delete_call_count` is only a durable pre-call authorization claim. It is not
  an exactly-once modem guarantee: a crash before or after the external call
  leaves the item `unknown` and blocks automatic retry.
- Target deployment is not authorized by this milestone. Target integration
  remains read-only until the owner broker, trusted principal identity,
  preflight re-scan, durable barrier, worker recovery and fault-injection gates
  are implemented and independently audited.

## Verification

- `tests/stagec-sql.js` exercises schema constraints, idempotency uniqueness,
  terminal-state blocking, one-time delete claims and immutable tombstones.
- Existing A0 SQLite and archive contract tests remain required.
- No test in this milestone sends, reads, or deletes a real SMS.
