#!/usr/bin/ucode
'use strict';

const backend_module = loadfile('./packages/modem-smsd/files/usr/share/modem-sms/backend-lteat.uc')();

function equal(actual, expected, label) {
	if (actual !== expected)
		die(`${label}: expected ${expected}, got ${actual}\n`);
}

let calls = [];
let connection = {
	list: function() { return ['lteat']; },
	defer: function(object, method, args, callback) {
		push(calls, { object: object, method: method, args: args });
		if (method == 'send')
			callback(0, { result: `AT+CPMS?\r\n+CPMS: "SM",1,50,"SM",1,50,"SM",1,50\r\nOK\r\n` });
		else if (method == 'get_sms')
			callback(0, { result: '+CMGL: 7,"REC READ",,12\r\n00112233445566778899AABB\r\nOK\r\n' });
		else if (method == 'send_sms')
			callback(0, { ERROR: 0, result: 'AT+CMSS=8\r\n+CMSS: 19\r\nOK\r\n' });
		else if (method == 'del_sms')
			callback(0, { result: 'AT+CMGD=7\r\nOK\r\n' });
		else
			callback(9, {});
		/* Exercise the adapter's immediate-callback plus null-return path. */
		return null;
	}
};

let backend = backend_module.create(connection, {});
equal(backend.available(), true, 'backend availability');
equal(backend.capabilities().features.delete, false, 'r5 delete capability fails closed');

let list_callbacks = 0;
let list_result = null;
backend.list_storage('SM', function(result) {
	list_callbacks++;
	list_result = result;
});
if (list_callbacks != 1)
	die(sprintf('list callback once: expected 1, got %d; calls=%.J\n', list_callbacks, calls));
equal(list_result.ok, true, 'list storage result');
equal(length(list_result.records), 1, 'list record count');
equal(list_result.records[0].index, 7, 'list record index');
equal(list_result.records[0].storage_status, 'REC READ', 'CMGL storage status');
equal(list_result.capacity.used, 1, 'capacity used');
equal(list_result.capacity.total, 50, 'capacity total');
equal(calls[0].method, 'send', 'storage switch method');
equal(calls[0].args.cmd, 'AT+CPMS="SM","SM","SM"', 'target storage switch contract');

let send_callbacks = 0;
let send_result = null;
backend.send_pdu({ pdu: '001122', tpdu_length: 2 }, function(result) {
	send_callbacks++;
	send_result = result;
});
equal(send_callbacks, 1, 'send callback once');
equal(send_result.ok, true, 'send result');
equal(send_result.message_reference, 19, 'send message reference');

let delete_callbacks = 0;
let delete_result = null;
backend.delete_record('ME', 7, function(result) {
	delete_callbacks++;
	delete_result = result;
});
equal(delete_callbacks, 1, 'delete callback once');
equal(delete_result.ok, true, 'delete result');

let plain_connection = {
	list: function() { return ['lteat']; },
	defer: function(object, method, args, callback) {
		if (method == 'send')
			callback(0, { result: '+CPMS: 1,50,1,50,1,50\r\nOK\r\n' });
		else if (method == 'get_sms')
			callback(0, { result: '+CMGL: 1,"REC UNREAD"\r\n00112233445566778899AABB\r\nOK\r\n' });
		return {};
	}
};
let plain_result = null;
backend_module.create(plain_connection, {}).list_storage('SM', function(result) { plain_result = result; });
equal(plain_result.ok, true, 'plain CPMS set response');
equal(plain_result.capacity.used, 1, 'plain CPMS capacity');

let mismatch_connection = {
	list: function() { return ['lteat']; },
	defer: function(object, method, args, callback) {
		if (method == 'send')
			callback(0, { result: '+CPMS: "SM",2,50,"SM",2,50,"SM",2,50\r\nOK\r\n' });
		else if (method == 'get_sms')
			callback(0, { result: '+CMGL: 1,"REC READ"\r\n00112233445566778899AABB\r\nOK\r\n' });
		return {};
	}
};
let mismatch_result = null;
backend_module.create(mismatch_connection, {}).list_storage('SM', function(result) { mismatch_result = result; });
equal(mismatch_result.ok, false, 'record/capacity mismatch rejected');
equal(mismatch_result.error_code, 'BACKEND_PARSE_FAILED', 'record/capacity mismatch code');

let duplicate_index_connection = {
	list: function() { return ['lteat']; },
	defer: function(object, method, args, callback) {
		if (method == 'send')
			callback(0, { result: '+CPMS: "SM",2,50,"SM",2,50,"SM",2,50\r\nOK\r\n' });
		else if (method == 'get_sms')
			callback(0, { result: '+CMGL: 7,"REC READ"\r\n00112233445566778899AABB\r\n' +
				'+CMGL: 7,"REC UNREAD"\r\n00112233445566778899AABC\r\nOK\r\n' });
		return {};
	}
};
let duplicate_index_result = null;
backend_module.create(duplicate_index_connection, {}).list_storage('SM',
	function(result) { duplicate_index_result = result; });
equal(duplicate_index_result.ok, false, 'duplicate physical index rejected');
equal(duplicate_index_result.error_code, 'BACKEND_PARSE_FAILED', 'duplicate physical index code');
equal(duplicate_index_result.detail, 'DUPLICATE_RECORD_INDEX', 'duplicate physical index detail');

let split_array_connection = {
	list: function() { return ['lteat']; },
	defer: function(object, method, args, callback) {
		if (method == 'send')
			callback(0, { result: '+CPMS: 1,50,1,50,1,50\r\nOK\r\n' });
		else if (method == 'get_sms')
			callback(0, { result: [ '+CMGL: 9,"REC READ"', '00112233445566778899AABB', 'OK' ] });
		return {};
	}
};
let split_array_result = null;
backend_module.create(split_array_connection, {}).list_storage('SM',
	function(result) { split_array_result = result; });
equal(split_array_result.ok, true, 'split array CMGL parsed');
equal(split_array_result.records[0].index, 9, 'split array index context preserved');

let throwing_connection = {
	list: function() { return ['lteat']; },
	defer: function() { die('synchronous transport failure'); }
};
let throwing_result = null;
backend_module.create(throwing_connection, {}).list_storage('SM', function(result) { throwing_result = result; });
equal(throwing_result.ok, false, 'synchronous defer failure returned');
equal(throwing_result.error_code, 'BACKEND_STORAGE_SWITCH_FAILED', 'synchronous defer failure code');

let cms_connection = {
	list: function() { return ['lteat']; },
	defer: function(object, method, args, callback) {
		if (method == 'send')
			callback(0, { result: '+CPMS: 0,50,0,50,0,50\r\nOK\r\n' });
		else if (method == 'send_sms')
			callback(9, { result: '+CMS ERROR: 322\r\n' });
		return {};
	}
};
let cms_result = null;
backend_module.create(cms_connection, {}).send_pdu({ pdu: '001122', tpdu_length: 2 },
	function(result) { cms_result = result; });
equal(cms_result.ok, false, 'definite CMS error returned');
equal(cms_result.error_code, 'STORAGE_FULL', 'definite CMS error precedes transport status');

let incomplete_connection = {
	list: function() { return { lteat: { send: {}, get_sms: {}, send_sms: {} } }; }
};
equal(backend_module.create(incomplete_connection, {}).available(), false,
	'missing backend method reported unsupported');

let complete_connection = {
	list: function() { return { lteat: { send: {}, get_sms: {}, send_sms: {}, del_sms: {} } }; }
};
equal(backend_module.create(complete_connection, {}).available(), true,
	'complete backend method contract available');

let switch_error_connection = {
	list: function() { return ['lteat']; },
	defer: function(object, method, args, callback) {
		callback(0, { result: 'AT+CPMS\r\nERROR\r\n' });
		return {};
	}
};
let switch_error_result = null;
backend_module.create(switch_error_connection, {}).list_storage('SM',
	function(result) { switch_error_result = result; });
equal(switch_error_result.ok, false, 'plain ERROR rejects storage switch');

let read_error_connection = {
	list: function() { return ['lteat']; },
	defer: function(object, method, args, callback) {
		if (method == 'send') callback(0, { result: '+CPMS: 0,50,0,50,0,50\r\nOK\r\n' });
		else callback(0, { result: 'AT+CMGL=4\r\nERROR\r\n' });
		return {};
	}
};
let read_error_result = null;
backend_module.create(read_error_connection, {}).list_storage('SM',
	function(result) { read_error_result = result; });
equal(read_error_result.error_code, 'BACKEND_READ_FAILED', 'plain ERROR rejects read');

let send_error_connection = {
	list: function() { return ['lteat']; },
	defer: function(object, method, args, callback) {
		if (method == 'send') callback(0, { result: '+CPMS: 0,50,0,50,0,50\r\nOK\r\n' });
		else callback(0, { result: 'AT+CMGS\r\nERROR\r\n' });
		return {};
	}
};
let send_error_result = null;
backend_module.create(send_error_connection, {}).send_pdu({ pdu: '001122', tpdu_length: 2 },
	function(result) { send_error_result = result; });
equal(send_error_result.error_code, 'BACKEND_SUBMIT_FAILED', 'plain ERROR rejects send');

let delete_unknown_connection = {
	list: function() { return ['lteat']; },
	defer: function(object, method, args, callback) {
		if (method == 'send') callback(0, { result: '+CPMS: 0,50,0,50,0,50\r\nOK\r\n' });
		else callback(7, {});
		return {};
	}
};
let delete_unknown_result = null;
backend_module.create(delete_unknown_connection, {}).delete_record('SM', 1,
	function(result) { delete_unknown_result = result; });
equal(delete_unknown_result.error_code, 'BACKEND_DELETE_UNKNOWN', 'delete timeout remains unknown');
equal(delete_unknown_result.outcome_unknown, true, 'delete timeout outcome flag');

print('backend.uc: all tests passed\n');
