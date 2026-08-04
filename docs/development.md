# Development and verification

## Source layout

- `packages/modem-smsd`: OpenWrt service package, core codec, backend adapter and SSH CLI.
- `packages/modem-sms-archived`: disabled-by-default A0 SQLite storage worker and schema.
- `packages/luci-app-modem-sms`: LuCI JavaScript view, menu, ACL and Simplified Chinese translations.
- `tests/core.uc`: target-runtime codec and segmentation tests.
- `tests/backend.uc`: lteat adapter parser and callback tests.
- `tests/daemon-integration.sh`: real daemon/ubus tests with a fake modem backend; never sends a real SMS.
- `tests/daemon-live-read.sh`: read-only live lteat smoke test; never sends or deletes.
- `tests/static.ps1`: package, JSON, ACL and product-decoupling checks.
- `tests/archive-contract.js`: A0 package and safety contract checks.
- `tests/archive-sql.js`: SQLite schema, ordering, idempotency and integrity checks.

## Local static check

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\static.ps1
```

## Target ucode check

Run from the repository root on an OpenWrt host or SDK that provides `ucode`:

```sh
ucode tests/core.uc
ucode tests/backend.uc
ucode -c -o /tmp/core.ucb packages/modem-smsd/files/usr/share/modem-sms/core.uc
ucode -c -o /tmp/backend.ucb packages/modem-smsd/files/usr/share/modem-sms/backend-lteat.uc
ucode -c -o /tmp/service.ucb packages/modem-smsd/files/usr/sbin/modem-smsd
ucode -c -o /tmp/ctl.ucb packages/modem-smsd/files/usr/bin/modem-smsctl
```

On an uninstalled test router, after copying the repository to a temporary directory:

```sh
sh tests/daemon-integration.sh "$PWD"
sh tests/daemon-live-read.sh "$PWD"
```

Both scripts refuse to run if `/etc/config/modem-sms`, `/usr/share/modem-sms`, or an existing `modem.sms` object is present. Do not bypass this guard on a deployed router.

## Build

Copy or link both directories below `packages/` into matching OpenWrt 25.12 package feeds. Build `modem-smsd` first and then `luci-app-modem-sms`. The target device uses `apk`, so final artifacts are APK packages even though package recipes retain the standard OpenWrt Makefile format.

For the r7 A0 candidate, build `modem-sms-archived` as a separate package after
`modem-smsd`. Its runtime dependencies are `lua`, `libubox-lua`,
`libubus-lua`, `libuci-lua`, `lsqlite3` and `libsqlite3-0`; the target SDK
must resolve and compile these packages before any target installation is
considered.

Do not install the service until the target syntax checks pass. The first device integration run should call `capabilities`, `analyse`, and a refreshed read before any write operation. Sending and deletion remain explicit, separately confirmed tests.

Before release, repeat the target checks with the exact firmware ucode version and run an independent read-only adversarial review. A passing local static check does not replace target compilation. Do not perform a real send or delete during the syntax/contract gate.

The current private `lteat` API does not offer one atomic “select storage and operate” call. Before every deployment or firmware upgrade, search the target filesystem and process list for other `AT+CPMS`, `lteat.get_sms`, `lteat.del_sms` or `lteat.send_sms` callers. Release is blocked if another caller can switch SMS storage concurrently; all SMS/CPMS access must be routed through `modem-smsd`.

The complete deployment evidence and rollback procedure are in `docs/deployment-and-rollback.md`. Source tests alone do not authorize a formal installation; the target-SDK APKs and their SHA-256 manifest are mandatory release inputs.
