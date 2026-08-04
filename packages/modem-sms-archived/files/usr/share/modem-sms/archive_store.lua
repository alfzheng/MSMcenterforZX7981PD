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
	local capacity = self:capacity()
	local journal_mode_ok = journal_mode_normalized == self.journal_mode
	local layout_ok = page_size == 4096 and max_page_count == MAX_PAGE_COUNT and journal_mode_ok
		and page_count > 0 and page_count <= MAX_PAGE_COUNT
	local ok = integrity == 'ok' and layout_ok and recovery == '0' and capacity.capacity_ok
	return {
		ok = ok,
		integrity_check = integrity,
		page_count = page_count,
		page_size = page_size,
		max_page_count = max_page_count,
		layout_ok = layout_ok,
		journal_mode = journal_mode_normalized,
		journal_mode_ok = journal_mode_ok,
		wal_autocheckpoint = WAL_AUTOCHECKPOINT,
		snapshot_version = self:snapshot_version(),
		recovery_incomplete = recovery ~= '0',
		capacity = capacity,
		error_code = ok and nil or (integrity ~= 'ok' and 'ARCHIVE_VERIFY_FAILED'
			or not layout_ok and 'ARCHIVE_LAYOUT_INVALID'
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
	if not is_ok(db:exec(pragmas)) or not is_ok(db:exec(schema)) then
		local error_code = db:errmsg()
		store:close()
		return nil, error_code or 'ARCHIVE_SCHEMA_FAILED'
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

return M
