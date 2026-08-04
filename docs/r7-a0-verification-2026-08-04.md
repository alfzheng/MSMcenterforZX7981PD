# r7 A0 verification record — 2026-08-04

This record packages the verification evidence for the r7 A0 hardening change.
The archive remains disabled by default. It is not a target deployment approval.

## Repository checks

The following checks passed from the repository root:

```text
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\static.ps1
node --no-warnings tests/archive-contract.js
node --no-warnings tests/archive-sql.js
node --check packages\luci-app-modem-sms\htdocs\luci-static\resources\view\modem\sms.js
node tests/frontend-storage.js
git diff --check
```

The checks cover the default-off gate, fixed archive path, no modem backend
coupling, fail-closed `archive_get`, storage verification/capacity gates, journal
policy, database permissions, cursor bounds, ACL scope, SQLite schema and query
ordering. `git diff --check` reports no whitespace errors.

## Isolated SDK build

The current package sources were staged into the ignored local build workspace and
built in the Alpine/QEMU OpenWrt 25.12.5 mediatek/filogic SDK. The guest build
returned `BUILD_RC=0` and `__R7_A0_BUILD_OK__`, and emitted seven APK payloads.
The APK hashes below were calculated from those emitted payloads in the serial
build log; no package binary is committed to this repository.

| Package | SHA-256 |
|---|---|
| `libsqlite3-0-0-3.53.1-r1.apk` | `c7d00a8136e93ad70949c82bee51f55d86a8f164e1a6e01f8a30e5b39e608cc7` |
| `libubox-lua-2026.06.19~7dd12784-r1.apk` | `874aa9396397789c3159881f98a9a69f2722615e2858a817dd5911812a685fe6` |
| `lsqlite3-0.9.5-r1.apk` | `59982cbaf7f50e099229732b788fe5bd5b3b92e0a43583c3209649ab9f541b2e` |
| `luci-app-modem-sms-0.1.0-r6.apk` | `8991267c20e5fba8192ef4276857e07379d5f3d1d576c3b1500d891178c08151` |
| `luci-i18n-modem-sms-zh-cn-0.260731.23086.apk` | `849b4c34020fb8053e1c1530e2747e61a4f29f1bbce93032635f904670da2d0a` |
| `modem-sms-archived-0.1.0-r1.apk` | `0ca15aab5715adee04a0449c580abd2350229bef9fb7c90cc05bda8319d92776` |
| `modem-smsd-0.1.0-r6.apk` | `29c1fd9d9c0af697df6966d0bedf035f75f8407cd5fec0f84a70b170a669e026` |

## Target boundary

The earlier target read-only baseline confirmed the archive service was installed,
`archive_enabled=0`, `ARCHIVE_DISABLED` was returned by archive capabilities and
verification, the archive database was absent, and no SMS list/get/send/delete/body
operation was invoked. The target has not been redeployed with this hardening
change in this record; after commit, repeat package SHA checks and read-only target
acceptance before considering A0 activation.
