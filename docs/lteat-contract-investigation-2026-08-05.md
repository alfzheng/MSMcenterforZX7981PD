# lteat SMS contract investigation — 2026-08-05

## Scope

This investigation was read-only and targeted the authorized ZX7981PD device
at `192.168.88.1`. It did not send SMS, delete SMS, issue arbitrary AT, or
change modem configuration.

## Contract evidence

The target reports the following ubus signature:

```text
"get_sms":{}
"send":{}
"send_sms":{}
"del_sms":{}
```

The `lteat` executable contains the strings `get_sms`, `send_sms`, `del_sms`,
and fixed `AT+CMGL=4`. No argument schema, range argument, page token, or
index-specific read method was exposed by the ubus signature. The process owns
`/dev/ttyUSB2`.

The existing adapter therefore cannot request a bounded page from the current
private API. Passing a guessed argument to `get_sms` would not be a contract
fix and could create firmware-specific behavior that is not testable or safe.

## Read-only response evidence

Repeated `ubus call lteat get_sms '{}'` samples were summarized without
printing PDU bodies or phone numbers:

- samples returned 41 or 48 records while `+CPMS` reported 50 used slots;
- twelve samples eventually covered indexes 1 through 50 only as a union;
- three consecutive samples returned 41 records at indexes 1–41, with a
  serialized response size of 10,434 bytes and extracted result size of 10,251
  bytes;
- the response-size and index boundary are consistent with a lower-level
  fixed-output limit, but the proprietary binary and firmware source are not
  available, so this is recorded as a strong hypothesis rather than a proven
  implementation fact.

The adapter now returns only a bounded `serialized_response_bytes` diagnostic in
addition to `parsed_count`, `expected_count`, `attempts`, and the existing detail
code. It also requires an `OK` terminator before accepting a response. The
serialized size is not proof of a modem hardware buffer size. The adapter never
returns the raw response or PDU content in an error.

After the diagnostic package was installed, a direct read-only probe confirmed
`exact_ok_lines=0`, `last_line=OTHER`, `raw_bytes=10434`, and `text_bytes=10251`
for the current 41-record sample. This confirms that the present private
`lteat` response does not expose an `OK` line to callers. It still does not
prove whether `lteat` strips a successful terminator or the lower layer
truncates before it; a complete 50-record sample and controlled boundary test
are still required before relaxing the gate.

## Safety decision

The current fail-closed `BACKEND_PARSE_FAILED` behavior remains the correct
authoritative-read behavior. A union of responses, a stable subset, or an index
merge can retain stale records after slot reuse, mix states from different
instants, or silently omit/duplicate messages. None is eligible for archive,
send-capacity decisions, or deletion.

The evidence triggers the planned P1B fallback: replace the `lteat` SMS
transport with one controlled broker that remains the single serial-port owner
and supports bounded index reads or a complete, verifiable snapshot. The
current `lteat` process must not be bypassed by opening `/dev/ttyUSB2` from a
second process.

## Next gate

Before a broker package can be deployed, it must provide:

1. a versioned ubus contract for storage selection, complete listing, index
   reads, send, and delete;
2. serialized CPMS/TTY ownership and restart-safe request handling;
3. fake-serial tests for truncation, index reuse, status changes, conflicts,
   capacity changes, timeout, and partial transport failure;
4. target ucode/ubus syntax checks, a fresh installation backup, and a
   read-only SM/ME regression before any send or delete test.

Until those gates pass, the target remains on the fail-closed r17 diagnostic
backend. The diagnostic UI/package improvement is deployed separately, but it
does not claim to make the incomplete modem snapshot complete.
