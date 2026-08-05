# SMS diagnostic deployment — 2026-08-05

## Deployment scope

This was a diagnostic-only package upgrade on the authorized ZX7981PD target
(`192.168.88.1`, OpenWrt 25.12.5, `aarch64_cortex-a53`). It did not enable
device deletion, send SMS, delete SMS, archive SMS, or bypass the existing
`lteat` serial owner.

The package build used the matching OpenWrt 25.12.5 mediatek/filogic SDK in the
Alpine/QEMU build environment. The final package set was:

```text
091dcd0df1e9daa25f0935d1b4fb99d86becf84e4c798e27d1302ef93ac13573  modem-smsd-0.1.0-r17.apk
b73ac9f51108a3947a27c12c03473fa7f91c8445915c8f1eaf0531c7085b2e04  luci-app-modem-sms-0.1.0-r8.apk
db93d41de8b651318f1d210b39713d2cad9bea57a002fab2823be7ea683eb5f0  luci-i18n-modem-sms-zh-cn-0.260805.29338.apk
```

APK verification, extraction, package metadata checks, CR-byte checks, ACL
checks, delete-disabled checks, and the target's exact ucode backend contract
tests passed before installation.

## Backup and installation

The target backup directory was:

```text
/tmp/modem-sms-release-r17-20260805b/
```

The backup was also copied to the ignored local deployment evidence directory
`.build-temp/deploy-current-r17-20260805b/`. Important hashes:

```text
d5fb98ac779f017bcb248039b8b672c1eab3ea126a63b04c0959b8d8cc466410  sysupgrade-before.tar.gz
4479b547fe083a122fd589f45b9a44875355eb9267a019fc627623d9d5c60144  packages.before.txt
6cac188675cdd1e0b2e8b7e59ca7d87d319702810462d649261bfe9faceaba8c  modem-sms.uci.before
ced8d8686196d9f2445c8a2edb0ffce1d456090ae86cd00bbef18f06fd92e60a  modem-sms-idempotency.before.json
```

The three APKs passed target-side SHA-256 and `apk verify`, then upgraded
`modem-smsd` r16→r17, LuCI r7→r8, and the Chinese translation package. A few
unrelated configured package indexes were unreachable during the post-install
`apk info` command; this did not affect the successful package transaction,
service restart, or subsequent no-network version check.

## Read-only acceptance

The target now reports:

```text
modem-smsd-0.1.0-r17 [installed]
luci-app-modem-sms-0.1.0-r8 [installed]
luci-i18n-modem-sms-zh-cn-0.260805.29338 [installed]
cap_ok=true backend_available=true delete=false delete_error_code=DEVICE_DELETE_DISABLED
cold_ok=true loaded=false loading=true
final_ok=true loading=false stale=true SM available=false ME available=true
first_error_storage=SM error_code=BACKEND_PARSE_FAILED detail=RESPONSE_INCOMPLETE
parsed_count=41 expected_count=50 attempts=1 serialized_response_bytes=10434
```

A direct lower-level read-only probe confirmed the current `get_sms` result has
41 `+CMGL` headers, zero exact `OK` lines, and no `OK` final line. No raw PDU,
phone number, or message body was written to the report.

This is an expected safe outcome for the current incomplete backend response:
the service preserves the previous snapshot and marks it stale. The r17/r8
deployment improves diagnosis and prevents an unterminated response from being
treated as complete; it does not make the target's SMS list complete.

## Final disposition

- Diagnostic deployment: **GO**.
- Complete authoritative SMS read: **NO-GO**.
- Cross-response union and stable-subset display: **NO-GO**.
- Device deletion: remains disabled.
- P1B replacement broker: triggered; it must become the single CPMS/TTY owner
  and provide a versioned complete-snapshot or bounded index-read contract
  before functional deployment can be reopened.
