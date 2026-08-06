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
		if (method == 'capabilities')
			callback(0, { schema_version: 1, ok: true, backend_id: 'smsat-v1',
				transport: 'exclusive-tty', serial_owner: true, owner_nonce: 11,
				indexed_read: true, device_delete: false });
		else if (method == 'scan_begin')
			callback(0, { schema_version: 1, ok: true, owner_nonce: 11, scan_id: 7, generation: 4,
				storage: 'SM', used: 1, total: 2 });
		else if (method == 'scan_read') {
			read_count++;
			equal(type(args.scan_id), 'int', 'scan id must stay int64-compatible');
			equal(args.owner_nonce, 11, 'scan calls must bind the broker owner nonce');
			if (args.index == 1)
				callback(0, { schema_version: 1, ok: true, owner_nonce: 11, index: 1, empty: false,
					status: 'REC READ', pdu: '00AABBCCDDEEFF001122', pdu_bytes: 10,
					pass_complete: read_count == 2 || read_count == 4,
					complete: read_count == 4, phase: read_count <= 2 ?
						(read_count == 2 ? 1 : 0) : (read_count == 4 ? 2 : 1) });
			else
				callback(0, { schema_version: 1, ok: true, owner_nonce: 11, index: 2, empty: true,
					complete: read_count == 4, pass_complete: true,
					phase: read_count == 4 ? 2 : 1 });
		}
		else if (method == 'scan_end')
			callback(0, { schema_version: 1, ok: true, owner_nonce: 11, stable: true, generation: 4,
				used: 1, total: 2 });
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
		if (method == 'capabilities')
			callback(0, { schema_version: 1, ok: true, backend_id: 'smsat-v1',
				transport: 'exclusive-tty', serial_owner: true, owner_nonce: 12,
				indexed_read: true, device_delete: false });
		else if (method == 'scan_begin')
			callback(0, { schema_version: 1, ok: true, owner_nonce: 12, scan_id: 8, generation: 5,
				storage: 'SM', used: 1, total: 1 });
		else if (method == 'scan_read') {
			changed_reads++;
			callback(0, { schema_version: 1, ok: true, owner_nonce: 12, index: 1, empty: false,
				status: 'REC READ', pdu: changed_reads == 1 ?
					'00AABBCCDDEEFF001122' : '00FFEEDDCCBBAA001122', pdu_bytes: 10,
				pass_complete: true, complete: changed_reads == 2,
				phase: changed_reads == 1 ? 1 : 2 });
		}
		else if (method == 'scan_end')
			callback(0, { schema_version: 1, ok: true, owner_nonce: 12, stable: true, generation: 5,
				used: 1, total: 1 });
		return null;
	}
};
let changed = null;
backend_module.create(changed_connection, {}).list_storage('SM', function(reply) { changed = reply; });
equal(changed.ok, false, 'changed PDU must fail closed');
equal(changed.error_code, 'BROKER_SCAN_CONTENT_CHANGED', 'changed PDU error');

let release_calls = [];
let release_connection = {
	list: connection.list,
	defer: function(object, method, args, callback) {
		push(release_calls, method);
		if (method == 'capabilities')
			callback(0, { schema_version: 1, ok: true, backend_id: 'smsat-v1',
				transport: 'exclusive-tty', serial_owner: true, owner_nonce: 13,
				indexed_read: true, device_delete: false });
		else if (method == 'scan_begin')
			callback(0, { schema_version: 1, ok: true, owner_nonce: 13, scan_id: 9, generation: 6,
				storage: 'SM', used: 1, total: 1 });
		else if (method == 'scan_read')
			callback(9, { schema_version: 1, ok: false, error_code: 'BROKER_READ_TIMEOUT' });
		else if (method == 'scan_end')
			callback(9, { schema_version: 1, ok: false, owner_nonce: 13, error_code: 'BROKER_CPMS_RECHECK_FAILED' });
		return {};
	}
};
let release_result = null;
backend_module.create(release_connection, {}).list_storage('SM', function(reply) {
	release_result = reply;
});
equal(release_result.ok, false, 'release failure must fail closed');
equal(release_result.error_code, 'BROKER_SCAN_RELEASE_UNCONFIRMED',
	'release failure is explicit');
equal(release_calls[3], 'scan_end', 'read failure still attempts scan_end');

print('backend-smsat.uc: broker adapter contract tests passed\n');
