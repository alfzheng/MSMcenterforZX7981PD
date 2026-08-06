'use strict';

/*
 * Read-only adapter for the disabled-by-default modem-sms-broker foundation.
 * The broker owns the serial lease and performs the two-pass integrity gate;
 * this adapter only translates its private ubus contract into modem-smsd's
 * public read interface. Sending and deletion remain deliberately disabled.
 */
function factory(connection, options) {
	const STATUS_CONNECTION_FAILED = 10;
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
		let text = `${value ?? ''}`;
		return match(text, /^[0-9]+$/) ? +text : null;
	}

	function descriptor_available() {
		let objects = connection.list(object_name);
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

		invoke('scan_begin', { storage: storage }, function(begin_code, begin) {
			if (begin_code || !begin.ok) {
				finish(fail(begin.error_code ?? 'BROKER_SCAN_BEGIN_FAILED', null,
					{ backend_status: begin_code }));
				return;
			}
			let scan_id = `${begin.scan_id ?? ''}`;
			let used = integer(begin.used);
			let total = integer(begin.total);
			function abort_begin(result) {
				if (match(scan_id, /^[0-9]+$/))
					invoke('scan_end', { scan_id: scan_id }, function() { finish(result); });
				else
					finish(result);
			}
			if (!match(scan_id, /^[0-9]+$/) || `${begin.storage ?? ''}` !== storage ||
				used == null || total == null ||
				used < 0 || total < used || total > 4096) {
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
					if (result.ok && (end_code || !end.ok || !end.stable ||
						integer(end.used) !== used || integer(end.total) !== total)) {
						finish(fail(end.error_code ?? 'BROKER_SCAN_END_FAILED', null,
							{ backend_status: end_code }));
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
					if (read_code || !reply.ok) {
						fail_scan(reply.error_code ?? 'BROKER_SCAN_READ_FAILED');
						return;
					}
					let reply_index = integer(reply.index);
					if (reply_index !== index) {
						fail_scan('BROKER_INDEX_MISMATCH');
						return;
					}
					let empty = reply.empty === true || reply.empty === 1;
					let current = { empty: empty, status: `${reply.status ?? ''}`, pdu: '' };
					if (!empty) {
						current.pdu = `${reply.pdu ?? ''}`;
						if (!match(current.pdu, /^[0-9A-Fa-f]+$/) || length(current.pdu) < 20 ||
							length(current.pdu) > 1024 || length(current.pdu) % 2) {
							fail_scan('BROKER_PDU_INVALID');
							return;
						}
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
					if (pass == 1 && index == total &&
						(reply.complete !== true && reply.complete !== 1)) {
						fail_scan('BROKER_SCAN_INCOMPLETE');
						return;
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
		restore_storage: function(storage, callback) { callback(2); },
		capabilities: function() {
			return {
				backend_id: 'smsat-v1',
				transport: 'private-ubus-broker',
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
