local sqlite3 = require('lsqlite3')

local M = {}
local SCHEMA_PATH = '/usr/share/modem-sms/archive_schema.sql'
local MAX_PAGE_COUNT = 1280
local JOURNAL_SIZE_LIMIT = 524288
local TRANSACTION_PEAK = 524288
local WAL_AUTOCHECKPOINT = 100

local function is_ok(code)
	return code == nil or code == 0 or code == sqlite3.OK
end

local function fail(store, code)
	return nil, code or (store and store.db:errmsg()) or 'SQLITE_ERROR'
end

local function read_file(path)
	local file = io.open(path, 'rb')
	if not file then return nil end
	local value = file:read('*a')
	file:close()
	return value
end

local function file_size(path)
	local file = io.open(path, 'rb')
	if not file then return 0 end
	local size = file:seek('end') or 0
	file:close()
	return size
end

local function free_bytes(path)
	local probe = path
	local file = io.open(path, 'rb')
	if file then
		file:close()
	else
		probe = path:match('^(.*)/[^/]+$') or path
	end
	local pipe = io.popen('/bin/df -Pk ' .. probe .. ' 2>/dev/null', 'r')
	if not pipe then return nil end
	local available
	for line in pipe:lines() do
		local value = line:match('^%S+%s+%d+%s+%d+%s+(%d+)%s+')
		if value then available = tonumber(value) * 1024 end
	end
	pipe:close()
	return available
end

local function scalar(store, sql, values)
	local statement = store.db:prepare(sql)
	if not statement then return fail(store) end
	if values and #values > 0 then
		local code = statement:bind_values(unpack(values))
		if not is_ok(code) then
			statement:finalize()
			return fail(store)
		end
	end
	local result
	for row in statement:nrows() do
		result = row[1]
		break
	end
	statement:finalize()
	return result
end

local function rows(store, sql, values)
	local statement = store.db:prepare(sql)
	if not statement then return fail(store) end
	if values and #values > 0 then
		local code = statement:bind_values(unpack(values))
		if not is_ok(code) then
			statement:finalize()
			return fail(store)
		end
	end
	local result = {}
	for row in statement:nrows() do
		result[#result + 1] = row
	end
	statement:finalize()
	return result
end

local function escape_like(value)
	return (value:gsub('\\', '\\\\'):gsub('%%', '\\%%'):gsub('_', '\\_'))
end

local function masked_number(value)
	if not value or #value <= 4 then return value and '****' or nil end
	return string.rep('*', #value - 4) .. value:sub(-4)
end

local function normalize_limit(value, maximum)
	value = tonumber(value) or 10
	if value ~= 10 and value ~= 20 and value ~= 50 and value ~= 100 then value = 10 end
	return math.min(value, maximum or 100)
end

local function normalize_journal_mode(value)
	local mode = string.upper(tostring(value or 'DELETE'))
	if mode ~= 'DELETE' and mode ~= 'WAL' then
		return nil, 'ARCHIVE_JOURNAL_MODE_INVALID'
	end
	return mode
end

local function ensure_column(db, table_name, column_name, definition)
	local statement = db:prepare('PRAGMA table_info("' .. table_name .. '")')
	if not statement then return nil, db:errmsg() or 'ARCHIVE_SCHEMA_MIGRATION_FAILED' end
	local present = false
	for row in statement:nrows() do
		if row.name == column_name then
			present = true
			break
		end
	end
	statement:finalize()
	if present then return true end
	local code = db:exec('ALTER TABLE "' .. table_name .. '" ADD COLUMN "'
		.. column_name .. '" ' .. definition)
	if not is_ok(code) then return nil, db:errmsg() or 'ARCHIVE_SCHEMA_MIGRATION_FAILED' end
	return true
end

local function table_exists(db, table_name)
	local statement = db:prepare(
		"SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?")
	if not statement then return nil, 'ARCHIVE_SCHEMA_MIGRATION_FAILED' end
	if not is_ok(statement:bind_values(table_name)) then
		statement:finalize()
		return nil, 'ARCHIVE_SCHEMA_MIGRATION_FAILED'
	end
	local present = false
	for _ in statement:nrows() do
		present = true
		break
	end
	statement:finalize()
	return present
end

local function ensure_stage_job_columns(db)
	local present, err = table_exists(db, 'stage_jobs')
	if present == nil then return nil, err end
	if not present then return true end
	local columns = {
		{ 'lease_generation', 'INTEGER NOT NULL DEFAULT 0' },
		{ 'lease_acquired_at', 'INTEGER NOT NULL DEFAULT 0' },
		{ 'lease_owner_id', "TEXT NOT NULL DEFAULT ''" },
		{ 'lease_nonce_digest', "TEXT NOT NULL DEFAULT ''" },
		{ 'lease_storage', 'TEXT' }
	}
	for _, column in ipairs(columns) do
		local ok, column_error = ensure_column(db, 'stage_jobs', column[1], column[2])
		if not ok then return nil, column_error end
	end
	return true
end

local function migrate_schema(db, transaction_active)
	local owns_transaction = not transaction_active
	if owns_transaction then
		local begin_code = db:exec('BEGIN IMMEDIATE')
		if not is_ok(begin_code) then return nil, db:errmsg() or 'ARCHIVE_SCHEMA_MIGRATION_FAILED' end
	end
	local columns = {
		{ 'source_token_digest', "TEXT NOT NULL DEFAULT ''" },
		{ 'segment_no', 'INTEGER NOT NULL DEFAULT 1' },
		{ 'segment_total', 'INTEGER NOT NULL DEFAULT 1' }
	}
	for _, column in ipairs(columns) do
		local ok, err = ensure_column(db, 'message_sources', column[1], column[2])
		if not ok then
			if owns_transaction then db:exec('ROLLBACK') end
			return nil, err
		end
	end
	local stage_ok, stage_error = ensure_stage_job_columns(db)
	if not stage_ok then
		if owns_transaction then db:exec('ROLLBACK') end
		return nil, stage_error
	end
	local code = db:exec("UPDATE metadata SET value = '2' WHERE key = 'schema_version' "
		.. "AND CAST(value AS INTEGER) < 2")
	if not is_ok(code) then
		if owns_transaction then db:exec('ROLLBACK') end
		return nil, db:errmsg() or 'ARCHIVE_SCHEMA_MIGRATION_FAILED'
	end
	code = db:exec("INSERT OR IGNORE INTO metadata(key, value) VALUES "
		.. "('stage_c_schema_version', '1'), ('stage_c_delete_enabled', '0')")
	if not is_ok(code) then
		if owns_transaction then db:exec('ROLLBACK') end
		return nil, db:errmsg() or 'ARCHIVE_SCHEMA_MIGRATION_FAILED'
	end
	if owns_transaction then
		code = db:exec('COMMIT')
		if not is_ok(code) then
			db:exec('ROLLBACK')
			return nil, db:errmsg() or 'ARCHIVE_SCHEMA_MIGRATION_FAILED'
		end
	end
	return true
end

local function capacity_snapshot(path, max_bytes, min_free_bytes)
	local main = file_size(path)
	local wal = file_size(path .. '-wal')
	local shm = file_size(path .. '-shm')
	local journal = file_size(path .. '-journal')
	local available = free_bytes(path)
	local persistent_bytes = main + wal + shm + journal
	local peak_ok = persistent_bytes + TRANSACTION_PEAK <= max_bytes
	local free_ok = available ~= nil and available - TRANSACTION_PEAK >= min_free_bytes
	return {
		archive_max_bytes = max_bytes,
		archive_min_free_bytes = min_free_bytes,
		persistent_bytes = persistent_bytes,
		main_bytes = main,
		wal_bytes = wal,
		shm_bytes = shm,
		journal_bytes = journal,
		available_bytes = available,
		transaction_peak_bytes = TRANSACTION_PEAK,
		capacity_ok = peak_ok and free_ok,
		error_code = available == nil and 'ARCHIVE_CAPACITY_UNVERIFIED'
			or (peak_ok and free_ok and nil or 'ARCHIVE_FULL')
	}
end

local Store = {}
Store.__index = Store

function Store:close()
	if self.db then
		self.db:close()
		self.db = nil
	end
end

function Store:metadata(key)
	local value, err = scalar(self, 'SELECT value FROM metadata WHERE key = ?', { key })
	if value == nil and err then return nil, err end
	return value
end

function Store:snapshot_version()
	return tonumber(self:metadata('snapshot_version') or '0') or 0
end

function Store:capacity()
	return capacity_snapshot(self.path, self.max_bytes, self.min_free_bytes)
end

function Store:verify()
	local integrity, integrity_err = scalar(self, 'PRAGMA integrity_check')
	if integrity == nil then return fail(self, integrity_err) end
	local page_count = tonumber(scalar(self, 'PRAGMA page_count') or '0') or 0
	local page_size = tonumber(scalar(self, 'PRAGMA page_size') or '0') or 0
	local max_page_count = tonumber(scalar(self, 'PRAGMA max_page_count') or '0') or 0
	local journal_mode = scalar(self, 'PRAGMA journal_mode')
	local journal_mode_normalized = journal_mode and string.upper(tostring(journal_mode)) or nil
	local recovery = self:metadata('recovery_incomplete')
	local schema_version = tonumber(self:metadata('schema_version') or '0') or 0
	local stage_schema_version = tonumber(self:metadata('stage_c_schema_version') or '0') or 0
	local stage_c_delete_enabled = self:metadata('stage_c_delete_enabled') or '0'
	local capacity = self:capacity()
	local foreign_keys = tonumber(scalar(self, 'PRAGMA foreign_keys') or '0') or 0
	local foreign_keys_ok = foreign_keys == 1
	local invalid_message_digests = tonumber(scalar(self,
		"SELECT COUNT(*) FROM messages WHERE "
		.. "length(source_identity_digest) <> 64 OR source_identity_digest GLOB '*[^0-9A-Fa-f]*' "
		.. "OR length(content_digest) <> 64 OR content_digest GLOB '*[^0-9A-Fa-f]*'") or '1') or 1
	local invalid_source_digests = tonumber(scalar(self,
		"SELECT COUNT(*) FROM message_sources WHERE "
		.. "length(raw_pdu_sha256) <> 64 OR raw_pdu_sha256 GLOB '*[^0-9A-Fa-f]*' "
		.. "OR (source_token_digest <> '' AND (length(source_token_digest) <> 64 "
		.. "OR source_token_digest GLOB '*[^0-9A-Fa-f]*'))") or '1') or 1
	local source_integrity_ok = invalid_message_digests == 0 and invalid_source_digests == 0
	local journal_mode_ok = journal_mode_normalized == self.journal_mode
	local stage_c_gate_ok = stage_c_delete_enabled == '0'
	local schema_ok = schema_version >= 2 and stage_schema_version >= 1 and stage_c_gate_ok
	local layout_ok = page_size == 4096 and max_page_count == MAX_PAGE_COUNT and journal_mode_ok
		and page_count > 0 and page_count <= MAX_PAGE_COUNT
	local ok = integrity == 'ok' and layout_ok and schema_ok and foreign_keys_ok
		and source_integrity_ok and recovery == '0' and capacity.capacity_ok
	return {
		ok = ok,
		integrity_check = integrity,
		page_count = page_count,
		page_size = page_size,
		max_page_count = max_page_count,
		layout_ok = layout_ok,
		foreign_keys = foreign_keys,
		foreign_keys_ok = foreign_keys_ok,
		invalid_message_digests = invalid_message_digests,
		invalid_source_digests = invalid_source_digests,
		source_integrity_ok = source_integrity_ok,
		schema_version = schema_version,
		stage_c_schema_version = stage_schema_version,
		stage_c_delete_enabled = stage_c_delete_enabled == '1',
		stage_c_gate_ok = stage_c_gate_ok,
		schema_ok = schema_ok,
		journal_mode = journal_mode_normalized,
		journal_mode_ok = journal_mode_ok,
		wal_autocheckpoint = WAL_AUTOCHECKPOINT,
		snapshot_version = self:snapshot_version(),
		recovery_incomplete = recovery ~= '0',
		capacity = capacity,
		error_code = ok and nil or (integrity ~= 'ok' and 'ARCHIVE_VERIFY_FAILED'
			or not layout_ok and 'ARCHIVE_LAYOUT_INVALID'
			or not foreign_keys_ok and 'ARCHIVE_FOREIGN_KEYS_DISABLED'
			or not source_integrity_ok and 'ARCHIVE_SOURCE_IDENTITY_INVALID'
			or not stage_c_gate_ok and 'STAGE_C_GATE_INVALID'
			or not schema_ok and 'ARCHIVE_SCHEMA_OUTDATED'
			or recovery ~= '0' and 'RECOVERY_INCOMPLETE' or capacity.error_code)
	}
end

local function build_filters(args, after)
	local clauses = { 'deleted_at IS NULL', '(? = \'all\' OR direction = ?)' }
	local values = { args.box, args.box }
	local pattern = args.pattern
	if pattern then
		local fields = args.query_fields
		if not fields or #fields == 0 then
			fields = { 'direction', 'original_source', 'archive_quality', 'association_trust' }
		end
		local allowed = {
			direction = true,
			original_source = true,
			archive_quality = true,
			association_trust = true
		}
		local search = {}
		for _, field in ipairs(fields) do
			if not allowed[field] then return nil, 'PERMISSION_DENIED' end
			search[#search + 1] = field .. ' LIKE ? ESCAPE \'\\\''
			values[#values + 1] = pattern
		end
		if #search == 0 then return nil, 'QUERY_FIELDS_UNSUPPORTED' end
		clauses[#clauses + 1] = '(' .. table.concat(search, ' OR ') .. ')'
	end
	if after then
		clauses[#clauses + 1] = '(COALESCE(message_time, 0) < ? OR '
			.. '(COALESCE(message_time, 0) = ? AND archive_id < ?))'
		values[#values + 1] = after.message_time
		values[#values + 1] = after.message_time
		values[#values + 1] = after.archive_id
	end
	return table.concat(clauses, ' AND '), values
end

function Store:page(args, after)
	local where, values_or_error = build_filters(args, after)
	if not where then return fail(self, values_or_error) end
	local values = values_or_error
	local sql = 'SELECT archive_id, direction, number, message_time, encoding, '
		.. 'segments_expected, segments_received, complete, archive_quality, '
		.. 'association_trust, lossless_archivable, original_source, '
		.. 'first_archived_at, updated_at FROM messages WHERE ' .. where
		.. ' ORDER BY COALESCE(message_time, 0) DESC, archive_id DESC LIMIT ?'
	local limit = normalize_limit(args.limit, self.page_limit_max)
	values[#values + 1] = limit + 1
	local result, err = rows(self, sql, values)
	if not result then return fail(self, err) end
	local has_more = #result > limit
	if has_more then result[#result] = nil end
	local items = {}
	for _, row in ipairs(result) do
		items[#items + 1] = {
			archive_id = row.archive_id,
			direction = row.direction,
			number_masked = masked_number(row.number),
			message_time = row.message_time,
			encoding = row.encoding,
			segments_expected = row.segments_expected,
			segments_received = row.segments_received,
			complete = row.complete == 1,
			archive_quality = row.archive_quality,
			association_trust = row.association_trust,
			lossless_archivable = row.lossless_archivable == 1,
			original_source = row.original_source,
			first_archived_at = row.first_archived_at,
			updated_at = row.updated_at
		}
	end
	local count_where, count_values_or_error = build_filters(args, nil)
	if not count_where then return fail(self, count_values_or_error) end
	local count_sql = 'SELECT COUNT(*) FROM messages WHERE ' .. count_where
	local count_values = count_values_or_error
	local filtered_count, count_err = scalar(self, count_sql, count_values)
	if filtered_count == nil then return fail(self, count_err) end
	return {
		items = items,
		has_more = has_more,
		page_size = limit,
		filtered_count = tonumber(filtered_count) or 0,
		snapshot_version = self:snapshot_version()
	}
end

function Store:get(archive_id)
	local result, err = rows(self, 'SELECT archive_id, source_identity_digest, content_digest, '
		.. 'direction, number, message_time, encoding, segments_expected, '
		.. 'segments_received, complete, archive_quality, association_trust, '
		.. 'lossless_archivable, original_source, first_archived_at, updated_at '
		.. 'FROM messages WHERE archive_id = ? AND deleted_at IS NULL', { archive_id })
	if not result then return fail(self, err) end
	if #result == 0 then return fail(self, 'MESSAGE_NOT_FOUND') end
	local row = result[1]
	local message = {
		archive_id = row.archive_id,
		source_identity_digest = row.source_identity_digest,
		content_digest = row.content_digest,
		direction = row.direction,
		number_masked = masked_number(row.number),
		message_time = row.message_time,
		encoding = row.encoding,
		segments_expected = row.segments_expected,
		segments_received = row.segments_received,
		complete = row.complete == 1,
		archive_quality = row.archive_quality,
		association_trust = row.association_trust,
		lossless_archivable = row.lossless_archivable == 1,
		original_source = row.original_source,
		first_archived_at = row.first_archived_at,
		updated_at = row.updated_at
	}
	return message
end

function M.random_token()
	local file = io.open('/dev/urandom', 'rb')
	if not file then return nil end
	local bytes = file:read(32)
	file:close()
	if not bytes or #bytes ~= 32 then return nil end
	return (bytes:gsub('.', function(value) return string.format('%02x', string.byte(value)) end))
end

function M.open(path, options)
	if path ~= '/root/modem-sms/archive.sqlite3' then return nil, 'ARCHIVE_PATH_UNSAFE' end
	options = options or {}
	local schema = read_file(SCHEMA_PATH)
	if not schema then return nil, 'ARCHIVE_SCHEMA_UNAVAILABLE' end
	local journal_mode, journal_error = normalize_journal_mode(options.journal_mode)
	if not journal_mode then return nil, journal_error end
	local max_bytes = tonumber(options.archive_max_bytes) or 5242880
	local min_free_bytes = tonumber(options.archive_min_free_bytes) or 12582912
	local preflight, preflight_error = M.preflight(path, {
		archive_max_bytes = max_bytes,
		archive_min_free_bytes = min_free_bytes
	})
	if not preflight then return nil, preflight_error end
	local db = sqlite3.open(path)
	if not db then return nil, 'ARCHIVE_OPEN_FAILED' end
	if not is_ok(db:exec('PRAGMA foreign_keys = ON')) then
		local error_code = db:errmsg()
		db:close()
		return nil, error_code or 'ARCHIVE_FOREIGN_KEYS_DISABLED'
	end
	local store = setmetatable({
		db = db,
		path = path,
		max_bytes = max_bytes,
		min_free_bytes = min_free_bytes,
		page_limit_max = tonumber(options.page_limit_max) or 100,
		journal_mode = journal_mode
	}, Store)
	local pragmas = 'PRAGMA foreign_keys = ON; PRAGMA synchronous = FULL; '
		.. 'PRAGMA page_size = 4096; PRAGMA max_page_count = ' .. MAX_PAGE_COUNT .. '; '
		.. 'PRAGMA journal_size_limit = ' .. JOURNAL_SIZE_LIMIT .. '; '
		.. 'PRAGMA busy_timeout = 2000; '
		.. 'PRAGMA journal_mode = ' .. string.lower(journal_mode) .. '; '
		.. 'PRAGMA wal_autocheckpoint = ' .. WAL_AUTOCHECKPOINT .. ';'
	if not is_ok(db:exec(pragmas)) then
		local error_code = db:errmsg()
		store:close()
		return nil, error_code or 'ARCHIVE_SCHEMA_FAILED'
	end
	local schema_begin = db:exec('BEGIN IMMEDIATE')
	if not is_ok(schema_begin) then
		local error_code = db:errmsg()
		store:close()
		return nil, error_code or 'ARCHIVE_SCHEMA_MIGRATION_FAILED'
	end
	local stage_columns_ok, stage_columns_error = ensure_stage_job_columns(db)
	if not stage_columns_ok then
		db:exec('ROLLBACK')
		store:close()
		return nil, stage_columns_error or 'ARCHIVE_SCHEMA_MIGRATION_FAILED'
	end
	if not is_ok(db:exec(schema)) then
		local error_code = db:errmsg()
		db:exec('ROLLBACK')
		store:close()
		return nil, error_code or 'ARCHIVE_SCHEMA_FAILED'
	end
	local migrated, migration_error = migrate_schema(db, true)
	if not migrated then
		db:exec('ROLLBACK')
		store:close()
		return nil, migration_error
	end
	if not is_ok(db:exec('COMMIT')) then
		local error_code = db:errmsg()
		db:exec('ROLLBACK')
		store:close()
		return nil, error_code or 'ARCHIVE_SCHEMA_MIGRATION_FAILED'
	end
	return store
end

function M.preflight(path, options)
	if path ~= '/root/modem-sms/archive.sqlite3' then return nil, 'ARCHIVE_PATH_UNSAFE' end
	options = options or {}
	local max_bytes = tonumber(options.archive_max_bytes) or 5242880
	local min_free_bytes = tonumber(options.archive_min_free_bytes) or 12582912
	local result = capacity_snapshot(path, max_bytes, min_free_bytes)
	return result.capacity_ok and result or nil, result.error_code
end

M.Store = Store
M.escape_like = escape_like
M.normalize_limit = normalize_limit
M.migrate_schema = migrate_schema

return M
