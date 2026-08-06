# P1B SMS broker design — 2026-08-05

## Why P1B is required

The installed `lteat` object owns `/dev/ttyUSB2` through `/etc/init.d/lte` and
also supports the LTE data plane. Its SMS method is `get_sms:{}` with a fixed
`AT+CMGL=4` implementation; the authorized target returns an incomplete,
changing response. The current modem service therefore remains fail-closed.

P1B is not a second process that opens `/dev/ttyUSB2`. That would create two
serial owners and make `CPMS` selection, SMS reads, sends, and data-plane AT
operations race with one another.

## Route decision

| Route | Decision | Reason |
|---|---|---|
| A. `lteat.send` plus controlled `CMGR` | Candidate experiment only | It preserves the current owner, but has no atomic CPMS/read operation or modem epoch. It cannot be authoritative without a stronger broker contract. |
| B. A second SMS process opens `/dev/ttyUSB2` | Prohibited | Concurrent reads and CPMS switches can corrupt both SMS results and LTE control traffic. |
| C. One broker replaces or fronts the complete `lteat` owner | Required for deployment | It can serialize the TTY, hold a CPMS lease, expose bounded index reads, and retain the data-plane compatibility surface required by `/etc/init.d/lte` and LuCI. |

The next implementation must therefore either provide a compatibility
`lteat` ubus object for every method used by the target data plane, or obtain an
official way for the existing owner to delegate SMS operations atomically. A
SMS-only object that merely steals the TTY is not a valid deployment.

## Private broker contract

The broker's object is private to `modem-smsd` and must not be granted to the
LuCI or general SSH ACL. The first version should provide:

1. `capabilities` — contract version, owner identity/nonce, supported storage,
   read/send/delete capability, and health;
2. `scan_begin(storage)` — acquire the serialized CPMS lease and return a scan
   ID, storage, used/total capacity, and broker generation;
3. `scan_read(scan_id,index)` — read one physical index and return a bounded
   record with index, status, and PDU. The broker requires monotonically
   increasing indexes for two complete passes; a generic AT error is not
   treated as an empty slot until a model-specific response classifier is
   verified;
4. `scan_end(scan_id)` — re-check capacity/generation and release the lease;
5. `send_sms`, `delete_sms` — only after the existing archive/lease safety
   gates pass; delete remains disabled in the current release.

The public `modem.sms` API does not change. Raw PDU data is allowed only inside
the root-owned broker-to-daemon boundary and is never sent to LuCI, SSH output,
logs, or diagnostics.

## Authoritative snapshot gate

A broker scan is eligible for the normal message cache only when all of these
hold:

- CPMS storage and used/total capacity are stable at begin and end;
- every returned index is unique and within `1..total`;
- the number of non-empty records equals `used`;
- two complete indexed passes have identical index, full-PDU, and storage-state
  values;
- no transport timeout, malformed response, owner-nonce change, lease loss, or
  CPMS switch is observed;
- the broker reports a stable generation for the entire scan.

The current foundation also caps a single scan at 4096 physical slots and
fails closed on an ambiguous `CMGR` error. These are explicit compatibility
gates, not claims that the target modem has already passed them.

Any failure preserves the prior cache and returns a bounded error. A union of
partial passes is never a snapshot. The synthetic invariant model is covered
by `tests/broker-snapshot.js`; it is a contract gate, not evidence that the
current proprietary `lteat` implementation already satisfies the contract.

## Implementation sequence

1. Freeze the private contract and run the synthetic adversarial gate.
2. Implement a root-only serial core with exclusive open, termios setup,
   line/PDU framing, bounded timeouts, and a request queue.
3. Build a fake-serial harness for truncation, index reuse, status changes,
   capacity changes, conflicts, timeout, and restart/lease loss.
4. Inventory every target `lteat` method used by the data plane and implement
   compatibility shims before any owner switch.
5. Compile and install the broker disabled by default; run only fake and
   read-only target contract tests.
6. Create a fresh sysupgrade/config backup, stop the old owner only during an
   explicitly reversible canary, and restore it immediately on any data-plane
   or SMS regression.

No target owner switch is authorized by this design document. The current r17
diagnostic package remains the deployed fail-closed baseline until the broker
passes the independent audit and the complete target gate.

## Current integration checkpoint — 2026-08-06

The candidate `backend-smsat.uc` adapter now translates the private
`scan_begin/scan_read/scan_end` contract into the existing `modem-smsd` read
interface. It keeps `send_available=false` and device deletion disabled. The
default UCI backend remains `lteat`; selecting `smsat` is not a deployment
approval and does not provide the `lteat` data-plane compatibility surface.
The candidate `modem-smsd` package is r20 and was cross-compiled together with
the broker. The SDK environment has only a target-architecture `ucode`
binary, so the adapter test source was not executed on the x86 build host;
target-side ucode execution remains a gate.

The 2026-08-06 independent P1C audit findings were addressed in source: the
adapter is included in the package, scan tokens remain numeric for the int64
ubus schema, all scan termination paths confirm release or fail closed, and
generation/phase/PDU/status/empty invariants and a broker capabilities/owner
handshake are checked before scanning. The broker reports service contract health
separately from idle `serial_ready` state, so the pre-scan handshake does not require
an already-open TTY. The broker now binds the capability owner nonce to every
scan call and reports `serial_owner` from the actual held TTY descriptor. Empty
slot classification remains disabled unless a target-verified model-specific
CMS error code is configured; a generic modem error is never treated as empty.
This does not relax
the target-side owner, ACL, fake-PTY, or lteat data-plane gates.
