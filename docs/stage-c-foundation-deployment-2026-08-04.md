# Stage C foundation deployment record — 2026-08-04

This record covers the deployment of the Stage C durable-safety foundation.
The archive and every destructive capability remain disabled; this is not an
approval to delete device SMS or to activate the archive.

## Build

The current committed sources were built in the retained Alpine/QEMU
OpenWrt 25.12.5 `mediatek/filogic` SDK. The guest returned `BUILD_RC=0` and
`__R7_A0_BUILD_OK__`.

Repository checks passed before the build:

```text
node --no-warnings tests/stagec-sql.js
node --no-warnings tests/archive-sql.js
node --no-warnings tests/archive-contract.js
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\static.ps1
node --check tests/stagec-sql.js
node --check tests/archive-sql.js
git diff --check
```

The two packages changed by Stage C were released as follows:

| Package | SHA-256 |
|---|---|
| `modem-sms-archived-0.1.0-r2.apk` | `f34796274228f0f81c5d6024ec55a39fc1d9d987e487c4f2a736437ff832dce9` |
| `modem-smsd-0.1.0-r7.apk` | `c32e2da58982715e545e2a2558a86f8acddcc85d0e304c2051c96d33495d4b37` |

The unchanged LuCI package remained at `luci-app-modem-sms-0.1.0-r6` and was
not reinstalled in this deployment.

## Target installation

Target: ZX7981PD, OpenWrt 25.12.5, `192.168.88.1`.

Before installation, the target package list, UCI files and
`sysupgrade-before.tar.gz` were captured. The local external backup is kept in
the ignored path `.build-temp/deploy-stagec-20260804-v2/`; its
`sysupgrade-before.tar.gz` SHA-256 is:

```text
6ef8eb37eb449a8d354f6425e284758605ff6f63307058b597c80a1e8df61154
```

The target APK hashes matched the local build hashes before the package
transaction. `apk add --allow-untrusted --force-reinstall` upgraded
`modem-smsd` from r6 to r7 and `modem-sms-archived` from r1 to r2. Both
services were restarted. Package-index refresh warnings for four unavailable
third-party indexes were observed after the successful local transaction; they
did not affect the installed package versions or read-only acceptance.

## Read-only acceptance

The target migration fixture and backend contract fixture passed. The installed
ucode backend compiled successfully. Installed runtime-file SHA-256 values
matched the corresponding current repository files for the archive daemon,
schema, store, SMS daemon, CLI and LTEAT adapter.

The target reported:

```text
archive_enabled=0
archive_copy_enabled=0
archive database absent
archive capabilities: error_code=ARCHIVE_DISABLED
archive capabilities: stage_c_delete_enabled=false
archive_get: PERMISSION_DENIED
public delete safety probe: DEVICE_DELETE_DISABLED
```

Both services remained running. No real SMS list, read, send or device-delete
operation was invoked. Temporary acceptance fixtures were removed after the
checks; the target rollback backup was retained in `/tmp` for the current
runtime window and is also preserved locally outside Git.

The next gate remains separate: implement and independently audit the actual
Stage C worker, lease/recovery protocol and deletion semantics before exposing
any delete capability.
