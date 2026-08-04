#!/usr/bin/lua

local sqlite3 = require('lsqlite3')
package.path = 'packages/modem-sms-archived/files/usr/share/modem-sms/?.lua;' .. package.path
local worker = require('stagec_worker')

local schema_file = assert(io.open(
	'packages/modem-sms-archived/files/usr/share/modem-sms/archive_schema.sql', 'rb'))
local schema = schema_file:read('*a')
schema_file:close()

local digest = string.rep('a', 64)
local digest_b = string.rep('b', 64)
local digest_c = string.rep('c', 64)
local function clock(value)
	return function() return value end
end

local function new_db()
	local db = assert(sqlite3.open(':memory:'))
	assert(db:exec(schema) == sqlite3.OK)
	return db
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

local db = new_db()
local lease = assert(worker.acquire(db, {
	owner_id = 'worker-1', owner_nonce_digest = digest, storage = 'SM',
	clock = clock(100), ttl_seconds = 100
}))
assert(lease.lease_generation == 1 and lease.state == 'active')
local busy, busy_error = worker.acquire(db, {
	owner_id = 'worker-2', owner_nonce_digest = digest_b, storage = 'ME',
	clock = clock(101), ttl_seconds = 100
})
assert(busy == nil and busy_error == 'LEASE_BUSY')
local wrong_storage, wrong_storage_error = worker.renew(db, {
	owner_id = 'worker-1', owner_nonce_digest = digest,
	storage = 'ME', lease_generation = 1, clock = clock(102), ttl_seconds = 100
})
assert(wrong_storage == nil and wrong_storage_error == 'LEASE_NOT_OWNER')
local renewed = assert(worker.renew(db, {
	owner_id = 'worker-1', owner_nonce_digest = digest,
	storage = 'SM', lease_generation = 1, clock = clock(102), ttl_seconds = 100
}))
assert(renewed.expires_at == 202)
assert(worker.release(db, {
	owner_id = 'worker-1', owner_nonce_digest = digest,
	storage = 'SM', lease_generation = 1, clock = clock(103), ttl_seconds = 100
}))
local next_lease = assert(worker.acquire(db, {
	owner_id = 'worker-2', owner_nonce_digest = digest_b, storage = 'ME',
	clock = clock(104), ttl_seconds = 100
}))
assert(next_lease.lease_generation == 2 and next_lease.storage == 'ME')
local recovered = assert(worker.recover(db, clock(105)))
assert(recovered.changed and recovered.recovery_incomplete)
assert(one(db, "SELECT state FROM stage_cpms_leases WHERE lease_scope = 'global'").state == 'lost')
assert(one(db, "SELECT value FROM metadata WHERE key = 'recovery_incomplete'").value == '1')
local blocked, blocked_error = worker.acquire(db, {
	owner_id = 'worker-3', owner_nonce_digest = digest_c, storage = 'SM',
	clock = clock(106), ttl_seconds = 100
})
assert(blocked == nil and blocked_error == 'RECOVERY_INCOMPLETE')
local clock_db = new_db()
local caller_time_ignored = assert(worker.acquire(clock_db, {
	owner_id = 'clock-test', owner_nonce_digest = digest_c, storage = 'SM',
	now = 4102444800, ttl_seconds = 1
}))
assert(caller_time_ignored.expires_at < 4102444800)
local invalid_clock, invalid_clock_error = worker.acquire(clock_db, {
	owner_id = 'clock-test-2', owner_nonce_digest = digest_b, storage = 'ME',
	clock = 123, ttl_seconds = 1
})
assert(invalid_clock == nil and invalid_clock_error == 'LEASE_CLOCK_INVALID')
clock_db:close()
db:close()

local delete_db = new_db()
exec(delete_db, "UPDATE metadata SET value = '1' WHERE key = 'stage_c_delete_enabled'")
exec(delete_db, [[
	INSERT INTO stage_cpms_leases (
		lease_scope, owner_id, owner_nonce_digest, storage, lease_generation,
		state, acquired_at, renewed_at, expires_at)
	VALUES ('global', 'worker-1', ?, 'SM', 1, 'active', 100, 100, 400)]],
	{ digest })
exec(delete_db, [[
	INSERT INTO stage_jobs (
		job_id, request_namespace, request_id, principal_id, operation,
		request_digest, selection_digest, token_digest, snapshot_version,
		worker_generation, lease_generation, lease_acquired_at, lease_owner_id, lease_nonce_digest,
		lease_storage, state, created_at, updated_at, expires_at)
	VALUES ('job-delete', 'stagec-worker', 'request-delete', 'root', 'delete_device',
		?, ?, ?, 1, 'worker-1', 1, 100, 'worker-1', ?, 'SM', 'accepted', 100, 100, 200)]],
	{ digest, digest_b, digest_c, digest })
exec(delete_db, [[
	INSERT INTO stage_job_items (
		job_id, item_no, archive_id, source_identity_digest, content_digest,
		storage, storage_index, scan_epoch, source_generation, source_token_digest,
		segment_no, segment_total, raw_pdu_sha256, archive_pin, state, created_at, updated_at)
	VALUES ('job-delete', 0, 'archive-delete', ?, ?, 'SM', 7, 'epoch-1', 1, ?,
		1, 1, ?, ?, 'proposed', 100, 100)]],
	{ digest, digest_b, digest_c, digest, digest })
exec(delete_db, "UPDATE stage_jobs SET state = 'validating' WHERE job_id = 'job-delete'")
exec(delete_db, "UPDATE stage_jobs SET state = 'archiving' WHERE job_id = 'job-delete'")
exec(delete_db, "UPDATE stage_jobs SET state = 'ready' WHERE job_id = 'job-delete'")
exec(delete_db, "UPDATE stage_job_items SET state = 'archived' WHERE job_id = 'job-delete'")
exec(delete_db, "UPDATE stage_job_items SET state = 'ready' WHERE job_id = 'job-delete'")
exec(delete_db, [[
	INSERT INTO stage_tombstones (
		tombstone_id, operation, job_id, item_no, principal_id, request_namespace,
		source_identity_digest, storage, storage_index, scan_epoch, source_generation,
		raw_pdu_sha256, state, created_at, updated_at)
	VALUES ('tombstone-delete', 'delete_device', 'job-delete', 0, 'root', 'stagec-worker',
		?, 'SM', 7, 'epoch-1', 1, ?, 'reserved', 100, 100)]],
	{ digest, digest })
exec(delete_db, "UPDATE stage_jobs SET state = 'deleting' WHERE job_id = 'job-delete'")
exec(delete_db, "UPDATE stage_job_items SET state = 'deleting' WHERE job_id = 'job-delete'")
exec(delete_db, [[
	UPDATE stage_job_items SET delete_call_count = 1
	WHERE job_id = 'job-delete' AND item_no = 0 AND state = 'deleting']])
local delete_recovery = assert(worker.recover(delete_db, clock(300)))
assert(delete_recovery.changed and delete_recovery.recovery_incomplete)
assert(one(delete_db, "SELECT state FROM stage_job_items WHERE job_id = 'job-delete'").state == 'unknown')
assert(one(delete_db, "SELECT outcome_unknown FROM stage_job_items WHERE job_id = 'job-delete'").outcome_unknown == 1)
assert(one(delete_db, "SELECT state FROM stage_tombstones WHERE tombstone_id = 'tombstone-delete'").state == 'unknown')
assert(one(delete_db, "SELECT state FROM stage_jobs WHERE job_id = 'job-delete'").state == 'unknown')
assert(one(delete_db, "SELECT COUNT(*) AS count FROM stage_events WHERE event = 'RECOVERY_UNKNOWN'").count == 2)
delete_db:close()

local move_db = new_db()
exec(move_db, [[
	INSERT INTO stage_jobs (
		job_id, request_namespace, request_id, principal_id, operation,
		request_digest, selection_digest, token_digest, snapshot_version,
		worker_generation, state, created_at, updated_at, expires_at)
	VALUES ('job-move', 'stagec-worker', 'request-move', 'root', 'move_local',
		?, ?, ?, 1, 'worker-1', 'accepted', 100, 100, 200)]],
	{ digest, digest_b, digest_c })
exec(move_db, [[
	INSERT INTO stage_job_items (
		job_id, item_no, archive_id, source_identity_digest, content_digest,
		storage, storage_index, scan_epoch, source_generation, source_token_digest,
		segment_no, segment_total, raw_pdu_sha256, archive_pin, state, created_at, updated_at)
	VALUES ('job-move', 0, 'archive-move', ?, ?, 'ME', 8, 'epoch-1', 1, ?,
		1, 1, ?, ?, 'proposed', 100, 100)]],
	{ digest, digest_b, digest_c, digest, digest })
local move_recovery = assert(worker.recover(move_db, clock(300)))
assert(move_recovery.changed and move_recovery.recovery_incomplete)
assert(one(move_db, "SELECT state FROM stage_job_items WHERE job_id = 'job-move'").state == 'blocked')
assert(one(move_db, "SELECT state FROM stage_jobs WHERE job_id = 'job-move'").state == 'blocked')
assert(one(move_db, "SELECT COUNT(*) AS count FROM stage_events WHERE event = 'RECOVERY_BLOCKED'").count == 2)
move_db:close()

local limit_db = new_db()
exec(limit_db, [[
	INSERT INTO stage_jobs (
		job_id, request_namespace, request_id, principal_id, operation,
		request_digest, selection_digest, token_digest, snapshot_version,
		worker_generation, state, created_at, updated_at, expires_at)
	VALUES ('job-limit', 'stagec-worker', 'request-limit', 'root', 'move_local',
		?, ?, ?, 1, 'worker-1', 'accepted', 100, 100, 400)]],
	{ digest, digest_b, digest_c })
for item_no = 0, 5000 do
	exec(limit_db, [[
		INSERT INTO stage_job_items (
			job_id, item_no, archive_id, source_identity_digest, content_digest,
			storage, storage_index, scan_epoch, source_generation, source_token_digest,
			segment_no, segment_total, raw_pdu_sha256, archive_pin, state, created_at, updated_at)
		VALUES ('job-limit', ?, ?, ?, ?, 'SM', ?, 'epoch-limit', 1, ?,
			1, 1, ?, ?, 'proposed', 100, 100)]],
		{ item_no, 'archive-limit-' .. item_no, digest, digest_b, item_no,
			digest_c, digest, digest })
end
local limited = assert(worker.recover(limit_db, clock(300)))
assert(limited.limit_exceeded and limited.recovery_incomplete)
assert(one(limit_db, "SELECT value FROM metadata WHERE key = 'recovery_incomplete'").value == '1')
assert(one(limit_db, "SELECT COUNT(*) AS count FROM stage_events WHERE event = 'RECOVERY_LIMIT'").count == 1)
assert(one(limit_db, "SELECT COUNT(*) AS count FROM stage_job_items WHERE state = 'proposed'").count == 5001)
limit_db:close()

print('stagec-worker.lua: lease ownership, startup recovery and fail-closed state transitions passed')
