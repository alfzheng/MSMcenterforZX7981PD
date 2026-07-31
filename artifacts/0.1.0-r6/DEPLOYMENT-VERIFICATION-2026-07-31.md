# SMS safety hotfix r6 deployment verification

Date: 2026-07-31 (Asia/Shanghai)

Target: ZX7981PD / OpenWrt 25.12.5 / mediatek-filogic / ARMv8

Status: installed and accepted.

## Provenance

- Package source commit:
  `3a8ac33b0a1c9610f95e324c91bad891e22ae8fc`
- Integration-test JSON quoting fix:
  `8694280817e77ad271c13197e1dcf06e138cb5b9`
- SDK: OpenWrt 25.12.5 mediatek/filogic, GCC 14.3.0, musl.
- Build and offline verification used separate QEMU WHPX qcow2 snapshots.
- The accepted build used a dedicated fresh virtual FAT transfer directory.

## Installed packages

- `modem-smsd 0.1.0-r6`
- `luci-app-modem-sms 0.1.0-r6`
- `luci-i18n-modem-sms-zh-cn 0.260731.25120`

All three APKs matched their local SHA-256 values and passed target-side
`apk verify` before installation.

## Target results

- Service is enabled, running and registered as `modem.sms`.
- First `summary` after daemon restart returned in 0 seconds with
  `ok:true,loaded:false,loading:true`; the completed dual-storage scan arrived
  after 32 seconds in the clean final run.
- Completed metadata summary remained 37 messages: 28 inbound and 9 outbound.
- Storage remained SM 40/50 and ME 21/50.
- `features.delete=false` and
  `delete_error_code=DEVICE_DELETE_DISABLED`.
- A fixed nonexistent-ID legacy delete probe returned
  `ok:false,error_code:DEVICE_DELETE_DISABLED`.
- Before and after that probe, total count, SM/ME usage and
  `cache_updated_at` were identical.
- ACL write access contains only `send`; the daemon has no public backend
  delete call; LuCI has no delete method, confirmation handler or delete
  control; target payloads passed LF checks.
- List metadata, synthetic text analysis and nonexistent send-status lookup
  worked without reading message text.
- Thirteen real daemon/ubus integration tests passed with the memory fake
  backend; the wrapper restored the production config, package payload and r6
  service on both success and failure.
- `usb0` remained `10.65.179.52/24`; the default route remained via
  `10.65.179.1`.
- Overlay remained at 45% usage, with about 24.1 MiB available.
- No real SMS was sent or deleted.

## Browser note

Restarting `rpcd` during package installation invalidated the existing LuCI
browser session. The installed static LuCI payload and ACL were verified on
the target, but a final authenticated visual smoke test requires the user to
sign in to LuCI again. The browser tab is left at the login page for that
optional visual confirmation.

## Rollback

The external pre-deployment baseline and package-file rollback bundle are at
`.device-backups/zx-sms-r5-predeploy-20260731-144904/`. Verified r4 and r5
APKs are also retained under `artifacts/`. The target staging directory is
`/tmp/modem-sms-r5-20260731-144904/`.
