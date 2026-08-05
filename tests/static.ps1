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
    'packages/luci-app-modem-sms/htdocs/luci-static/resources/view/modem/sms.js',
    'packages/modem-sms-archived/Makefile',
    'packages/modem-sms-archived/files/etc/config/modem-sms-archive',
    'packages/modem-sms-archived/files/etc/init.d/modem-sms-archived',
    'packages/modem-sms-archived/files/usr/sbin/modem-sms-archived',
    'packages/modem-sms-archived/files/usr/share/modem-sms/archive_schema.sql',
    'packages/modem-sms-archived/files/usr/share/modem-sms/archive_store.lua',
    'packages/modem-sms-archived/files/usr/share/modem-sms/stagec_worker.lua',
    'tests/stagec-sql.js',
    'tests/stagec-worker.lua',
    'tests/stagec-fault-injection.lua',
    'tests/archive-migration.lua',
    'tests/archive-runtime.lua'
)

foreach ($relative in $requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $workspace $relative))) {
        throw "Missing required file: $relative"
    }
}

$productCode = Get-ChildItem -Path (Join-Path $workspace 'packages') -Recurse -File |
    Where-Object { $_.Extension -in @('.uc', '.js', '.json', '.po', '.lua', '.sql') -or $_.Name -in @('modem-smsd', 'modem-smsctl', 'modem-sms-archived') } |
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
if (-not $backendConfig.Contains("option read_retry_max '10'")) {
    throw 'SM reads must retry and merge changing partial snapshots up to ten times'
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
if (-not $backend.Contains('function contract_available(required_methods, require_signature)') -or
    -not $backend.Contains('function delete_available()') -or
    -not $backend.Contains('return contract_available([switch_method, list_method, send_method], false)') -or
    -not $backend.Contains('return contract_available([switch_method, list_method, send_method, delete_method], true)')) {
    throw 'backend read/send availability must be independent from delete method presence'
}
if (-not $daemon.Contains("capabilities.features.delete = false") -or
    -not $daemon.Contains("error_result('DEVICE_DELETE_DISABLED')")) {
    throw 'r5+ daemon must advertise and enforce the device-delete safety gate'
}
if (-not $daemon.Contains('archive_capabilities:') -or
    -not $daemon.Contains('messages_page:') -or
    -not $daemon.Contains('archive_verify:')) {
    throw 'A0 daemon archive proxy methods are missing'
}
$archiveConfig = Get-Content -LiteralPath (Join-Path $workspace 'packages/modem-sms-archived/files/etc/config/modem-sms-archive') -Raw -Encoding UTF8
$archiveInit = Get-Content -LiteralPath (Join-Path $workspace 'packages/modem-sms-archived/files/etc/init.d/modem-sms-archived') -Raw -Encoding UTF8
$archiveDaemon = Get-Content -LiteralPath (Join-Path $workspace 'packages/modem-sms-archived/files/usr/sbin/modem-sms-archived') -Raw -Encoding UTF8
$archiveStore = Get-Content -LiteralPath (Join-Path $workspace 'packages/modem-sms-archived/files/usr/share/modem-sms/archive_store.lua') -Raw -Encoding UTF8
$archiveSchema = Get-Content -LiteralPath (Join-Path $workspace 'packages/modem-sms-archived/files/usr/share/modem-sms/archive_schema.sql') -Raw -Encoding UTF8
$stagecWorker = Get-Content -LiteralPath (Join-Path $workspace 'packages/modem-sms-archived/files/usr/share/modem-sms/stagec_worker.lua') -Raw -Encoding UTF8
$archiveMakefile = Get-Content -LiteralPath (Join-Path $workspace 'packages/modem-sms-archived/Makefile') -Raw -Encoding UTF8
if (-not $archiveConfig.Contains("option archive_enabled '0'") -or
    -not $archiveConfig.Contains("option archive_copy_enabled '0'") ) {
    throw 'A0/A1 archive gates must default closed'
}
if (-not $archiveMakefile.Contains('+lsqlite3') -or
    -not $archiveMakefile.Contains('+libsqlite3-0') -or
    -not $archiveMakefile.Contains('+libubox-lua') -or
    -not $archiveMakefile.Contains('+libubus-lua')) {
    throw 'archive package dependencies are incomplete'
}
if (-not $archiveInit.Contains('umask 077') -or
    -not $archiveInit.Contains('touch "$archive_path"') -or
    -not $archiveInit.Contains('mkdir -p /root/modem-sms') -or
    -not $archiveInit.Contains('chmod 600') -or
    -not $archiveInit.Contains('[ ! -L /root/modem-sms ]') -or
    -not $archiveInit.Contains('[ ! -L "$archive_path" ]') -or
    -not $archiveInit.Contains('[ -f "$archive_path" ]')) {
    throw 'archive database permissions must be initialized to 0600'
}
if (-not [regex]::IsMatch($archiveDaemon,
        "(?s)archive_get\s*=\s*\{\s*function\(req\)\s*connection:reply\(req, error_reply\('PERMISSION_DENIED'\)")) {
    throw 'underlying archive_get must fail closed'
}
if ($archiveDaemon.Contains('allow_content') -or $archiveDaemon.Contains('current:get')) {
    throw 'underlying archive daemon must not expose content access controls'
}
if (-not $archiveStore.Contains('PRAGMA journal_mode') -or
    -not $archiveStore.Contains('wal_autocheckpoint') -or
    -not $archiveStore.Contains('journal_bytes') -or
    -not $archiveStore.Contains('capacity_snapshot') -or
    -not $archiveStore.Contains('migrate_schema') -or
    -not $archiveStore.Contains('ARCHIVE_SCHEMA_OUTDATED') -or
    -not $archiveStore.Contains('stage_c_gate_ok') -or
    -not $archiveStore.Contains('STAGE_C_GATE_INVALID') -or
    -not $archiveStore.Contains('BEGIN IMMEDIATE') -or
    -not $archiveStore.Contains('foreign_keys_ok') -or
    -not $archiveStore.Contains('source_integrity_ok')) {
    throw 'archive storage gates are incomplete'
}
foreach ($stagecFunction in @('function M.recover', 'function M.acquire',
		'function M.renew', 'function M.release', 'MAX_RECOVERY_ITEMS',
		'MAX_RECOVERY_JOBS', 'RECOVERY_LIMIT', 'RECOVERY_INCOMPLETE')) {
    if (-not $stagecWorker.Contains($stagecFunction)) {
        throw "Stage C worker function or recovery gate missing: $stagecFunction"
    }
}
if (-not $archiveSchema.Contains('lease_acquired_at')) {
    throw 'Stage C delete jobs must bind the lease acquisition timestamp'
}
if ($stagecWorker.Contains('ubus') -or $stagecWorker.Contains('lteat') -or
    $stagecWorker.Contains('delete_record') -or $stagecWorker.Contains('os.execute')) {
    throw 'Stage C worker must remain database-only and modem-independent'
}
if (-not $archiveDaemon.Contains('stagec_worker.recover')) {
    throw 'archive daemon must run Stage C startup recovery before verification'
}
foreach ($stageTable in @('stage_jobs', 'stage_job_items', 'stage_tombstones', 'stage_cpms_leases',
        'stage_cpms_lease_history', 'stage_events')) {
    if (-not $archiveSchema.Contains("CREATE TABLE IF NOT EXISTS $stageTable")) {
        throw "Stage C schema table missing: $stageTable"
    }
}
foreach ($stageTrigger in @('stage_jobs_insert_gate', 'stage_job_items_insert_gate',
        'stage_tombstones_insert_gate', 'stage_jobs_identity_immutable',
        'stage_job_items_identity_immutable', 'stage_tombstones_identity_immutable',
        'stage_jobs_operation_state', 'stage_jobs_destructive_gate',
        'stage_job_items_operation_state', 'stage_job_items_destructive_gate',
        'stage_jobs_no_delete', 'stage_job_items_no_delete',
        'stage_jobs_valid_transition', 'stage_job_items_valid_transition',
        'stage_job_items_delete_call_once', 'stage_job_items_delete_completion_claim',
        'stage_tombstones_valid_transition', 'stage_cpms_leases_valid_transition',
        'stage_cpms_leases_insert_gate', 'stage_cpms_leases_immutable',
        'stage_cpms_lease_history_insert', 'stage_cpms_lease_history_update',
        'stage_cpms_lease_history_immutable', 'stage_cpms_lease_history_no_delete',
        'stage_events_no_update', 'stage_events_no_delete',
        'stage_tombstones_parent_state', 'stage_job_items_failed_reserved_tombstone',
        'stage_tombstones_immutable')) {
    if (-not $archiveSchema.Contains("CREATE TRIGGER IF NOT EXISTS $stageTrigger")) {
        throw "Stage C schema trigger missing: $stageTrigger"
    }
}
if (-not $archiveDaemon.Contains('stage_c_delete_enabled = false') -or
    -not $archiveDaemon.Contains("stage_c_error_code = 'STAGE_C_NOT_IMPLEMENTED'")) {
    throw 'Stage C archive capability must remain fail-closed'
}
if ($archiveStore.Contains('os.execute') -or $archiveStore.Contains('os.remove') -or
    $archiveStore.Contains('os.rename')) {
    throw 'archive store must not mutate files through generic Lua helpers'
}
if ($daemon.Contains('backend.delete_record(')) {
    throw 'r5+ public daemon must not contain a path to the backend delete operation'
}
if ($cli.Contains("command == 'delete'")) {
    throw 'r5+ SSH CLI must not expose a device-delete command'
}
if (-not $daemonMakefile.Contains('PKG_RELEASE:=13') -or -not $luciMakefile.Contains('PKG_RELEASE:=7')) {
    throw 'modem-smsd must use r13 and LuCI must use r7 for storage diagnostics'
}
if (-not $archiveMakefile.Contains('PKG_RELEASE:=12')) {
    throw 'modem-sms-archived must use PKG_RELEASE:=12'
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
if ('archive_verify' -in $readMethods -or 'archive_get' -in $readMethods) {
    throw 'LuCI ACL must not grant archive diagnostics or content access'
}

Write-Output "static.ps1: $($jsonFiles.Count) JSON files, $($messageIds.Count) translations and package invariants passed"
