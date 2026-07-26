'use strict';

const fs = require('fs');
const vm = require('vm');
const path = require('path');

const sourcePath = path.resolve(__dirname,
	'../packages/luci-app-modem-sms/htdocs/luci-static/resources/view/modem/sms.js');
const source = fs.readFileSync(sourcePath, 'utf8');
const start = source.indexOf("const ACTIVE_REQUEST_KEY");
const end = source.indexOf('function requestId()');
if (start < 0 || end < 0)
	throw new Error('Unable to locate request storage implementation');

class SharedStorage {
	constructor() { this.values = new Map(); }
	get length() { return this.values.size; }
	key(index) { return Array.from(this.values.keys())[index] || null; }
	getItem(key) { return this.values.has(key) ? this.values.get(key) : null; }
	setItem(key, value) { this.values.set(String(key), String(value)); }
	removeItem(key) { this.values.delete(String(key)); }
}

function tab(storage) {
	const context = { window: { localStorage: storage }, Set, Array, JSON };
	vm.createContext(context);
	vm.runInContext(source.slice(start, end) +
		'globalThis.api = { storedRequestIds, storeRequestId, clearStoredRequestId };', context);
	return context.api;
}

const storage = new SharedStorage();
const first = tab(storage);
const second = tab(storage);
const idA = 'request-tab-a-0001';
const idB = 'request-tab-b-0002';

/* Two independent tabs store without a shared read-modify-write array. */
first.storeRequestId(idA);
second.storeRequestId(idB);
let recovered = first.storedRequestIds().sort();
if (JSON.stringify(recovered) !== JSON.stringify([idA, idB].sort()))
	throw new Error(`cross-tab request IDs lost: ${JSON.stringify(recovered)}`);

first.clearStoredRequestId(idA);
recovered = second.storedRequestIds();
if (recovered.length !== 1 || recovered[0] !== idB)
	throw new Error(`clearing one ID affected another tab: ${JSON.stringify(recovered)}`);

/* Legacy array migration creates independent keys before deleting the old key. */
storage.setItem('modem-sms.active-request-id', JSON.stringify([idA, idB]));
recovered = first.storedRequestIds().sort();
if (JSON.stringify(recovered) !== JSON.stringify([idA, idB].sort()) ||
	storage.getItem('modem-sms.active-request-id') !== null)
	throw new Error('legacy request ID migration failed');

console.log('frontend-storage.js: all tests passed');
