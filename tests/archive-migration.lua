#!/usr/bin/lua

local sqlite3 = require('lsqlite3')
package.path = 'packages/modem-sms-archived/files/usr/share/modem-sms/?.lua;' .. package.path
local archive_store = require('archive_store')

local function expect_ok(code, message)
	assert(code == nil or code == 0 or code == sqlite3.OK, message)
end

local function has_column(db, column, table_name)
	table_name = table_name or 'message_sources'
	local statement = assert(db:prepare('PRAGMA table_info("' .. table_name .. '")'))
	for row in statement:nrows() do
		if row.name == column then
			statement:finalize()
			return true
		end
	end
	statement:finalize()
	return false
end

local legacy = assert(sqlite3.open(':memory:'))
expect_ok(legacy:exec([[CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
INSERT INTO metadata(key, value) VALUES ('schema_version', '1');
CREATE TABLE message_sources (
    archive_id TEXT NOT NULL, storage TEXT NOT NULL, storage_index INTEGER NOT NULL,
    scan_epoch TEXT NOT NULL, source_generation INTEGER NOT NULL,
    raw_pdu BLOB NOT NULL, raw_pdu_sha256 TEXT NOT NULL,
    first_seen_at INTEGER NOT NULL, last_seen_at INTEGER NOT NULL,
    PRIMARY KEY (archive_id, storage, storage_index, source_generation));
CREATE TABLE stage_jobs (
    job_id TEXT PRIMARY KEY, request_namespace TEXT NOT NULL,
    request_id TEXT NOT NULL, principal_id TEXT NOT NULL,
    operation TEXT NOT NULL, request_digest TEXT NOT NULL,
    selection_digest TEXT NOT NULL, token_digest TEXT NOT NULL,
    snapshot_version INTEGER NOT NULL, worker_generation TEXT NOT NULL,
    state TEXT NOT NULL, error_code TEXT, created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL, expires_at INTEGER NOT NULL);]]),
	'legacy fixture creation failed')
assert(not has_column(legacy, 'source_token_digest'), 'legacy fixture unexpectedly has v2 column')
assert(archive_store.migrate_schema(legacy), 'v1 migration failed')
assert(has_column(legacy, 'source_token_digest'), 'source token migration missing')
assert(has_column(legacy, 'segment_no'), 'segment number migration missing')
assert(has_column(legacy, 'segment_total'), 'segment total migration missing')
assert(has_column(legacy, 'lease_generation', 'stage_jobs'), 'stage job lease generation migration missing')
assert(has_column(legacy, 'lease_acquired_at', 'stage_jobs'), 'stage job lease acquired_at migration missing')
assert(has_column(legacy, 'lease_owner_id', 'stage_jobs'), 'stage job lease owner migration missing')
assert(has_column(legacy, 'lease_nonce_digest', 'stage_jobs'), 'stage job lease nonce migration missing')
assert(has_column(legacy, 'lease_storage', 'stage_jobs'), 'stage job lease storage migration missing')
local version_statement = assert(legacy:prepare("SELECT value FROM metadata WHERE key = 'schema_version'"))
local version
for row in version_statement:nrows() do version = row.value break end
version_statement:finalize()
assert(version == '2', 'schema version was not advanced')
assert(archive_store.migrate_schema(legacy), 'repeat migration failed')
local schema_file = assert(io.open('packages/modem-sms-archived/files/usr/share/modem-sms/archive_schema.sql', 'rb'))
local full_schema = schema_file:read('*a')
schema_file:close()
local legacy_schema_code = legacy:exec(full_schema)
assert(legacy_schema_code == nil or legacy_schema_code == 0 or legacy_schema_code == sqlite3.OK,
	'full schema could not be applied after legacy Stage C migration: ' .. tostring(legacy:errmsg()))
legacy:close()

local full = assert(sqlite3.open(':memory:'))
expect_ok(full:exec('PRAGMA foreign_keys = ON'), 'foreign key pragma failed')
expect_ok(full:exec(full_schema), 'full schema fixture failed')
local foreign_keys = 0
local fk_statement = assert(full:prepare('PRAGMA foreign_keys'))
for row in fk_statement:nrows() do foreign_keys = tonumber(row.foreign_keys) or 0 end
fk_statement:finalize()
assert(foreign_keys == 1, 'foreign keys were not enabled in full schema fixture')
assert(archive_store.migrate_schema(full), 'full schema repeat migration failed')
full:close()

local rollback = assert(sqlite3.open(':memory:'))
expect_ok(rollback:exec([[CREATE VIEW metadata AS SELECT 'schema_version' AS key, '1' AS value;
CREATE TABLE message_sources (
    archive_id TEXT NOT NULL, storage TEXT NOT NULL, storage_index INTEGER NOT NULL,
    scan_epoch TEXT NOT NULL, source_generation INTEGER NOT NULL,
    raw_pdu BLOB NOT NULL, raw_pdu_sha256 TEXT NOT NULL,
    first_seen_at INTEGER NOT NULL, last_seen_at INTEGER NOT NULL,
    PRIMARY KEY (archive_id, storage, storage_index, source_generation));]]),
	'rollback fixture creation failed')
local migrated, migration_error = archive_store.migrate_schema(rollback)
assert(not migrated and migration_error, 'migration failure injection did not fail')
assert(not has_column(rollback, 'source_token_digest'), 'failed migration was not rolled back')
rollback:close()

print('archive-migration.lua: v1 migration, repeatability and rollback checks passed')
