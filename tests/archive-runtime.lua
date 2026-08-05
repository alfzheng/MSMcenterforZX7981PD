#!/usr/bin/lua

package.path = 'packages/modem-sms-archived/files/usr/share/modem-sms/?.lua;' .. package.path
local archive_store = require('archive_store')

local valid_options = {
	archive_max_bytes = 5242880,
	archive_min_free_bytes = 12582912,
	journal_mode = 'DELETE'
}

local valid, valid_error = archive_store.preflight('/root/modem-sms/archive.sqlite3', valid_options)
assert(valid and valid.capacity_ok, 'valid capacity preflight failed: ' .. tostring(valid_error))

local invalid, invalid_error = archive_store.preflight('/root/modem-sms/archive.sqlite3', {
	archive_max_bytes = 5242880,
	archive_min_free_bytes = 'not-a-number',
	journal_mode = 'DELETE'
})
assert(not invalid and invalid_error == 'ARCHIVE_CAPACITY_UNVERIFIED',
	'invalid capacity string did not fail closed: ' .. tostring(invalid_error))

local unsafe, unsafe_error = archive_store.open('/tmp/archive.sqlite3', valid_options)
assert(not unsafe and unsafe_error == 'ARCHIVE_PATH_UNSAFE',
	'non-fixed archive path was not rejected: ' .. tostring(unsafe_error))

local store, open_error = archive_store.open('/root/modem-sms/archive.sqlite3', valid_options)
assert(store, 'target archive open failed: ' .. tostring(open_error))
local verification, verify_error = store:verify()
assert(verification and verification.ok, 'target archive verify failed: ' .. tostring(verify_error))
store:close()

print('archive-runtime.lua: target capacity, fixed-path, parent guard and verify checks passed')
