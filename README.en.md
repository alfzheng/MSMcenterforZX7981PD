# ZX7981PD SMS Center

This project provides SMS sending and receiving for OpenWrt 25.12 / LuCI 26. The current version focuses on general SMS capabilities and does not include operator command templates or private app interfaces.

## Scope and applicability

- Verified target: ZX7981PD running OpenWrt 25.12.5 on `aarch64_cortex-a53` with LuCI 26.
- Backend prerequisite: the target firmware must provide a compatible `lteat` ubus SMS contract.
- The project does not open a modem TTY directly or execute arbitrary AT commands.
- This is a ZX7981PD-oriented source and adaptation baseline, not a plug-and-play promise for arbitrary 5G modems or OpenWrt devices.

## Components

- `packages/modem-smsd`: the resident ucode/ubus service, PDU codec, serialized send queue, `ME/SM` storage handling, `lteat` adapter, and SSH JSON CLI.
- `packages/luci-app-modem-sms`: the LuCI page, menu entry, least-privilege ACL, and Simplified Chinese resources.
- `tests`: target ucode codec tests and local static checks.
- `docs`: API, development, deployment, and on-device verification notes.

The public LuCI and `modem.sms` APIs do not expose a modem model, fixed TTY path, or private `lteat` structure. A different modem requires a compatible `backend-<id>.uc` adapter; retaining the frontend and core service does not mean that every 5G modem works without adaptation.

## Current capabilities

- Read SMS from `SM` and `ME` storage.
- Decode GSM 7-bit and UCS2/PDU messages, including concatenated SMS.
- Send SMS through the existing `lteat` backend.
- Provide LuCI and constrained ubus/SSH JSON interfaces.
- Redact phone numbers and device identifiers in diagnostics by default; diagnostic paths do not emit message bodies.

## Deliberate limitations

- Device-side SMS deletion remains disabled. The capability reports `delete=false`, and the legacy delete method returns `DEVICE_DELETE_DISABLED` without reading or modifying modem storage.
- Batch selection, batch device deletion, and any behavior that presents a failed deletion as successful are not released.
- The service serializes `CPMS` switching and subsequent SMS operations. Other pages, scripts, or daemons must not concurrently call the modem's SMS/`CPMS` methods.

## Cold-start behavior

During cold start, the modem may return an incomplete SMS snapshot. The backend accepts only a single internally complete response and performs at most 20 bounded retries. In the worst case, a cold refresh may take about four minutes; previous complete `SM → ME → SM` samples on the target took approximately 23–44 seconds, with cache hits completing faster.

## Local checks

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\static.ps1
node --no-warnings tests\stagec-sql.js
node --no-warnings tests\archive-sql.js
```

The target device or SDK must also pass the ucode tests described in `docs/development.md` before installation and real SMS regression testing.

## SSH JSON interface

```sh
modem-smsctl list --box inbox --limit 50 --refresh --json
modem-smsctl get '<message_id>' --json
modem-smsctl send --to '+8613800000000' --text 'test' --confirm --request-id 'caller-unique-id' --json
modem-smsctl status 'caller-unique-id' --wait 120 --json
modem-smsctl summary --json
# Only when the historical archive is disposable and loss of old request-ID
# duplicate protection is explicitly accepted:
modem-smsctl history-clear --confirm --json
```

`sent` means that all SMS segments were accepted by the modem backend; it does not prove final delivery to the handset. A timeout is reported as `unknown`, and the service does not retry automatically.

## Deployment boundary

Build an `.apk` with the matching OpenWrt SDK, verify the target architecture and `lteat` contract, back up the configuration, and perform a read-only list check before installation. Do not install this release on an unverified device.

## Maintenance records

- [ZX OpenClash configuration and routing record (2026-07-27)](docs/zx-openclash-configuration-2026-07-27.md)
- [Project closeout and archive record (2026-07-27)](docs/project-closeout-2026-07-27.md)
- [SMS backend live regression record (2026-08-05)](docs/sms-backend-live-regression-2026-08-05.md)
