$ErrorActionPreference = 'Stop'

$workspace = Split-Path -Parent $PSScriptRoot
$jsonFiles = Get-ChildItem -Path (Join-Path $workspace 'packages') -Recurse -Filter '*.json'
foreach ($file in $jsonFiles) {
    $null = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
}

$requiredFiles = @(
    'packages/modem-smsd/Makefile',
    'packages/modem-smsd/files/etc/init.d/modem-smsd',
    'packages/modem-smsd/files/usr/sbin/modem-smsd',
    'packages/modem-smsd/files/etc/config/modem-sms',
    'packages/modem-smsd/files/usr/bin/modem-smsctl',
    'packages/modem-smsd/files/usr/share/modem-sms/core.uc',
    'packages/modem-smsd/files/usr/share/modem-sms/backend-lteat.uc',
    'tests/backend.uc',
    'packages/luci-app-modem-sms/Makefile',
    'packages/luci-app-modem-sms/htdocs/luci-static/resources/view/modem/sms.js'
)

foreach ($relative in $requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $workspace $relative))) {
        throw "Missing required file: $relative"
    }
}

$productCode = Get-ChildItem -Path (Join-Path $workspace 'packages') -Recurse -File |
    Where-Object { $_.Extension -in @('.uc', '.js', '.json', '.po') -or $_.Name -in @('modem-smsd', 'modem-smsctl') } |
    ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 }
$joined = $productCode -join "`n"

foreach ($forbidden in @('CXLL', 'CXZLL', 'CXYL', '/dev/ttyUSB', 'RM500U')) {
    if ($joined.Contains($forbidden)) {
        throw "Forbidden product coupling found: $forbidden"
    }
}

$frontend = Get-Content -LiteralPath (Join-Path $workspace 'packages/luci-app-modem-sms/htdocs/luci-static/resources/view/modem/sms.js') -Raw -Encoding UTF8
if ($frontend.Contains('innerHTML')) {
    throw 'Frontend must not use innerHTML'
}
if ($frontend.Contains('lteat')) {
    throw 'Frontend must not depend on the lteat backend'
}

$core = Get-Content -LiteralPath (Join-Path $workspace 'packages/modem-smsd/files/usr/share/modem-sms/core.uc') -Raw -Encoding UTF8
if ([regex]::IsMatch($core, '(?m)^\s+[0-9]+\s*:')) {
    throw 'ucode object keys that start with digits must be quoted for the target runtime'
}
$ucodeSources = Get-ChildItem -Path (Join-Path $workspace 'packages/modem-smsd') -Recurse -File |
    Where-Object { $_.Extension -eq '.uc' -or $_.Name -in @('modem-smsd', 'modem-smsctl') }
foreach ($source in $ucodeSources) {
    $text = Get-Content -LiteralPath $source.FullName -Raw -Encoding UTF8
    if ($text.Contains('(?:')) {
        throw "Target ucode regex engine does not support non-capturing groups: $($source.FullName)"
    }
}

$backend = Get-Content -LiteralPath (Join-Path $workspace 'packages/modem-smsd/files/usr/share/modem-sms/backend-lteat.uc') -Raw -Encoding UTF8
$daemon = Get-Content -LiteralPath (Join-Path $workspace 'packages/modem-smsd/files/usr/sbin/modem-smsd') -Raw -Encoding UTF8
$cli = Get-Content -LiteralPath (Join-Path $workspace 'packages/modem-smsd/files/usr/bin/modem-smsctl') -Raw -Encoding UTF8
$backendConfig = Get-Content -LiteralPath (Join-Path $workspace 'packages/modem-smsd/files/etc/config/modem-sms') -Raw -Encoding UTF8
$daemonMakefile = Get-Content -LiteralPath (Join-Path $workspace 'packages/modem-smsd/Makefile') -Raw -Encoding UTF8
$luciMakefile = Get-Content -LiteralPath (Join-Path $workspace 'packages/luci-app-modem-sms/Makefile') -Raw -Encoding UTF8
if (-not $backend.Contains("options.switch_argument ?? 'cmd'")) {
    throw 'lteat adapter must default to the target contract argument cmd'
}
if (-not $backendConfig.Contains("option switch_argument 'cmd'")) {
    throw 'lteat package configuration must use the target contract argument cmd'
}
if (-not $backendConfig.Contains("option minimum_free_slots '4'")) {
    throw 'target storage reserve must leave at least four SMS slots'
}
if (-not $backendConfig.Contains("option cache_seconds '300'")) {
    throw 'default SMS cache must cover the measured cold dual-storage read'
}
if (-not $backendConfig.Contains("option read_call_timeout_seconds '60'")) {
    throw 'read timeout must exceed the measured cold dual-storage read'
}
if (-not $frontend.Contains('this.data && this.data.loading') -or -not $frontend.Contains('Loading messages from the modem')) {
    throw 'frontend must distinguish a cold modem load from service unavailability'
}
if (-not $core.Contains('request_status_report ?? false')) {
    throw 'TP-SRR must remain opt-in until durable delivery-report reconciliation exists'
}
if (-not $backend.Contains('features: { read: true, send: true, delete: false')) {
    throw 'r5+ backend capability must fail closed for device deletion'
}
if (-not $daemon.Contains("capabilities.features.delete = false") -or
    -not $daemon.Contains("error_result('DEVICE_DELETE_DISABLED')")) {
    throw 'r5+ daemon must advertise and enforce the device-delete safety gate'
}
if ($daemon.Contains('backend.delete_record(')) {
    throw 'r5+ public daemon must not contain a path to the backend delete operation'
}
if ($cli.Contains("command == 'delete'")) {
    throw 'r5+ SSH CLI must not expose a device-delete command'
}
if (-not $daemonMakefile.Contains('PKG_RELEASE:=6') -or -not $luciMakefile.Contains('PKG_RELEASE:=6')) {
    throw 'both r6 package Makefiles must use PKG_RELEASE:=6'
}
if (-not [regex]::IsMatch($daemon,
        '(?s)summary:\s*\{.*?if\s*\(!cache\.loaded\).*?request_load\(null\).*?loaded:\s*false,\s*loading:\s*true')) {
    throw 'r6 summary must start a background cold load and return loading immediately'
}
foreach ($forbiddenDeleteUi in @("method: 'delete'", 'confirmDelete', 'sms-confirm-delete')) {
    if ($frontend.Contains($forbiddenDeleteUi)) {
        throw "r5+ LuCI must not expose the legacy delete flow: $forbiddenDeleteUi"
    }
}

$po = Get-Content -LiteralPath (Join-Path $workspace 'packages/luci-app-modem-sms/po/zh_Hans/modem-sms.po') -Raw -Encoding UTF8
$messageIds = [regex]::Matches($frontend, "_\('([^']+)'\)") |
    ForEach-Object { $_.Groups[1].Value } |
    Sort-Object -Unique
foreach ($messageId in $messageIds) {
    $escaped = $messageId.Replace('\', '\\').Replace('"', '\"')
    if (-not $po.Contains("msgid `"$escaped`"")) {
        throw "Missing Simplified Chinese translation entry: $messageId"
    }
}

$acl = Get-Content -LiteralPath (Join-Path $workspace 'packages/luci-app-modem-sms/root/usr/share/rpcd/acl.d/luci-app-modem-sms.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$menu = Get-Content -LiteralPath (Join-Path $workspace 'packages/luci-app-modem-sms/root/usr/share/luci/menu.d/luci-app-modem-sms.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $menu.'admin/network/5g/sms') {
    throw 'LuCI menu must expose the PRD path Network -> 5G -> SMS'
}
$readMethods = $acl.'luci-app-modem-sms'.read.ubus.'modem.sms'
$writeMethods = $acl.'luci-app-modem-sms'.write.ubus.'modem.sms'
foreach ($method in @('capabilities', 'analyse', 'list', 'get', 'status', 'summary')) {
    if ($method -notin $readMethods) { throw "Missing read ACL method: $method" }
}
foreach ($method in @('send')) {
    if ($method -notin $writeMethods) { throw "Missing write ACL method: $method" }
}
if ('delete' -in $writeMethods) {
    throw 'r5+ LuCI ACL must not grant the legacy device-delete method'
}

Write-Output "static.ps1: $($jsonFiles.Count) JSON files, $($messageIds.Count) translations and package invariants passed"
