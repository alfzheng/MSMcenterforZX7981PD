# Archive-only enablement rehearsal — 2026-08-05

## Scope and safety boundary

This rehearsal covered only the local SQLite archive foundation on target
`ZX7981PD`, OpenWrt `25.12.5`, `aarch64_cortex-a53`, at `192.168.88.1`.

- `archive_enabled` was temporarily enabled only for read-only verification.
- `archive_copy_enabled` remained `0` throughout.
- Stage C destructive work and device deletion remained disabled.
- No modem SMS was read, sent, refreshed, or deleted.

## Issues found and fixed during the rehearsal

The rehearsal was intentionally run against the real target runtime. Each
startup failure was rolled back before the next package was installed.

1. The r6 init script used `install`, which is absent from the target BusyBox
   image. It was replaced with target-compatible `mkdir`, `touch`, and
   `chmod`, with fixed-path and restrictive-permission checks.
2. BusyBox `df` rejected the existing database file as a mount-point operand.
   Capacity probing now uses the database parent directory and requires an
   explicit success marker from the `df` command.
3. Target LuaSQLite3 exposes named result fields without numeric indexes.
   Scalar queries now support both `row[1]` and named-only result rows.
4. Archive initialization and store opening now reject symlinked paths,
   dangling symlinks, directories, and other non-regular database objects.
5. Non-positive, non-finite, fractional, or undersized capacity thresholds
   now fail closed with `ARCHIVE_CAPACITY_UNVERIFIED`.
6. A valid capacity budget no longer reports the contradictory `ARCHIVE_FULL`
   error code.

## Build and deployment evidence

The final package is `modem-sms-archived 0.1.0-r12`.

| Evidence | SHA-256 / result |
|---|---|
| r12 APK | `725446244407cffcfb7599b8aba8aea6918f5d0d34c2e4a4c1f6437fb27aa927` |
| r12 deployment-before backup | `5bac717089d789202ac35324d1f078fa7cc90c896a5da07c78cd09825a01743b` |
| target APK hash before install | matched the local r12 APK |
| package transaction | `modem-sms-archived r11 -> r12`, successful |

The package manager printed four pre-existing third-party package-index
download warnings. The package transaction itself completed successfully;
the package version and hash matched and the service passed the target checks.

As an additional source-to-target check, the installed r12 file hashes matched
the current repository source for the init script, daemon, archive store,
schema, and Stage C worker:

```text
init   77613f0ff319b5170bc728f059906b74ae482ef7dde6c9f9826e218a1187002b
daemon ff61850bbed19feb0e87e5726cf01e5bb4b14149c7c271723466daf6199e44ec
store  53b146a064972de5f97a6b2a2090c3755908d6927d3d1b59db88f2a9143d517b
schema b726337fc144167d04e28ea07198395da9da26dcd7ae1a71f32d5f9d15bd8790
worker f21a4b3e50cad79223c48c5671fd24d2093fa77439af300a3ce66038990abf2f
```

## Enabled-state acceptance

With `archive_enabled=1` and `archive_copy_enabled=0`:

- the archive service was `running`;
- `/root/modem-sms` was mode `0700`;
- `/root/modem-sms/archive.sqlite3` was mode `0600`;
- `archive-capabilities` returned `available=true`, `features.page=true`,
  `features.get=false`, `features.copy=false`, `features.destructive=false`,
  and `stage_c_delete_enabled=false`;
- `archive_verify` returned `ok=true`, `integrity_check=ok`, valid schema and
  capacity metadata, `recovery_incomplete=false`, and zero invalid digests;
- `messages_page` with `source=LOCAL`, `box=all`, `limit=10` returned
  `items=[]`, `filtered_count=0`, and `ok=true`;
- `archive_get` returned `PERMISSION_DENIED`;
- the compatibility device-delete RPC returned
  `DEVICE_DELETE_DISABLED`.

The archive page was empty. No modem backend operation was involved.

## Negative capacity check

The target was temporarily configured with
`archive_min_free_bytes=-1` while archive startup was enabled. The service
remained stopped and logged `ARCHIVE_CAPACITY_UNVERIFIED`. The valid value
`12582912` and the disabled archive configuration were then restored.

## Target-side regression checks

All of the following passed on the installed target runtime:

```text
lua tests/stagec-worker.lua
lua tests/stagec-fault-injection.lua
lua tests/archive-migration.lua
lua tests/archive-runtime.lua
```

The local checks also passed:

```text
node --no-warnings tests/stagec-sql.js
node --no-warnings tests/archive-sql.js
node --no-warnings tests/archive-contract.js
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\static.ps1
git diff --check
```

## Final rollback state

The rehearsal ended with:

```text
modem-sms-archived: 0.1.0-r12
archive_enabled=0
archive_copy_enabled=0
archive capabilities: ARCHIVE_DISABLED
device delete: DEVICE_DELETE_DISABLED
archive database: preserved at /root/modem-sms/archive.sqlite3
```

The archive database was preserved for a later explicitly approved archive
workflow. No archive-copy or Stage C enablement is implied by this rehearsal.

## Independent adversarial audit record

Three independent audit passes were used during implementation:

- Carson found no P0/P1 in the first target-compatibility review, but identified
  weak behavior coverage, symlink hardening gaps, and stale release evidence.
- Herschel escalated the dangling-symlink, invalid-capacity, and `df` exit-path
  issues to P1/P2. These were fixed in the subsequent r10/r11 source changes;
  the target negative-capacity checks were then executed.
- Avicenna found two remaining P1 issues: the Lua store did not independently
  reject a symlinked parent directory, and invalid UCI strings could still
  fall back to defaults. Both were fixed in r12.
- Parfit's final r12 audit reported P0=0 and P1=0. Its remaining P2 concerns
  were addressed by adding `tests/archive-runtime.lua` and clarifying the
  r6 historical baseline versus the r12 rehearsal result in the closeout
  documents.

The final audit conclusion is that the r12 runtime safety gate is publishable
for the bounded archive-only scope. It does not authorize archive copy, Stage
C destructive work, or device deletion.
