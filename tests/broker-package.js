'use strict';

const assert = require('assert');
const fs = require('fs');

const source = fs.readFileSync('packages/modem-sms-broker/src/modem-sms-broker.c', 'utf8');
const config = fs.readFileSync('packages/modem-sms-broker/files/etc/config/modem-sms-broker', 'utf8');
const init = fs.readFileSync('packages/modem-sms-broker/files/etc/init.d/modem-sms-broker', 'utf8');
const makefile = fs.readFileSync('packages/modem-sms-broker/Makefile', 'utf8');

assert.match(config, /option enabled '0'/, 'broker must remain disabled by default');
assert.match(config, /option lease_timeout_ms '300000'/, 'lease timeout must be explicit');
assert.match(init, /config_get_bool enabled main enabled 0/, 'init must fail closed on enablement');
assert.match(source, /flock\(g_state\.fd, LOCK_EX \| LOCK_NB\)/, 'TTY ownership must be exclusive');
assert.match(source, /MAX_SCAN_TOTAL/, 'scan capacity must be bounded');
assert.match(source, /BROKER_EMPTY_UNCERTAIN/, 'generic modem errors must fail closed');
assert.match(source, /BROKER_PDU_LENGTH_MISMATCH/, 'PDU length must be checked');
assert.match(source, /uloop_timeout_set\(&g_state\.lease_timer/, 'scan lease must expire');
assert.match(source, /scan_begin|scan_read|scan_end/, 'versioned scan methods must exist');
assert.match(source, /"serial_ready"/, 'capabilities must distinguish service health from an idle serial');
assert.match(source, /empty_cms_error_code/, 'empty-slot classification must be explicit and configurable');
assert.match(config, /option empty_cms_error_code ''/, 'empty-slot classification must default to disabled');
assert.match(source, /if \(!current\.empty\)\s+g_state\.nonempty_count\+\+/, 'empty records must not count as occupied slots');
assert.match(source, /line\[length - 1\] == '\\r'/, 'CRLF terminal framing must be normalized');
assert.match(source, /blobmsg_get_u64_flexible/, 'scan IDs must accept ubus JSON integer widths');
assert.match(source, /blobmsg_add_u32\(&g_blob, "phase"/, 'scan phase must remain numeric in JSON');
assert.match(source, /BEGIN_OWNER_NONCE|READ_OWNER_NONCE|END_OWNER_NONCE/, 'scan methods must bind owner nonce');
assert.match(source, /"serial_owner", g_state\.fd >= 0/, 'serial owner must reflect the held descriptor');
assert.doesNotMatch(source, /UBUS_METHOD(?:_NOARG)?\("(?:send_sms|delete_sms)"/, 'send/delete remain gated');
assert.match(makefile, /\+libubus \+libubox \+libuci/, 'runtime dependencies must be explicit');

console.log('broker-package.js: fail-closed package invariants passed');
