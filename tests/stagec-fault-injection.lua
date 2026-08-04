#!/usr/bin/lua

local sqlite3 = require('lsqlite3')
package.path = 'packages/modem-sms-archived/files/usr/share/modem-sms/?.lua;' .. package.path
local worker = require('stagec_worker')

local schema_file = assert(io.open(
	'packages/modem-sms-archived/files/usr/share/modem-sms/archive_schema.sql', 'rb'))
local schema = schema_file:read('*a')
schema_file:close()

local path = assert(os.tmpname())

local digest = string.rep('a', 64)
local digest_b = string.rep('b', 64)
local digest_c = string.rep('c', 64)

local function clock(value)
	return function() return value end
end

local function one(db, sql, values)
	local statement = assert(db:prepare(sql))
	if values then assert(statement:bind_values(unpack(values)) == sqlite3.OK) end
	local result
	for row in statement:nrows() do result = row; break end
	statement:finalize()
	return result
end

local function exec(db, sql, values)
	local statement = assert(db:prepare(sql))
	if values then assert(statement:bind_values(unpack(values)) == sqlite3.OK) end
	local code = statement:step()
	statement:finalize()
	assert(code == sqlite3.OK or code == sqlite3.DONE)
end

local seed = assert(sqlite3.open(path))
assert(seed:exec(schema) == sqlite3.OK)
seed:close()

local holder = assert(sqlite3.open(path))
local contender = assert(sqlite3.open(path))
assert(holder:exec('BEGIN IMMEDIATE') == sqlite3.OK)
local busy, busy_error = worker.acquire(contender, {
	owner_id = 'busy-worker', owner_nonce_digest = digest,
	storage = 'SM', clock = clock(100), ttl_seconds = 100
})
assert(busy == nil and busy_error == 'STAGE_TRANSACTION_BUSY')
assert(one(contender,
	"SELECT COUNT(*) AS count FROM stage_cpms_leases WHERE lease_scope = 'global'").count == 0)
assert(holder:exec('ROLLBACK') == sqlite3.OK)

local lease = assert(worker.acquire(contender, {
	owner_id = 'restart-worker', owner_nonce_digest = digest, storage = 'SM',
	clock = clock(100), ttl_seconds = 100
}))
assert(lease.lease_generation == 1)
exec(contender, [[
	INSERT INTO stage_jobs (
		job_id, request_namespace, request_id, principal_id, operation,
		request_digest, selection_digest, token_digest, snapshot_version,
		worker_generation, state, created_at, updated_at, expires_at)
	VALUES ('restart-job', 'fault-injection', 'restart-request', 'root', 'move_local',
		?, ?, ?, 1, 'restart-worker', 'accepted', 100, 100, 400)]],
	{ digest, digest_b, digest_c })
exec(contender, [[
	INSERT INTO stage_job_items (
		job_id, item_no, archive_id, source_identity_digest, content_digest,
		storage, storage_index, scan_epoch, source_generation, source_token_digest,
		segment_no, segment_total, raw_pdu_sha256, archive_pin, state, created_at, updated_at)
	VALUES ('restart-job', 0, 'restart-archive', ?, ?, 'SM', 1, 'restart-epoch', 1, ?,
		1, 1, ?, ?, 'proposed', 100, 100)]],
	{ digest, digest_b, digest_c, digest, digest })
contender:close()
holder:close()

local restarted = assert(sqlite3.open(path))
local recovered = assert(worker.recover(restarted, clock(200)))
assert(recovered.changed and recovered.recovery_incomplete)
assert(one(restarted, "SELECT state FROM stage_cpms_leases WHERE lease_scope = 'global'").state == 'lost')
assert(one(restarted, "SELECT state FROM stage_job_items WHERE job_id = 'restart-job'").state == 'blocked')
assert(one(restarted, "SELECT state FROM stage_jobs WHERE job_id = 'restart-job'").state == 'blocked')
assert(one(restarted, "SELECT value FROM metadata WHERE key = 'recovery_incomplete'").value == '1')
assert(one(restarted,
	"SELECT COUNT(*) AS count FROM stage_events WHERE event = 'LEASE_LOST'").count == 1)
assert(one(restarted,
	"SELECT COUNT(*) AS count FROM stage_events WHERE event = 'RECOVERY_BLOCKED'").count == 2)
local repeated = assert(worker.recover(restarted, clock(201)))
assert(not repeated.changed and repeated.recovery_incomplete)
assert(one(restarted, "SELECT COUNT(*) AS count FROM stage_events").count == 3)
restarted:close()

os.remove(path)
os.remove(path .. '-journal')
print('stagec-fault-injection.lua: busy rollback and restart recovery checks passed')
