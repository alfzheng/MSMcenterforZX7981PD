# Stage C worker deployment record — 2026-08-04

This deployment installs the database-only Stage C lease/recovery foundation.
It does not enable archive ingestion, device deletion or any public Stage C
RPC.

## Artifact

Built in the retained Alpine/QEMU OpenWrt 25.12.5 mediatek/filogic SDK with
`BUILD_RC=0` and `__R7_A0_BUILD_OK__`:

| Package | Result |
|---|---|
| `modem-sms-archived-0.1.0-r6.apk` | `89adb99e530315a804f558e72ac463dc103eaa96288821708b915ee855e9a130` |
| `modem-smsd` | unchanged at r7; not reinstalled |
| LuCI package | unchanged at r6; not reinstalled |

The r5 hash matched on the target before installation.

## Target and backup

Target: ZX7981PD, OpenWrt 25.12.5, aarch64, `192.168.88.1`.

Before the package transaction, the following were captured in the target
temporary deployment directory and copied to the ignored local evidence
directory `.build-temp/deploy-stagec-worker-20260804/`:

- `apk info -vv` package list;
- `uci export modem-sms` and `uci export modem-sms-archive`;
- `sysupgrade-before.tar.gz` and its SHA-256.

Backup SHA-256:

```text
6ef8eb37eb449a8d354f6425e284758605ff6f63307058b597c80a1e8df61154
```

## Transaction and acceptance

The target upgraded `modem-sms-archived` from r5 to r6 and restarted only the
archive service. The existing modem SMS daemon was not replaced.

The installed package and runtime checks passed:

```text
lua tests/stagec-worker.lua
lua tests/archive-migration.lua
```

The worker test includes lease ownership, renew/release, caller-time
rejection, lost-lease recovery, unknown/blocked terminal states and a
5,001-item recovery-limit case. The migration test includes the legacy
`stage_jobs` lease-column migration and schema application order.

Post-deployment read-only state:

```text
modem-sms-archived: 0.1.0-r6
archive_enabled=0
archive_copy_enabled=0
archive database absent
archive capabilities: ARCHIVE_DISABLED
stage_c_delete_enabled=false
public delete safety probe: DEVICE_DELETE_DISABLED
modem-smsd and modem-sms-archived processes present
```

Package-index warnings for unavailable third-party indexes were observed
after the successful local transaction. They did not affect the local APK
hash match, installed package version or read-only acceptance.

Temporary target test directories were removed. The rollback backup and local
deployment evidence were retained. No real SMS interface was called.
