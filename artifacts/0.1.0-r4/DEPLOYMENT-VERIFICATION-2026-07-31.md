# SMS service deployment verification

Date: 2026-07-31 (Asia/Shanghai)

Target: ZX7981PD / OpenWrt 25.12.5 / mediatek-filogic / ARMv8

## Deployed packages

- `modem-smsd` 0.1.0-r4
- `luci-app-modem-sms` 0.1.0-r4
- `luci-i18n-modem-sms-zh-cn` 0.260731.10577

## Configuration

- `modem-sms.main.cache_seconds=300`
- `modem-sms.lteat.read_call_timeout_seconds=60`
- service enabled and running as `modem-smsd`

## Verification

- Target SHA-256 verification: all three APKs passed.
- Offline APK verification: all three APKs passed `apk verify` and extraction checks.
- Package payload check: init script, daemon, CLI, core ucode and LTE backend contain no CRLF bytes.
- Static checks: `tests/static.ps1`, `tests/frontend-storage.js`, and JavaScript syntax check passed.
- `ubus -S list modem.sms`: passed.
- `ubus call modem.sms capabilities '{}'`: `ok=true`, backend available, SMS supported.
- Cold read with `refresh=false`: returned `loading=true` immediately, then `loading=false` with messages after approximately 10 seconds.
- Warm read path returned cached results without a send/delete operation.
- `usb0` remained configured with its existing address and default route; deployment changed only SMS packages, configuration, and service state.

## Deployment note

The first r3 installation exposed a Windows archive line-ending conversion issue: the package files were CRLF and the service could not start. The target was temporarily normalized, then r4 was rebuilt from LF-normalized package inputs, independently verified, and installed. The target is left on r4 only.

Pre-deployment rollback data is stored locally under `.device-backups/zx-sms-r3-predeploy-20260731/` and the target-side staging directory is `/tmp/modem-sms-r3-20260731-1045/`.
