# modem.sms API

All successful and product-level error replies include `schema_version: "1.0"` and `ok`. Product errors are returned as JSON with `ok: false` so LuCI and SSH callers receive the same stable error body. Transport and ACL errors remain native ubus errors.

## Methods

| Method | Arguments | Important reply fields |
|---|---|---|
| `capabilities` | none | `backend_id`, `backend_available`, `transport`, `features`, `encodings`, `storages`, `read_may_mark_read` |
| `analyse` | `text` | `encoding`, `units`, `segments`, `single_limit`, `concat_limit` |
| `list` | `box`, `storage`, `limit`, `refresh` | `messages`, `updated_at`, `stale`, `errors`, `storage`, `read_may_mark_read` |
| `get` | `id` | `message` including decoded text; number remains masked |
| `send` | `to`, `text`, `request_id` | `request_id`, `state`, `encoding`, `segments`, `parts_submitted`, `message_references`, `idempotency_persisted` |
| `status` | `request_id` | current send state and safe error code |
| `history_clear` | `confirm: "PURGE-IDEMPOTENCY-HISTORY"` | number of idempotency records cleared |
| `delete` | `id`, `fingerprint` | `deleted`, `id` |
| `summary` | none | masked counts, storage health and queue depth |

Send states are `queued`, `sending`, `sent`, `failed`, or `unknown`. `sent` means the modem backend accepted every segment; it is not a handset delivery receipt. A timeout becomes `unknown` and is never retried automatically. If one or more multipart segments were accepted before a later segment failed, the state is `unknown` with `error_code: "PARTIAL_SUBMIT"`, `submit_error_code` containing the backend failure, and the confirmed `parts_submitted` count.

Idempotency history is written atomically to the configured `request_state_path` before a request may touch the modem and again when it reaches a terminal state. Both writes are flushed, atomically renamed and globally synchronized because this target does not expose a file-specific `fsync`; this is a deployment performance gate. The state file is mode `0600` and contains the request ID, payload fingerprint, masked recipient, state summary and modem message references, but not the recipient or SMS body. On restart, a request that had been `queued` or `sending` is recovered as `unknown/INTERRUPTED_BY_RESTART`; it is never resumed automatically. Accepted IDs are not evicted automatically. When `request_history_max` is reached, new sends fail closed with `IDEMPOTENCY_HISTORY_FULL`. A root administrator can run `modem-smsctl history-clear --confirm --json` when no send is active; this deliberately removes duplicate protection for every historical request ID and is audited.

Reusing an existing request ID with a different recipient or body returns `REQUEST_ID_CONFLICT`. If the latest known capacity for the configured send storage cannot preserve enough slots for every segment plus the configured reserve, `send` returns `STORAGE_FULL`. The backend also maps modem memory-full and SIM-readiness errors to stable product codes.

`delete` always performs a fresh dual-storage read before touching the modem. It refuses the operation if either storage cannot be read, if the logical message ID disappeared, or if the refreshed fingerprint differs. This prevents a stale UI row from deleting a newly received message after the modem reuses an index.

## Backend contract

A backend module is named `backend-<id>.uc` and returns `{ create }`. The created adapter supplies:

- `id`, `transport`
- `available()`
- `capabilities()`
- `list_storage(storage, callback)`
- `send_pdu(pdu_item, callback)`
- `delete_record(storage, index, callback)`
- `restore_storage(storage, callback)`

Successful `send_pdu()` replies may include `message_reference`. The service preserves one reference per submitted segment so a later backend can associate SMS-STATUS-REPORT records without changing the LuCI API.

The UI and public API never receive TTY paths or backend-native replies. Adding an AT broker, QMI or MBIM implementation therefore does not require frontend changes.
