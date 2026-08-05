# SMS backend parse failure — 2026-08-05

## Finding

On ZX7981PD, `ubus call modem.sms list` reported `BACKEND_PARSE_FAILED` for
`SM`. The lower-level `lteat.get_sms` response was not stable across reads:
the observed `+CMGL` record counts were 48, 41, and 48 while `+CPMS` reported
50 used slots. A six-sample read-only probe eventually observed all 50 physical
indexes. This means the failure was caused by a changing partial modem
snapshot, not by a single malformed message alone.

The response also contained PDU lines with spaces between octets. The parser
now accepts that bounded hex representation and normalizes it before the
existing PDU length checks.

## Fix

`backend-lteat.uc` now performs at most twenty `get_sms` reads per storage and
accepts only one internally complete response. It succeeds only when that
single response count matches the `+CPMS` used count. An invalid or out-of-range
index, a duplicate index, an over-capacity result, or an incomplete result
after the retry bound remains a fail-closed `BACKEND_PARSE_FAILED` result. The bounded
diagnostics include `CAPACITY_MISMATCH`, parsed count, expected count, and
attempt count without exposing message content.

The default is configured as `read_retry_max '20'`; the backend also caps this
at twenty even if a local configuration is changed; non-numeric values fall back
to twenty. The UI now displays the
storage and bounded backend detail instead of converting it to “未知错误”.

## Verification boundary

- Local static, Stage C, archive SQLite, and whitespace/PDU regression checks
  pass.
- The package must be rebuilt and installed as `modem-smsd` r12 before claiming
  the target fix is active.
- Target verification is read-only: package hash, `ucode tests/backend.uc`,
  `ubus call modem.sms list`, storage state, and delete-disabled capability.
