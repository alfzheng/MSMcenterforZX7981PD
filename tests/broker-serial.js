'use strict';

const assert = require('assert');

function makePdu(tpduBytes = 10) {
	return `00${'AA'.repeat(tpduBytes)}`;
}

function parseCmgrFrame(frame, limit = 32768) {
	if (Buffer.byteLength(frame, 'utf8') > limit)
		return { ok: false, error: 'BROKER_RESPONSE_TOO_LARGE' };
	const lines = frame.split(/\n/).map(line => line.replace(/\r$/, ''));
	while (lines[lines.length - 1] === '')
		lines.pop();
	if (lines[lines.length - 1] !== 'OK')
		return { ok: false, error: 'BROKER_FRAME_INCOMPLETE' };
	if (lines.some(line => /^ERROR$|^\+CME ERROR|^\+CMS ERROR/.test(line)))
		return { ok: false, error: 'BROKER_EMPTY_UNCERTAIN' };
	const header = lines.find(line => line.startsWith('+CMGR:'));
	const pdu = lines.find(line => /^[0-9A-Fa-f ]+$/.test(line) && line.replace(/\s/g, '').length >= 20);
	if (!header || !pdu)
		return { ok: false, error: 'BROKER_READ_PARSE_FAILED' };
	const declared = Number(header.slice(header.lastIndexOf(',') + 1).trim());
	const normalized = pdu.replace(/\s/g, '').toUpperCase();
	const smscLength = Number.parseInt(normalized.slice(0, 2), 16);
	if (!Number.isInteger(declared) || normalized.length % 2 ||
		normalized.length / 2 !== 1 + smscLength + declared)
		return { ok: false, error: 'BROKER_PDU_LENGTH_MISMATCH' };
	return { ok: true, pdu: normalized, pduBytes: normalized.length / 2 };
}

function validFrame() {
	const pdu = makePdu(10);
	return `+CMGR: 1,,10\r\n${pdu}\r\nOK\r\n`;
}

assert.deepStrictEqual(parseCmgrFrame(validFrame()), {
	ok: true,
	pdu: makePdu(10),
	pduBytes: 11,
}, 'complete CMGR frame must pass its declared PDU length');

assert.strictEqual(parseCmgrFrame(validFrame().replace('AAAA', '')).ok, false,
	'truncated PDU must fail closed');
assert.strictEqual(parseCmgrFrame(validFrame().replace(/\r\nOK\r\n$/, '\r\n')).error,
	'BROKER_FRAME_INCOMPLETE', 'missing terminal OK must fail closed');
assert.strictEqual(parseCmgrFrame('+CMGR: 1,,10\r\nERROR\r\nOK\r\n').error,
	'BROKER_EMPTY_UNCERTAIN', 'generic modem error must not become an empty slot');
assert.strictEqual(parseCmgrFrame('+CMGR: 1,,11\r\n' + makePdu(10) + '\r\nOK\r\n').error,
	'BROKER_PDU_LENGTH_MISMATCH', 'declared length mismatch must fail closed');
assert.strictEqual(parseCmgrFrame(validFrame(), 8).error,
	'BROKER_RESPONSE_TOO_LARGE', 'response limit must be enforced');

console.log('broker-serial.js: framing and PDU adversarial cases passed');
