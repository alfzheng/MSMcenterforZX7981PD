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
assert.doesNotMatch(source, /UBUS_METHOD(?:_NOARG)?\("(?:send_sms|delete_sms)"/, 'send/delete remain gated');
assert.match(makefile, /\+libubus \+libubox \+libuci/, 'runtime dependencies must be explicit');

console.log('broker-package.js: fail-closed package invariants passed');
