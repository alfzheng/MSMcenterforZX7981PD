'use strict';

/*
 * Read-only adapter for the disabled-by-default modem-sms-broker foundation.
 * The broker owns the serial lease and performs the two-pass integrity gate;
 * this adapter only translates its private ubus contract into modem-smsd's
 * public read interface. Sending and deletion remain deliberately disabled.
 */
function factory(connection, options) {
	const STATUS_CONNECTION_FAILED = 10;
	const MAX_SCAN_TOTAL = 4096;
	const MIN_PDU_HEX_LENGTH = 20;
	const MAX_PDU_HEX_LENGTH = 1024;
	const VALID_STATUS = {
		'REC READ': true,
		'REC UNREAD': true,
		'STO SENT': true,
		'STO UNSENT': true
	};
	const object_name = options.object ?? 'modem.smsat';

	function invoke(method, args, callback) {
		let settled = false;
		function finish(code, reply) {
			if (settled)
				return;
			settled = true;
			callback(code, reply ?? {});
		}

		try {
			let pending = connection.defer(object_name, method, args ?? {}, function(code, reply) {
				finish(code, reply);
			});
			if (pending == null)
				finish(STATUS_CONNECTION_FAILED, {});
		}
		catch (exception) {
			finish(STATUS_CONNECTION_FAILED, {});
		}
	}

	function integer(value) {
		return type(value) == 'int' && value >= 0 ? value : null;
	}

	function flag(value) {
		if (value === true || value === 1)
			return true;
		if (value === false || value === 0)
			return false;
		return null;
	}

	function schema_ok(reply) {
		return type(reply) == 'object' && integer(reply.schema_version) == 1;
	}

	function scan_id_ok(value) {
		return integer(value) != null && value > 0;
	}

	function pdu_ok(reply) {
		if (type(reply.pdu) != 'string' || !match(reply.pdu, /^[0-9A-Fa-f]+$/) ||
			length(reply.pdu) < MIN_PDU_HEX_LENGTH ||
			length(reply.pdu) > MAX_PDU_HEX_LENGTH || length(reply.pdu) % 2 ||
			integer(reply.pdu_bytes) == null || integer(reply.pdu_bytes) != length(reply.pdu) / 2)
			return false;
		let smsc_length = hex(substr(reply.pdu, 0, 2));
		return smsc_length != null && 1 + smsc_length <= reply.pdu_bytes;
	}

	function descriptor_available() {
		let objects = null;
		try { objects = connection.list(object_name); }
		catch (exception) { return false; }
		if (objects == null)
			return false;
		let descriptor = null;
		if (type(objects) == 'object')
			descriptor = exists(objects, object_name) ? objects[object_name] : objects;
		else if (type(objects) == 'array' && length(objects) == 1 && type(objects[0]) == 'object')
			descriptor = objects[0];
		if (type(descriptor) != 'object')
			return false;
		for (let method in ['capabilities', 'scan_begin', 'scan_read', 'scan_end'])
			if (!exists(descriptor, method))
				return false;
		return true;
	}

	function fail(code, detail, extra) {
		let result = { ok: false, error_code: code, detail: detail ?? null };
		for (let key in extra ?? {})
			result[key] = extra[key];
		return result;
	}

	function error_code(reply, fallback) {
		return type(reply) == 'object' && reply.error_code != null ?
			`${reply.error_code}` : fallback;
	}

	function capabilities_ok(reply) {
		return schema_ok(reply) && flag(reply.ok) &&
			`${reply.backend_id ?? ''}` === 'smsat-v1' &&
			`${reply.transport ?? ''}` === 'exclusive-tty' &&
			flag(reply.serial_owner) === true &&
			flag(reply.indexed_read) === true &&
			flag(reply.device_delete) === false &&
			integer(reply.owner_nonce) != null && reply.owner_nonce > 0;
	}

	function list_storage(storage, callback) {
		if (!match(storage, /^(SM|ME)$/)) {
			callback(fail('INVALID_STORAGE'));
			return;
		}
		if (!descriptor_available()) {
			callback(fail('BROKER_UNAVAILABLE'));
			return;
		}

		let settled = false;
		function finish(result) {
			if (settled)
				return;
			settled = true;
			callback(result);
		}

		function begin_scan() {
		invoke('scan_begin', { storage: storage }, function(begin_code, begin) {
			let begin_scan_id = type(begin) == 'object' && scan_id_ok(begin.scan_id) ?
				begin.scan_id : null;
			function abort_begin(result) {
				if (begin_scan_id == null) {
					finish(result);
					return;
				}
				invoke('scan_end', { scan_id: begin_scan_id }, function(end_code, end) {
					if (end_code || !schema_ok(end) || !flag(end.ok) || !flag(end.stable)) {
						finish(fail('BROKER_SCAN_RELEASE_UNCONFIRMED',
							error_code(end, 'scan_end failed'), {
								backend_status: end_code, original_error_code: result.error_code
							}));
						return;
					}
					finish(result);
				});
			}
			if (begin_code || type(begin) != 'object' || !schema_ok(begin) || !flag(begin.ok)) {
				abort_begin(fail(error_code(begin, 'BROKER_SCAN_BEGIN_FAILED'), null,
					{ backend_status: begin_code }));
				return;
			}
			let scan_id = begin.scan_id;
			let generation = integer(begin.generation);
			let used = integer(begin.used);
			let total = integer(begin.total);
			if (!scan_id_ok(scan_id) || generation == null || generation < 1 ||
				`${begin.storage ?? ''}` !== storage || used == null || total == null ||
				used > total || total > MAX_SCAN_TOTAL) {
				abort_begin(fail('BROKER_CONTRACT_INVALID'));
				return;
			}

			let first = {};
			let records = [];
			let pass = 0;
			let next_index = 1;
			let nonempty = 0;

			function close_scan(result) {
				invoke('scan_end', { scan_id: scan_id }, function(end_code, end) {
					if (end_code || type(end) != 'object' || !schema_ok(end) ||
						!flag(end.ok) || !flag(end.stable)) {
						finish(fail('BROKER_SCAN_RELEASE_UNCONFIRMED',
							error_code(end, 'scan_end failed'), {
								backend_status: end_code, original_error_code: result.error_code
							}));
						return;
					}
					if (integer(end.used) !== used || integer(end.total) !== total ||
						integer(end.generation) !== generation) {
						finish(fail('BROKER_SCAN_UNSTABLE', null, {
							original_error_code: result.error_code
						}));
						return;
					}
					finish(result);
				});
			}

			function fail_scan(code, detail) {
				close_scan(fail(code, detail));
			}

			function read_next() {
				if (next_index > total) {
					if (nonempty !== used) {
						fail_scan('BROKER_COUNT_MISMATCH');
						return;
					}
					if (pass == 0) {
						pass = 1;
						next_index = 1;
						nonempty = 0;
						read_next();
						return;
					}
					close_scan({ ok: true, records: records, raw_count: length(records),
						capacity: { used: used, total: total }, attempts: 1 });
					return;
				}

				let index = next_index;
				invoke('scan_read', { scan_id: scan_id, index: index }, function(read_code, reply) {
					if (read_code || type(reply) != 'object' || !schema_ok(reply) || !flag(reply.ok) ||
						exists(reply, 'error_code')) {
						fail_scan(error_code(reply, 'BROKER_SCAN_READ_FAILED'));
						return;
					}
					let reply_index = integer(reply.index);
					if (reply_index !== index) {
						fail_scan('BROKER_INDEX_MISMATCH');
						return;
					}
					let empty = flag(reply.empty);
					if (empty == null) {
						fail_scan('BROKER_CONTRACT_INVALID');
						return;
					}
					let pass_complete = flag(reply.pass_complete);
					let complete = flag(reply.complete);
					let phase = integer(reply.phase);
					let at_end = index == total;
					let expected_phase = at_end ? pass + 1 : pass;
					if (pass_complete == null || complete == null || phase == null ||
						pass_complete !== at_end || complete !== (pass == 1 && at_end) ||
						phase !== expected_phase) {
						fail_scan('BROKER_SCAN_PHASE_INVALID');
						return;
					}
					if (empty && (exists(reply, 'error_code') || exists(reply, 'pdu') ||
						exists(reply, 'pdu_bytes') || exists(reply, 'status'))) {
						fail_scan('BROKER_EMPTY_CONTRACT_INVALID');
						return;
					}
					let current = { empty: empty, status: `${reply.status ?? ''}`, pdu: '' };
					if (!empty) {
						if (type(reply.status) != 'string' || !exists(VALID_STATUS, reply.status) ||
							!pdu_ok(reply)) {
							fail_scan('BROKER_PDU_INVALID');
							return;
						}
						current.status = reply.status;
						current.pdu = reply.pdu;
						nonempty++;
					}
					if (pass == 0) {
						first[index] = current;
						if (!empty)
							push(records, { index: index, pdu: current.pdu,
								storage_status: current.status || null });
					}
					else {
						let previous = first[index];
						if (previous == null || previous.empty !== current.empty ||
							previous.status !== current.status || previous.pdu !== current.pdu) {
							fail_scan('BROKER_SCAN_CONTENT_CHANGED');
							return;
						}
					}
					next_index++;
					read_next();
				});
			}

			if (total == 0) {
				close_scan({ ok: true, records: [], raw_count: 0,
					capacity: { used: 0, total: 0 }, attempts: 1 });
				return;
			}
			read_next();
		});
		}

		invoke('capabilities', {}, function(capability_code, capabilities) {
			if (capability_code || !capabilities_ok(capabilities)) {
				finish(fail(error_code(capabilities, 'BROKER_CAPABILITIES_INVALID'), null,
					{ backend_status: capability_code }));
				return;
			}
			begin_scan();
		});
	}

	return {
		id: 'smsat-v1',
		transport: 'private-ubus-broker',
		available: descriptor_available,
		send_available: function() { return false; },
		list_storage: list_storage,
		send_pdu: function(item, callback) { callback(fail('BROKER_SEND_DISABLED')); },
		delete_record: function(storage, message_index, callback) {
			callback(fail('DEVICE_DELETE_DISABLED'));
		},
		delete_available: function() { return false; },
		restore_storage: function(storage, callback) { callback(0); },
		capabilities: function() {
			return {
				schema_version: 1,
				contract_version: 'smsat-v1',
				backend_id: 'smsat-v1',
				transport: 'private-ubus-broker',
				owner: { object: object_name, exclusive_tty: true },
				health: 'broker-capabilities-required',
				features: { read: true, send: false, delete: false, indexed_read: true,
					concat: false, read_may_mark_read: true },
				read_may_mark_read: true,
				encodings: ['GSM-7', 'UCS2'],
				storages: ['SM', 'ME']
			};
		}
	};
}

return { create: factory };
