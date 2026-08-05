'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const sourcePath = path.resolve(__dirname,
	'../packages/luci-app-modem-sms/htdocs/luci-static/resources/view/modem/sms.js');
const source = fs.readFileSync(sourcePath, 'utf8');
const start = source.indexOf('function storageErrorText');
const end = source.indexOf('\nreturn view.extend');
if (start < 0 || end < 0)
	throw new Error('Unable to locate frontend error formatter');

const context = {
	_: value => {
		const translated = new String(value);
		translated.format = function(...args) {
			let index = 0;
			return this.toString().replace(/%[sd]/g, () => String(args[index++]));
		};
		return translated;
	},
	String
};
vm.createContext(context);
vm.runInContext(source.slice(start, end) +
	'globalThis.api = { storageErrorText, operationErrorText };', context);

const result = {
	ok: true,
	errors: [{
		storage: 'SM',
		error_code: 'BACKEND_PARSE_FAILED',
		detail: 'CAPACITY_MISMATCH',
		parsed_count: 41,
		expected_count: 50,
		attempts: 20,
		serialized_response_bytes: 10434
	}]
};
const text = context.api.operationErrorText(result);
if (text !== 'SM: BACKEND_PARSE_FAILED (CAPACITY_MISMATCH, 41/50 records, 20 attempts, 10434-byte serialized response)')
	throw new Error(`diagnostic formatter lost fields: ${text}`);

console.log('frontend-errors.js: all tests passed');
