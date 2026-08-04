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
assert(/\+lsqlite3/.test(makefile) && /\+libsqlite3-0/.test(makefile),
	'SQLite runtime dependencies missing');
assert(/\+lua/.test(makefile) && /\+libubus-lua/.test(makefile),
	'Lua/ubus runtime dependencies missing');
assert(/\+libubox-lua/.test(makefile), 'Lua uloop runtime dependency missing');
assert(/\/root\/modem-sms\//.test(init), 'archive init must use the fixed data directory');
assert(/umask 077/.test(init), 'archive init must set a restrictive umask');
assert(/install -m 600 \/dev\/null/.test(init) && /chmod 600/.test(init),
	'archive database must be initialized with mode 0600');
assert(/option cursor_max '128'/.test(config), 'cursor limit default missing');
assert(/option journal_mode 'DELETE'/.test(config), 'journal mode default missing');
assert(/CREATE TABLE IF NOT EXISTS metadata/.test(schema), 'metadata schema missing');
assert(/CREATE TABLE IF NOT EXISTS messages/.test(schema), 'messages schema missing');
assert(/CREATE TABLE IF NOT EXISTS message_sources/.test(schema), 'source schema missing');
assert(/bind_values/.test(store), 'archive SQL inputs must use bound parameters');
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
const archiveRead = acl['luci-app-modem-sms'].read.ubus['modem.sms'];
assert(archiveRead.includes('archive_capabilities') && archiveRead.includes('messages_page'),
	'LuCI metadata archive read methods missing');
assert(!archiveRead.includes('archive_verify') && !archiveRead.includes('archive_get'),
	'LuCI must not grant generic archive diagnostic/content methods');
for (const method of ['archive_capabilities', 'messages_page', 'archive_get', 'archive_verify'])
	assert(daemon.includes(`${method}:`), `daemon proxy method missing: ${method}`);

console.log('archive-contract.js: A0 contract checks passed');
