'use strict';

const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const read = relative => fs.readFileSync(path.join(root, relative), 'utf8');
const assert = (condition, message) => {
	if (!condition) throw new Error(message);
};

const config = read('packages/modem-sms-archived/files/etc/config/modem-sms-archive');
const makefile = read('packages/modem-sms-archived/Makefile');
const init = read('packages/modem-sms-archived/files/etc/init.d/modem-sms-archived');
const acl = JSON.parse(read('packages/luci-app-modem-sms/root/usr/share/rpcd/acl.d/luci-app-modem-sms.json'));
const schema = read('packages/modem-sms-archived/files/usr/share/modem-sms/archive_schema.sql');
const store = read('packages/modem-sms-archived/files/usr/share/modem-sms/archive_store.lua');
const archived = read('packages/modem-sms-archived/files/usr/sbin/modem-sms-archived');
const daemon = read('packages/modem-smsd/files/usr/sbin/modem-smsd');

assert(/option archive_enabled '0'/.test(config), 'A0 archive must default to disabled');
assert(/option archive_copy_enabled '0'/.test(config), 'A1 copy must default to disabled');
assert(/PKG_NAME:=modem-sms-archived/.test(makefile), 'archive package name missing');
assert(/PKG_RELEASE:=12/.test(makefile), 'archive package release must be r12');
assert(/\+lsqlite3/.test(makefile) && /\+libsqlite3-0/.test(makefile),
	'SQLite runtime dependencies missing');
assert(/\+lua/.test(makefile) && /\+libubus-lua/.test(makefile),
	'Lua/ubus runtime dependencies missing');
assert(/\+libubox-lua/.test(makefile), 'Lua uloop runtime dependency missing');
assert(/\/root\/modem-sms\//.test(init), 'archive init must use the fixed data directory');
assert(/umask 077/.test(init), 'archive init must set a restrictive umask');
assert(/touch \"\$archive_path\"/.test(init) && /chmod 600/.test(init),
	'archive database must be initialized with mode 0600 using target-compatible utilities');
assert(/\[ ! -L \/root\/modem-sms \]/.test(init) && /\[ ! -L \"\$archive_path\" \]/.test(init),
	'archive init must reject symlinked directory and database paths');
assert(/\[ -f \"\$archive_path\" \]/.test(init),
	'archive init must reject non-regular existing database objects');
assert(/option cursor_max '128'/.test(config), 'cursor limit default missing');
assert(/option journal_mode 'DELETE'/.test(config), 'journal mode default missing');
assert(/CREATE TABLE IF NOT EXISTS metadata/.test(schema), 'metadata schema missing');
assert(/CREATE TABLE IF NOT EXISTS messages/.test(schema), 'messages schema missing');
assert(/CREATE TABLE IF NOT EXISTS message_sources/.test(schema), 'source schema missing');
for (const table of ['stage_jobs', 'stage_job_items', 'stage_tombstones', 'stage_cpms_leases',
	'stage_cpms_lease_history', 'stage_events'])
	assert(new RegExp(`CREATE TABLE IF NOT EXISTS ${table}`).test(schema),
		`Stage C table missing: ${table}`);
for (const trigger of ['stage_jobs_insert_gate', 'stage_job_items_insert_gate',
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
	'stage_tombstones_immutable'])
	assert(new RegExp(`CREATE TRIGGER IF NOT EXISTS ${trigger}`).test(schema),
		`Stage C trigger missing: ${trigger}`);
assert(/bind_values/.test(store), 'archive SQL inputs must use bound parameters');
assert(store.includes('for _, value in pairs(row) do'),
	'archive scalar queries must support named-only LuaSQLite3 result rows');
assert(!/os\.execute|os\.remove|os\.rename/.test(store),
	'archive store must not use shell/file mutation helpers');
assert(!/lteat|CPMS|send_sms|del_sms/.test(archived),
	'archive daemon must not depend on the modem backend');
assert(/archive_get\s*=\s*\{\s*function\(req\)\s*connection:reply\(req, error_reply\('PERMISSION_DENIED'\)\)/s.test(archived),
	'underlying archive_get must fail closed');
assert(!/allow_content|current:get/.test(archived),
	'underlying archive daemon must not expose content access controls');
assert(/archive_store\.open[\s\S]*:verify\(\)/.test(archived),
	'archive daemon must verify the store before serving requests');
assert(/PRAGMA journal_mode/.test(store) && /wal_autocheckpoint/.test(store),
	'archive journal mode and WAL checkpoint policy missing');
assert(/journal_bytes/.test(store) && /capacity_snapshot/.test(store),
	'archive capacity accounting/preflight missing');
assert(store.includes("local probe = path:match('^(.*)/[^/]+$') or path"),
	'archive capacity probe must use the database parent directory for BusyBox df');
assert(store.includes('__MODEM_SMS_DF_OK__') && store.includes('ARCHIVE_PATH_UNSAFE'),
	'archive capacity and path probes must fail closed on command or object errors');
assert(store.includes('valid_capacity_value') && store.includes('ARCHIVE_CAPACITY_UNVERIFIED'),
	'archive capacity thresholds must reject invalid numeric configuration');
assert(store.includes('local function option_number') &&
	store.includes('[ ! -L "\' .. parent') &&
	store.includes('[ -d "\' .. parent'),
	'archive store must independently reject a symlinked or missing parent directory');
assert(archived.includes('local function capacity_number') &&
	archived.includes('return tonumber(raw) or raw'),
	'invalid UCI capacity strings must reach the fail-closed archive validator');
assert(store.includes('local capacity_ok = peak_ok and free_ok') &&
	store.includes('if available == nil then'),
	'archive capacity error reporting must preserve a nil error on a valid budget');
assert(/migrate_schema/.test(store) && /ARCHIVE_SCHEMA_OUTDATED/.test(store) &&
	/stage_c_gate_ok/.test(store) && /STAGE_C_GATE_INVALID/.test(store) &&
	/BEGIN IMMEDIATE/.test(store) && /foreign_keys_ok/.test(store) &&
	/source_integrity_ok/.test(store),
	'archive schema migration/version gate missing');
assert(/stage_c_delete_enabled = false/.test(archived) &&
	/stage_c_error_code = 'STAGE_C_NOT_IMPLEMENTED'/.test(archived),
	'Stage C archive capability must remain fail-closed');
const archiveRead = acl['luci-app-modem-sms'].read.ubus['modem.sms'];
assert(archiveRead.includes('archive_capabilities') && archiveRead.includes('messages_page'),
	'LuCI metadata archive read methods missing');
assert(!archiveRead.includes('archive_verify') && !archiveRead.includes('archive_get'),
	'LuCI must not grant generic archive diagnostic/content methods');
for (const method of ['archive_capabilities', 'messages_page', 'archive_get', 'archive_verify'])
	assert(daemon.includes(`${method}:`), `daemon proxy method missing: ${method}`);

console.log('archive-contract.js: A0 contract checks passed');
