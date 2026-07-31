'use strict';

function factory(connection, options) {
	const STATUS_INVALID_ARGUMENT = 2;
	const STATUS_TIMEOUT = 7;
	const STATUS_UNKNOWN_ERROR = 9;
	const STATUS_CONNECTION_FAILED = 10;
	const object_name = options.object ?? 'lteat';
	const switch_method = options.switch_method ?? 'send';
	const switch_argument = options.switch_argument ?? 'cmd';
	const list_method = options.list_method ?? 'get_sms';
	const send_method = options.send_method ?? 'send_sms';
	const delete_method = options.delete_method ?? 'del_sms';
	const send_storage = uc(options.default_storage ?? 'SM');

	function invoke(method, args, callback) {
		let settled = false;
		function finish(code, reply) {
			if (settled)
				return;
			settled = true;
			callback(code, reply ?? {});
		}

		let pending = null;
		let callback_active = false;
		try {
			pending = connection.defer(object_name, method, args ?? {}, function(code, reply) {
				callback_active = true;
				finish(code, reply);
				callback_active = false;
			});
		}
		catch (exception) {
			if (callback_active)
				die(`Backend callback failed: ${exception}\n`);
			finish(STATUS_CONNECTION_FAILED, {});
			return null;
		}

		if (pending == null)
			finish(STATUS_CONNECTION_FAILED, {});

		return pending;
	}

	function reply_contains_error(reply) {
		let kind = type(reply);
		if (kind == 'string')
			return !!match(uc(reply), /(\+CMS ERROR|\+CME ERROR|(^|\r?\n)\s*ERROR\s*(\r?\n|$))/);
		if (kind == 'array') {
			for (let item in reply)
				if (reply_contains_error(item))
					return true;
			return false;
		}
		if (kind == 'object') {
			for (let key in reply)
				if (reply_contains_error(reply[key]))
					return true;
		}
		return false;
	}

	function submit_error(code, reply) {
		let raw = uc(sprintf('%.J', reply ?? {}));
		if (match(raw, /(\+CMS ERROR:\s*(322|512)|MEMORY\s+FULL|STORAGE\s+FULL)/))
			return 'STORAGE_FULL';
		if (match(raw, /(\+CMS ERROR:\s*(310|311|312|313|314)|SIM\s+(NOT\s+INSERTED|BUSY|PIN))/))
			return 'SIM_NOT_READY';
		if (code == STATUS_TIMEOUT)
			return 'SUBMIT_TIMEOUT';
		/* A transport/status failure may arrive after the modem accepted the
		 * TPDU. Treat it as ambiguous unless the modem returned a definite CMS
		 * or CME error above. */
		if (code)
			return 'SUBMIT_UNKNOWN';
		return 'BACKEND_SUBMIT_FAILED';
	}

	function switch_storage(storage, callback) {
		if (!match(storage, /^(SM|ME)$/)) {
			callback(STATUS_INVALID_ARGUMENT, {});
			return;
		}

		let args = {};
		args[switch_argument] = `AT+CPMS="${storage}","${storage}","${storage}"`;
		invoke(switch_method, args, function(code, reply) {
			callback(code || reply_contains_error(reply) ? STATUS_UNKNOWN_ERROR : 0, reply);
		});
	}

	function record(out, index, pdu, raw_status) {
		let clean = replace(uc(pdu ?? ''), /[^0-9A-F]/g, '');
		if (length(clean) < 20 || length(clean) > 1024 || length(clean) % 2)
			return;

		for (let existing in out)
			if (existing.pdu == clean && existing.index == index)
				return;

		push(out, { index: index, pdu: clean, storage_status: raw_status ?? null });
	}

	function collect_string(value, inherited_index, inherited_status, out) {
		let current = inherited_index;
		let current_status = inherited_status;
		for (let line in split(value, /\r?\n/)) {
			line = trim(line);
			let header = match(line, /^\+CMGL:\s*([0-9]+)(,\s*"?([^",]+)"?)?/);
			if (header) {
				current = +header[1];
				current_status = header[3] ?? null;
				continue;
			}
			if (match(line, /^[0-9A-Fa-f]{20,}$/))
				record(out, current, line, current_status);
		}
		return { index: current, storage_status: current_status };
	}

	function collect(node, inherited_index, inherited_status, out) {
		let kind = type(node);

		if (kind == 'string') {
			return collect_string(node, inherited_index, inherited_status, out);
		}

		if (kind == 'array') {
			let context = { index: inherited_index, storage_status: inherited_status };
			for (let item in node) {
				let next = collect(item, context.index, context.storage_status, out);
				if (next) context = next;
			}
			return context;
		}

		if (kind != 'object')
			return { index: inherited_index, storage_status: inherited_status };

		let record_index = inherited_index;
		let record_status = inherited_status;
		for (let name in ['index', 'slot', 'position'])
			if (exists(node, name) && (type(node[name]) == 'int' || match(`${node[name]}`, /^[0-9]+$/)))
				record_index = +node[name];
		for (let name in ['status', 'storage_status', 'message_status'])
			if (exists(node, name) && (type(node[name]) == 'string' || type(node[name]) == 'int'))
				record_status = `${node[name]}`;

		for (let name in ['pdu', 'raw_pdu', 'message'])
			if (exists(node, name) && type(node[name]) == 'string')
				collect_string(node[name], record_index, record_status, out);

		for (let key in node)
			if (index(['pdu', 'raw_pdu', 'message'], key) < 0)
				collect(node[key], record_index, record_status, out);
		return { index: record_index, storage_status: record_status };
	}

	function extract_records(reply) {
		let out = [];
		collect(reply, null, null, out);
		return out;
	}

	function extract_message_reference(reply) {
		let raw = sprintf('%.J', reply ?? {});
		let found = match(raw, /\+CM(GS|SS):\s*([0-9]+)/);
		return found ? +found[2] : null;
	}

	function extract_capacity(reply) {
		let found = null;
		function scan(node) {
			if (found)
				return;
			let kind = type(node);
			if (kind == 'string') {
				let capacity = match(node, /\+CPMS:\s*"[^"]+",\s*([0-9]+),\s*([0-9]+)/);
				if (!capacity)
					capacity = match(node, /\+CPMS:\s*([0-9]+),\s*([0-9]+)/);
				if (capacity)
					found = { used: +capacity[1], total: +capacity[2] };
				return;
			}
			if (kind == 'array') {
				for (let item in node)
					scan(item);
			}
			else if (kind == 'object') {
				for (let key in node)
					scan(node[key]);
			}
		}
		scan(reply);
		return found ?? { used: null, total: null };
	}

	function list_storage(storage, callback) {
		switch_storage(storage, function(code, switch_reply) {
			if (code) {
				callback({ ok: false, error_code: 'BACKEND_STORAGE_SWITCH_FAILED', backend_status: code });
				return;
			}

			invoke(list_method, {}, function(list_code, reply) {
				if (list_code || reply_contains_error(reply)) {
					callback({ ok: false, error_code: 'BACKEND_READ_FAILED', backend_status: list_code });
					return;
				}
				let records = extract_records(reply);
				let capacity = extract_capacity(switch_reply);
				let seen_indexes = {};
				for (let item in records) {
					if (item.index == null || !match(`${item.index}`, /^(0|[1-9][0-9]*)$/)) {
						callback({ ok: false, error_code: 'BACKEND_PARSE_FAILED', detail: 'INVALID_RECORD_INDEX' });
						return;
					}
					let index_key = `${item.index}`;
					if (exists(seen_indexes, index_key)) {
						callback({ ok: false, error_code: 'BACKEND_PARSE_FAILED', detail: 'DUPLICATE_RECORD_INDEX' });
						return;
					}
					seen_indexes[index_key] = true;
				}
				if (capacity.used != null && capacity.used != length(records)) {
					callback({ ok: false, error_code: 'BACKEND_PARSE_FAILED',
						parsed_count: length(records), expected_count: capacity.used });
					return;
				}
				callback({ ok: true, records: records, raw_count: length(records), capacity: capacity });
			});
		});
	}

	function send_pdu(item, callback) {
		switch_storage(send_storage, function(storage_code) {
			if (storage_code) {
				callback({ ok: false, error_code: 'BACKEND_STORAGE_SWITCH_FAILED', backend_status: storage_code });
				return;
			}
			invoke(send_method, { text: item.pdu, number: `${item.tpdu_length}` }, function(code, reply) {
				if (code || reply_contains_error(reply))
					callback({ ok: false, error_code: submit_error(code, reply), backend_status: code });
				else
					callback({ ok: true, backend_status: 0, message_reference: extract_message_reference(reply) });
			});
		});
	}

	function delete_record(storage, message_index, callback) {
		if (!match(`${message_index}`, /^[0-9]+$/)) {
			callback({ ok: false, error_code: 'INVALID_INDEX' });
			return;
		}

		switch_storage(storage, function(code) {
			if (code) {
				callback({ ok: false, error_code: 'BACKEND_STORAGE_SWITCH_FAILED', backend_status: code });
				return;
			}

			invoke(delete_method, { index: `${message_index}` }, function(delete_code, reply) {
				if (reply_contains_error(reply))
					callback({ ok: false, error_code: 'BACKEND_DELETE_FAILED', backend_status: delete_code });
				else if (delete_code)
					callback({ ok: false, error_code: 'BACKEND_DELETE_UNKNOWN', backend_status: delete_code,
						outcome_unknown: true });
				else
					callback({ ok: true });
			});
		});
	}

	function available() {
		let objects = connection.list(object_name);
		if (objects == null || !length(objects))
			return false;
		/* Real ubus bindings expose an object/method signature. Some minimal
		 * test or legacy bindings only expose an object-name array. Validate the
		 * full method contract whenever the signature is available. */
		let descriptor = null;
		if (type(objects) == 'object')
			descriptor = exists(objects, object_name) ? objects[object_name] : objects;
		else if (type(objects) == 'array' && length(objects) == 1 && type(objects[0]) == 'object')
			descriptor = objects[0];
		if (descriptor != null) {
			if (type(descriptor) == 'object') {
				for (let method in [switch_method, list_method, send_method, delete_method])
					if (!exists(descriptor, method))
						return false;
			}
		}
		return true;
	}

	return {
		id: 'lteat-v1',
		transport: 'ubus',
		available: available,
		list_storage: list_storage,
		send_pdu: send_pdu,
		delete_record: delete_record,
		restore_storage: function(storage, callback) { switch_storage(storage, callback); },
		capabilities: function() {
			return {
				backend_id: 'lteat-v1',
				transport: 'ubus',
				vendor: null,
				model: null,
				features: { read: true, send: true, delete: false, concat: true,
					read_may_mark_read: true },
				read_may_mark_read: true,
				encodings: ['GSM-7', 'UCS2']
			};
		}
	};
}

return { create: factory };
