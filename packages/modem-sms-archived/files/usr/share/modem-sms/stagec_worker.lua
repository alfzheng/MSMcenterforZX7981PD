local sqlite3 = require('lsqlite3')

local M = {}
local LEASE_SCOPE = 'global'
local MAX_OWNER_ID = 128
local MAX_TTL_SECONDS = 3600
local MAX_RECOVERY_ITEMS = 5000
local MAX_RECOVERY_JOBS = 5000
local unpack_values = table.unpack or unpack

local function sql_ok(code)
	return code == nil or code == 0 or code == sqlite3.OK or code == sqlite3.DONE
end

local function sqlite_error(db, fallback)
	local message = string.upper(tostring(db and db:errmsg() or ''))
	if message:find('BUSY', 1, true) or message:find('LOCKED', 1, true) then
		return 'STAGE_TRANSACTION_BUSY'
	end
	if message:find('FULL', 1, true) then return 'STAGE_STORAGE_FULL' end
	if message:find('IOERR', 1, true) or message:find('I/O', 1, true) then
		return 'STAGE_IO_ERROR'
	end
	if message:find('CONSTRAINT', 1, true)
		or message:find('STAGE_', 1, true)
		or message:find('DELETE_LEASE_REQUIRED', 1, true)
		or message:find('FORBIDDEN', 1, true) then
		return 'STAGE_STATE_CONSTRAINT'
	end
	return fallback
end

local function valid_digest(value)
	return type(value) == 'string'
		and #value == 64
		and not value:find('[^0-9A-Fa-f]')
end

local function valid_owner(value)
	return type(value) == 'string'
		and #value >= 1
		and #value <= MAX_OWNER_ID
		and not value:find('[%z\1-\31\127]')
end

local function valid_storage(value)
	return value == 'SM' or value == 'ME'
end

local function now_value(value)
	value = tonumber(value)
	if not value or value < 1 or value % 1 ~= 0 then return nil end
	return value
end

local function ttl_value(value)
	value = tonumber(value)
	if not value or value < 1 or value > MAX_TTL_SECONDS or value % 1 ~= 0 then return nil end
	return value
end

local function resolve_time(clock)
	if clock == nil then return os.time() end
	if type(clock) ~= 'function' then return nil, 'LEASE_CLOCK_INVALID' end
	local ok, value = pcall(clock)
	if not ok then return nil, 'LEASE_CLOCK_INVALID' end
	value = now_value(value)
	if not value then return nil, 'LEASE_CLOCK_INVALID' end
	return value
end

local function begin(db)
	if not sql_ok(db:exec('BEGIN IMMEDIATE')) then
		return nil, sqlite_error(db, 'STAGE_TRANSACTION_BEGIN_FAILED')
	end
	return true
end

local function rollback(db)
	db:exec('ROLLBACK')
end

local function commit(db)
	if not sql_ok(db:exec('COMMIT')) then
		rollback(db)
		return nil, sqlite_error(db, 'STAGE_DURABLE_COMMIT_FAILED')
	end
	return true
end

local function query_one(db, sql, values)
	local statement = db:prepare(sql)
	if not statement then return nil, sqlite_error(db, 'STAGE_SQL_ERROR') end
	if values and #values > 0 then
		if not sql_ok(statement:bind_values(unpack_values(values))) then
			statement:finalize()
			return nil, sqlite_error(db, 'STAGE_SQL_ERROR')
		end
	end
	local result
	for row in statement:nrows() do
		result = row
		break
	end
	statement:finalize()
	return result
end

local function execute(db, sql, values)
	local statement = db:prepare(sql)
	if not statement then return nil, sqlite_error(db, 'STAGE_SQL_ERROR') end
	if values and #values > 0 then
		if not sql_ok(statement:bind_values(unpack_values(values))) then
			statement:finalize()
			return nil, sqlite_error(db, 'STAGE_SQL_ERROR')
		end
	end
	local code = statement:step()
	statement:finalize()
	if not sql_ok(code) then return nil, sqlite_error(db, 'STAGE_SQL_ERROR') end
	return true
end

local function metadata(db, key)
	local row, err = query_one(db, 'SELECT value FROM metadata WHERE key = ?', { key })
	if not row then return nil, err end
	return row.value
end

local function set_metadata(db, key, value)
	return execute(db, 'UPDATE metadata SET value = ? WHERE key = ?', { value, key })
end

local function lease_row(db)
	return query_one(db, [[
		SELECT owner_id, owner_nonce_digest, storage, lease_generation, state,
		       acquired_at, renewed_at, expires_at
		FROM stage_cpms_leases WHERE lease_scope = 'global']], {})
end

local function lease_result(row)
	return {
		lease_scope = LEASE_SCOPE,
		owner_id = row.owner_id,
		storage = row.storage,
		lease_generation = tonumber(row.lease_generation),
		state = row.state,
		acquired_at = tonumber(row.acquired_at),
		renewed_at = tonumber(row.renewed_at),
		expires_at = tonumber(row.expires_at)
	}
end

local function validate_lease_args(args, require_storage)
	if type(args) ~= 'table' or not valid_owner(args.owner_id)
		or not valid_digest(args.owner_nonce_digest) then
		return nil, 'LEASE_ARGUMENT_INVALID'
	end
	if require_storage and not valid_storage(args.storage) then
		return nil, 'LEASE_STORAGE_INVALID'
	end
	local now, clock_error = resolve_time(args.clock)
	local ttl = ttl_value(args.ttl_seconds)
	if not now or not ttl then return nil, clock_error or 'LEASE_ARGUMENT_INVALID' end
	return { now = now, ttl = ttl }
end

local function record_event(db, job_id, item_no, event, state, detail_code, now)
	return execute(db, [[
		INSERT INTO stage_events (job_id, item_no, event, state, detail_code, created_at)
		VALUES (?, ?, ?, ?, ?, ?)]], { job_id, item_no, event, state, detail_code, now })
end

local function recovery_limit(db, now)
	local ok, err = set_metadata(db, 'recovery_incomplete', '1')
	if not ok then return nil, err end
	local event_ok, event_err = record_event(db, nil, nil, 'RECOVERY_LIMIT',
		'blocked', 'RECOVERY_INCOMPLETE', now)
	if not event_ok then return nil, event_err end
	return { changed = true, recovery_incomplete = true, limit_exceeded = true }
end

local function recover_pending(db, now)
	local changed = false
	local lease = lease_row(db)
	if lease and lease.state == 'active' then
		local ok, err = execute(db, [[
			UPDATE stage_cpms_leases
			SET state = 'lost', renewed_at = ?
			WHERE lease_scope = 'global' AND state = 'active']], { now })
		if not ok then return nil, err end
		local event_ok, event_err = record_event(db, nil, nil, 'LEASE_LOST',
			'blocked', 'RECOVERY_INCOMPLETE', now)
		if not event_ok then return nil, event_err end
		changed = true
	end

	local items, items_error = query_one(db, [[
		SELECT COUNT(*) AS count FROM stage_job_items
		WHERE state IN ('proposed', 'archived', 'ready', 'deleting')]], {})
	if not items then return nil, items_error end
	if tonumber(items.count) and tonumber(items.count) > MAX_RECOVERY_ITEMS then
		return recovery_limit(db, now)
	end
	if tonumber(items.count) and tonumber(items.count) > 0 then
		local statement = db:prepare([[
			SELECT i.job_id, i.item_no, i.state, i.delete_call_count
			FROM stage_job_items AS i
			WHERE i.state IN ('proposed', 'archived', 'ready', 'deleting')
			ORDER BY i.job_id, i.item_no]])
		if not statement then return nil, 'STAGE_SQL_ERROR' end
		local pending = {}
		for row in statement:nrows() do pending[#pending + 1] = row end
		statement:finalize()
		for _, row in ipairs(pending) do
			local unknown = row.state == 'deleting' or tonumber(row.delete_call_count) == 1
			local next_state = unknown and 'unknown' or 'blocked'
			local ok, err = execute(db, [[
				UPDATE stage_job_items
				SET state = ?, outcome_unknown = ?, error_code = 'RECOVERY_INCOMPLETE',
				    updated_at = ?
				WHERE job_id = ? AND item_no = ? AND state IN
				    ('proposed', 'archived', 'ready', 'deleting')]],
				{ next_state, unknown and 1 or 0, now, row.job_id, row.item_no })
			if not ok then return nil, err end
			local event_ok, event_err = record_event(db, row.job_id, row.item_no,
				unknown and 'RECOVERY_UNKNOWN' or 'RECOVERY_BLOCKED', next_state,
				'RECOVERY_INCOMPLETE', now)
			if not event_ok then return nil, event_err end
			changed = true
		end
	end

	local tombstone_statement = db:prepare([[
		SELECT tombstone_id, job_id, item_no, state
		FROM stage_tombstones WHERE state = 'reserved'
		ORDER BY tombstone_id]])
	if not tombstone_statement then return nil, 'STAGE_SQL_ERROR' end
	local tombstones = {}
	for row in tombstone_statement:nrows() do tombstones[#tombstones + 1] = row end
	tombstone_statement:finalize()
	for _, row in ipairs(tombstones) do
		local item = query_one(db,
			'SELECT state FROM stage_job_items WHERE job_id = ? AND item_no = ?',
			{ row.job_id, row.item_no })
		if item and (item.state == 'unknown' or item.state == 'blocked') then
			local ok, err = execute(db,
				'UPDATE stage_tombstones SET state = ?, updated_at = ? '
				.. 'WHERE tombstone_id = ? AND state = \'reserved\'',
				{ item.state, now, row.tombstone_id })
			if not ok then return nil, err end
			changed = true
		end
	end

	local jobs, jobs_error = query_one(db, [[
		SELECT COUNT(*) AS count FROM stage_jobs
		WHERE state IN ('accepted', 'validating', 'archiving', 'ready', 'deleting')]], {})
	if not jobs then return nil, jobs_error end
	if tonumber(jobs.count) and tonumber(jobs.count) > MAX_RECOVERY_JOBS then
		return recovery_limit(db, now)
	end
	if tonumber(jobs.count) and tonumber(jobs.count) > 0 then
		local statement = db:prepare([[
			SELECT j.job_id, j.state,
			       EXISTS (SELECT 1 FROM stage_job_items AS i
			               WHERE i.job_id = j.job_id AND i.state = 'unknown') AS has_unknown
			FROM stage_jobs AS j
			WHERE j.state IN ('accepted', 'validating', 'archiving', 'ready', 'deleting')
			ORDER BY j.job_id]])
		if not statement then return nil, 'STAGE_SQL_ERROR' end
		local pending = {}
		for row in statement:nrows() do pending[#pending + 1] = row end
		statement:finalize()
		for _, row in ipairs(pending) do
			local unknown = row.state == 'deleting' or tonumber(row.has_unknown) == 1
			local next_state = unknown and 'unknown' or 'blocked'
			local ok, err = execute(db, [[
				UPDATE stage_jobs
				SET state = ?, error_code = 'RECOVERY_INCOMPLETE', updated_at = ?
				WHERE job_id = ? AND state IN
				    ('accepted', 'validating', 'archiving', 'ready', 'deleting')]],
				{ next_state, now, row.job_id })
			if not ok then return nil, err end
			local event_ok, event_err = record_event(db, row.job_id, nil,
				unknown and 'RECOVERY_UNKNOWN' or 'RECOVERY_BLOCKED', next_state,
				'RECOVERY_INCOMPLETE', now)
			if not event_ok then return nil, event_err end
			changed = true
		end
	end

	if changed then
		local ok, err = set_metadata(db, 'recovery_incomplete', '1')
		if not ok then return nil, err end
	end
	return { changed = changed, recovery_incomplete = changed }
end

function M.recover(db, clock)
	if not db then return nil, 'STAGE_DATABASE_INVALID' end
	local now, clock_error = resolve_time(clock)
	if not now then return nil, clock_error end
	local started, start_error = begin(db)
	if not started then return nil, start_error end
	local recovery, recovery_error = metadata(db, 'recovery_incomplete')
	if recovery == nil then
		rollback(db)
		return nil, recovery_error or 'STAGE_METADATA_UNAVAILABLE'
	end
	if recovery ~= '0' then
		rollback(db)
		return { changed = false, recovery_incomplete = true }
	end
	local result, result_error = recover_pending(db, now)
	if not result then
		rollback(db)
		return nil, result_error
	end
	local committed, commit_error = commit(db)
	if not committed then return nil, commit_error end
	return result
end

function M.acquire(db, args)
	if not db then return nil, 'STAGE_DATABASE_INVALID' end
	local normalized, validation_error = validate_lease_args(args, true)
	if not normalized then return nil, validation_error end
	local started, start_error = begin(db)
	if not started then return nil, start_error end
	local recovery, recovery_error = metadata(db, 'recovery_incomplete')
	local gate, gate_error = metadata(db, 'stage_c_delete_enabled')
	if recovery == nil or gate == nil then
		rollback(db)
		return nil, recovery_error or gate_error or 'STAGE_METADATA_UNAVAILABLE'
	end
	if recovery ~= '0' then rollback(db); return nil, 'RECOVERY_INCOMPLETE' end
	if gate ~= '0' then rollback(db); return nil, 'STAGE_C_GATE_INVALID' end
	local row, row_error = lease_row(db)
	if row_error then rollback(db); return nil, row_error end
	local now = normalized.now
	local expires = now + normalized.ttl
	if not row then
		local ok, err = execute(db, [[
			INSERT INTO stage_cpms_leases (
				lease_scope, owner_id, owner_nonce_digest, storage, lease_generation,
				state, acquired_at, renewed_at, expires_at)
			VALUES ('global', ?, ?, ?, 1, 'active', ?, ?, ?)]],
			{ args.owner_id, args.owner_nonce_digest, args.storage, now, now, expires })
		if not ok then rollback(db); return nil, err end
	else
		if row.state == 'active' and tonumber(row.expires_at) > now then
			rollback(db)
			return nil, 'LEASE_BUSY'
		end
		if row.state == 'active' then
			local recovered, recover_error = recover_pending(db, now)
			if not recovered then rollback(db); return nil, recover_error end
			local committed, commit_error = commit(db)
			if not committed then return nil, commit_error end
			return nil, 'RECOVERY_INCOMPLETE'
		end
		local generation = tonumber(row.lease_generation) + 1
		local ok, err = execute(db, [[
			UPDATE stage_cpms_leases
			SET owner_id = ?, owner_nonce_digest = ?, storage = ?,
			    lease_generation = ?, state = 'active', acquired_at = ?,
			    renewed_at = ?, expires_at = ?
			WHERE lease_scope = 'global']],
			{ args.owner_id, args.owner_nonce_digest, args.storage, generation,
				now, now, expires })
		if not ok then rollback(db); return nil, err end
	end
	local committed, commit_error = commit(db)
	if not committed then return nil, commit_error end
	local active = lease_row(db)
	return active and lease_result(active) or nil, active and nil or 'LEASE_UNAVAILABLE'
end

local function owner_matches(row, args)
	return row and row.state == 'active'
		and row.owner_id == args.owner_id
		and row.owner_nonce_digest == args.owner_nonce_digest
		and row.storage == args.storage
		and tonumber(row.lease_generation) == tonumber(args.lease_generation)
end

function M.renew(db, args)
	if not db then return nil, 'STAGE_DATABASE_INVALID' end
	local normalized, validation_error = validate_lease_args(args, true)
	local generation = type(args) == 'table' and tonumber(args.lease_generation) or nil
	if not normalized or not generation or generation < 1 or generation % 1 ~= 0 then
		return nil, validation_error or 'LEASE_ARGUMENT_INVALID'
	end
	local started, start_error = begin(db)
	if not started then return nil, start_error end
	local row, row_error = lease_row(db)
	if row_error then rollback(db); return nil, row_error end
	if not owner_matches(row, args) then rollback(db); return nil, 'LEASE_NOT_OWNER' end
	if tonumber(row.expires_at) <= normalized.now then
		local recovered, recover_error = recover_pending(db, normalized.now)
		if not recovered then rollback(db); return nil, recover_error end
		local committed, commit_error = commit(db)
		if not committed then return nil, commit_error end
		return nil, 'LEASE_EXPIRED'
	end
	local ok, err = execute(db, [[
		UPDATE stage_cpms_leases SET renewed_at = ?, expires_at = ?
		WHERE lease_scope = 'global' AND state = 'active']],
		{ normalized.now, normalized.now + normalized.ttl })
	if not ok then rollback(db); return nil, err end
	local committed, commit_error = commit(db)
	if not committed then return nil, commit_error end
	return lease_result(lease_row(db))
end

function M.release(db, args)
	if not db then return nil, 'STAGE_DATABASE_INVALID' end
	local generation = type(args) == 'table' and tonumber(args.lease_generation) or nil
	if type(args) ~= 'table' or not generation or generation < 1 or generation % 1 ~= 0 then
		return nil, 'LEASE_ARGUMENT_INVALID'
	end
	local normalized, validation_error = validate_lease_args(args, true)
	if not normalized then return nil, validation_error end
	local started, start_error = begin(db)
	if not started then return nil, start_error end
	local row, row_error = lease_row(db)
	if row_error then rollback(db); return nil, row_error end
	if not owner_matches(row, args) then rollback(db); return nil, 'LEASE_NOT_OWNER' end
	if tonumber(row.expires_at) <= normalized.now then
		local recovered, recover_error = recover_pending(db, normalized.now)
		if not recovered then rollback(db); return nil, recover_error end
		local committed, commit_error = commit(db)
		if not committed then return nil, commit_error end
		return nil, 'LEASE_EXPIRED'
	end
	local ok, err = execute(db, [[
		UPDATE stage_cpms_leases SET state = 'released', renewed_at = ?
		WHERE lease_scope = 'global' AND state = 'active']], { normalized.now })
	if not ok then rollback(db); return nil, err end
	local committed, commit_error = commit(db)
	if not committed then return nil, commit_error end
	return lease_result(lease_row(db))
end

M.validate_digest = valid_digest
M.validate_owner = valid_owner

return M
