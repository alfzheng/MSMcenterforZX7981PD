# SMS backend live regression — 2026-08-05

## Scope

This record covers the build and target retest performed from repository
`main` at commit `5f1667e`. The target is ZX7981PD, OpenWrt 25.12.5
(`mediatek/filogic`, ARMv8/aarch64).

## Build and package verification

The target SDK build completed successfully in the local Alpine/QEMU WHPX
environment. It produced:

```text
modem-smsd-0.1.0-r16.apk
luci-app-modem-sms-0.1.0-r7.apk
luci-i18n-modem-sms-zh-cn-0.260805.13600.apk
```

SHA-256:

```text
3f5ef979363d00fd4376953310949e31ef1e26a681b46948060fd5c3f98f6b09  luci-app-modem-sms-0.1.0-r7.apk
f7b865bfc7fc6a807cda5746a3eec1269f06ff29da78016c4282958c899a72b6  luci-i18n-modem-sms-zh-cn-0.260805.13600.apk
12f8c7c53949a8653fa69d2ae5c5f802cb316c3a133e972712407c49acdfa08a  modem-smsd-0.1.0-r16.apk
```

Linux-side `apk verify`, `adbdump`, extraction, CR-byte checks, retry-bound
checks, delete-gate checks, ACL checks, and LuCI resource checks all passed.

## Pre-deployment state

The target already had the same package versions before this run:

```text
modem-smsd-0.1.0-r16
luci-app-modem-sms-0.1.0-r7
luci-i18n-modem-sms-zh-cn-0.260805.13600
```

The target-side hashes for `backend-lteat.uc` and `modem-smsd` matched the
newly verified package contents:

```text
df38c7aa2c724b1c8e053127c903c63ccd48fa47f077e90e3c9f47a372c63dcb  backend-lteat.uc
469027fc5b9a391d8e228445dbd699ba5737f1ae7efd3a0b6a7bfef411a33257  modem-smsd
```

An installation would therefore be a same-bits reinstall, not a functional
upgrade, and was intentionally not performed.

Before the retest, the target created an installation backup at
`/tmp/modem-sms-release-r16-20260805/`:

```text
d5fb98ac779f017bcb248039b8b672c1eab3ea126a63b04c0959b8d8cc466410  sysupgrade-before.tar.gz
6cac188675cdd1e0b2e8b7e59ca7d87d319702810462d649261bfe9faceaba8c  modem-sms.uci.before
ced8d8686196d9f2445c8a2edb0ffce1d456090ae86cd00bbef18f06fd92e60a  modem-sms-idempotency.before.json
```

## Live retest result

The target capabilities remained healthy and delete remained disabled, but a
read-only `modem.sms list` retest returned:

```text
BACKEND_PARSE_FAILED
detail=CAPACITY_MISMATCH
parsed_count=41
expected_count=50
attempts=20
```

The resulting summary was deliberately stale-preserving:

```text
loaded=true
loading=false
stale=true
SM available=false, preserved_snapshot=true, restore_ok=true
ME available=true, used=21, total=50
```

No SMS was sent, deleted, moved, or archived during this retest.

## Read-only modem evidence

The lower-level `lteat.get_sms` response is not a stable complete snapshot:

- twelve samples returned 41 or 48 records;
- the union of their physical indexes covered 1 through 50;
- six sampled responses had stable PDU lengths and hashes for overlapping
  indexes, but that does not prove that the records belonged to one instant;
- the target therefore still fails the r16 requirement that one response be
  internally complete and match `+CPMS` used capacity.

## Adversarial audit disposition

The independent audit is **NO-GO** for making a cross-response union the
authoritative snapshot. The audit identified index reuse, read-state changes,
capacity-consistent replacement, and duplicate/conflict cases as concrete
ways that a union could expose stale or incorrect messages. The current
fail-closed behavior is therefore retained.

Before a future version can use any multi-response strategy, it needs explicit
invariants and tests for stable capacity, unique in-range indexes, immutable
full-PDU identity, status changes, index reuse, conflicts, transport failure,
capacity changes, and the retry boundary. Any non-authoritative partial view
must remain ineligible for archive, send-capacity decisions, or deletion.

## Deployment disposition

**NO-GO for a new deployment.** The compiled packages are valid, but they are
bit-equivalent to the installed r16/r7 packages and the live read remains
stale-preserving. The next implementation gate is a separately reviewed
snapshot-consistency design or a reliable lower-level modem/backend snapshot
fix, followed by new fault-injection tests and a fresh target package.
