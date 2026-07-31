'use strict';

const fs = require('fs');

/* Deterministic backend used only by tests/daemon-integration.sh. */
const deliver_pdu = '07914151551512F2040B916105551511F100006060605130308A04D4F29C0E';

function fault_mode() {
	let value = fs.readfile('/tmp/modem-sms-fake-mode');
	return value == null ? '' : trim(value);
}

function create(connection, options) {
	let send_count = 0;
	return {
		id: 'fake-v1',
		transport: 'memory',
		available: function() { return true; },
		list_storage: function(storage, callback) {
			if (fault_mode() == storage + '_FAIL') {
				callback({ ok: false, error_code: 'BACKEND_COMMAND_FAILED', detail: 'INJECTED_' + storage + '_FAILURE' });
				return;
			}
			callback(storage == 'SM' ? {
				ok: true,
				records: [{ index: 7, pdu: deliver_pdu, storage_status: 'REC READ' }],
				capacity: { used: 1, total: 50 }
			} : {
				ok: true,
				records: [],
				capacity: { used: 0, total: 50 }
			});
		},
		send_pdu: function(item, callback) {
			send_count++;
			let mode = fault_mode();
			if (mode == 'BLOCK_SEND' || (mode == 'BLOCK_SECOND_SEND' && send_count == 2)) {
				fs.writefile('/tmp/modem-sms-fake-blocked', mode);
				sleep(30000);
				return;
			}
			if (mode == 'SUBMIT_UNKNOWN') {
				callback({ ok: false, error_code: 'SUBMIT_UNKNOWN', outcome_unknown: true });
				return;
			}
			callback({ ok: true, backend_status: 0, message_reference: 42 });
		},
		delete_record: function(storage, index, callback) {
			fs.writefile('/tmp/modem-sms-fake-delete-called', `${storage}:${index}`);
			callback({ ok: true });
		},
		restore_storage: function(storage, callback) { callback(0); },
		capabilities: function() {
			return {
				backend_id: 'fake-v1',
				transport: 'memory',
				features: { read: true, send: true, delete: false, concat: true,
					read_may_mark_read: false },
				read_may_mark_read: false,
				encodings: ['GSM-7', 'UCS2']
			};
		}
	};
}

return { create: create };
