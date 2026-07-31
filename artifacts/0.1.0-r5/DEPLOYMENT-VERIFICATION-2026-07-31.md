# SMS safety hotfix r5 target verification

Date: 2026-07-31 (Asia/Shanghai)

Target: ZX7981PD / OpenWrt 25.12.5 / mediatek-filogic / ARMv8

Status: rejected as the final release; superseded by the corrective release.

## Results

- All three APKs matched their local SHA-256 values and passed target-side `apk verify`.
- `modem-smsd`, LuCI and the Simplified Chinese package upgraded from r4 to r5.
- The service was enabled, running and registered as `modem.sms`.
- `capabilities.features.delete=false` and
  `delete_error_code=DEVICE_DELETE_DISABLED` were confirmed on the target.
- `usb0` remained `10.65.179.52/24` with default route via `10.65.179.1`.
- No real SMS was sent or deleted.

## Rejection reason

The first `summary` call after daemon restart waited for the complete SM/ME cold
scan and exceeded the ubus client timeout. A retry after the background scan
completed returned the correct 37-message metadata summary, so this was not a
service crash or modem failure. The daemon's `list` endpoint already returned a
truthful non-blocking `loading:true` response, but `summary` had not adopted the
same cold-load contract.

The installed r5 package therefore proved the delete safety gate, but did not
pass the complete cold-start acceptance gate. Rebuilding different bytes under
the same package version is prohibited; the fix must increment the package
release before target installation.

Pre-deployment r4 baseline and rollback files are stored outside the device at
`.device-backups/zx-sms-r5-predeploy-20260731-144904/`.
