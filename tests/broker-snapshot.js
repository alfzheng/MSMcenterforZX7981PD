'use strict';

const assert = require('assert');

function signature(record) {
	return `${record.index}|${record.pdu}|${record.status || ''}`;
}

function validatePass(records, capacity) {
	if (!Array.isArray(records) || records.length !== capacity.used)
		return false;

	const seen = new Set();
	for (const record of records) {
		if (!Number.isInteger(record.index) || record.index < 1 || record.index > capacity.total)
			return false;
		if (seen.has(record.index))
			return false;
		seen.add(record.index);
	}
	return true;
}

function validateSnapshot(before, first, after, second, transportOk = true) {
	if (!transportOk || !before || !after || before.storage !== after.storage ||
		before.used !== after.used || before.total !== after.total)
		return false;
	if (!validatePass(first, before) || !validatePass(second, after))
		return false;

	const firstByIndex = new Map(first.map(record => [record.index, signature(record)]));
	for (const record of second) {
		if (firstByIndex.get(record.index) !== signature(record))
			return false;
	}
	return true;
}

function records(start, end, status = 'REC READ', suffix = '') {
	const out = [];
	for (let index = start; index <= end; index++)
		out.push({ index, status, pdu: `PDU-${index}-${suffix}` });
	return out;
}

const completeCapacity = { storage: 'SM', used: 3, total: 50 };
const complete = records(1, 3);
assert.strictEqual(validateSnapshot(completeCapacity, complete, completeCapacity, complete), true,
	'complete stable indexed passes must be accepted');

const partial41 = records(1, 41);
const partial48 = records(1, 48);
assert.strictEqual(validateSnapshot({ storage: 'SM', used: 50, total: 50 },
	partial41, { storage: 'SM', used: 50, total: 50 }, partial48), false,
	'41/48 partial passes must not be treated as a complete union');

const indexReuse = records(1, 3, 'REC READ', 'old');
const replaced = records(1, 3, 'REC READ', 'new');
assert.strictEqual(validateSnapshot(completeCapacity, indexReuse, completeCapacity, replaced), false,
	'index reuse must fail the immutable full-PDU gate');

const statusChanged = records(1, 3);
const unread = records(1, 3, 'REC UNREAD');
assert.strictEqual(validateSnapshot(completeCapacity, statusChanged, completeCapacity, unread), false,
	'storage-state changes must fail the stable snapshot gate');

assert.strictEqual(validateSnapshot(completeCapacity, complete,
		{ storage: 'SM', used: 4, total: 50 }, complete), false,
		'capacity changes must fail the stable snapshot gate');
assert.strictEqual(validateSnapshot(completeCapacity, complete, completeCapacity, complete, false), false,
		'transport failure must fail closed');

console.log('broker-snapshot.js: adversarial snapshot invariants passed');
