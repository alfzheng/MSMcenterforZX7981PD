#!/usr/bin/ucode
'use strict';

const backend_module = loadfile('./packages/modem-smsd/files/usr/share/modem-sms/backend-smsat.uc')();

function equal(actual, expected, label) {
	if (actual !== expected)
		die(`${label}: expected ${expected}, got ${actual}\n`);
}

let read_count = 0;
let connection = {
	list: function() {
		return { 'modem.smsat': { capabilities: {}, scan_begin: {}, scan_read: {}, scan_end: {} } };
	},
	defer: function(object, method, args, callback) {
		equal(object, 'modem.smsat', 'broker object');
		if (method == 'scan_begin')
			callback(0, { ok: true, scan_id: 7, storage: 'SM', used: 1, total: 2 });
		else if (method == 'scan_read') {
			read_count++;
			if (args.index == 1)
				callback(0, { ok: true, index: 1, empty: false, status: 'REC READ',
					pdu: '00AABBCCDDEEFF001122' });
			else
				callback(0, { ok: true, index: 2, empty: true, complete: read_count == 4,
					phase: read_count == 4 ? 2 : 1 });
		}
		else if (method == 'scan_end')
			callback(0, { ok: true, stable: true, used: 1, total: 2 });
		else
			callback(9, {});
		return null;
	}
};

let backend = backend_module.create(connection, {});
equal(backend.available(), true, 'broker contract availability');
equal(backend.send_available(), false, 'broker send remains disabled');
equal(backend.capabilities().features.delete, false, 'broker delete remains disabled');

let result = null;
backend.list_storage('SM', function(reply) { result = reply; });
equal(result.ok, true, 'two-pass broker list');
equal(result.raw_count, 1, 'empty physical slot is not a record');
equal(result.records[0].index, 1, 'record index');
equal(read_count, 4, 'complete two-pass physical scan');

let changed_reads = 0;
let changed_connection = {
	list: connection.list,
	defer: function(object, method, args, callback) {
		if (method == 'scan_begin')
			callback(0, { ok: true, scan_id: 8, storage: 'SM', used: 1, total: 1 });
		else if (method == 'scan_read') {
			changed_reads++;
			callback(0, { ok: true, index: 1, empty: false, status: 'REC READ',
				pdu: changed_reads == 1 ? '00AABBCCDDEEFF001122' : '00FFEEDDCCBBAA001122' });
		}
		else if (method == 'scan_end')
			callback(0, { ok: true, stable: true, used: 1, total: 1 });
		return null;
	}
};
let changed = null;
backend_module.create(changed_connection, {}).list_storage('SM', function(reply) { changed = reply; });
equal(changed.ok, false, 'changed PDU must fail closed');
equal(changed.error_code, 'BROKER_SCAN_CONTENT_CHANGED', 'changed PDU error');

print('backend-smsat.uc: broker adapter contract tests passed\n');
