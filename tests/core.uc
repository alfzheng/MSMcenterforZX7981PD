#!/usr/bin/ucode
'use strict';

const core = loadfile('./packages/modem-smsd/files/usr/share/modem-sms/core.uc')();

function equal(actual, expected, label) {
	if (actual !== expected)
		die(`${label}: expected ${expected}, got ${actual}\n`);
}

function truthy(actual, label) {
	if (!actual)
		die(`${label}: expected a truthy value, got ${actual}\n`);
}

function error_code(pdu, expected, label) {
	let decoded = core.decode_pdu(pdu);
	equal(decoded.ok, false, `${label} rejected`);
	equal(decoded.error_code, expected, `${label} error code`);
}

function all_prefixes_rejected(pdu, label) {
	for (let bytes = 0; bytes < int(length(pdu) / 2); bytes++) {
		let decoded = core.decode_pdu(substr(pdu, 0, bytes * 2));
		if (decoded.ok)
			die(`${label}: truncated prefix of ${bytes} bytes was accepted\n`);
	}
}

let gsm = core.analyse_text('hello world');
equal(gsm.ok, true, 'ASCII analysis');
equal(gsm.encoding, 'GSM-7', 'ASCII encoding');
equal(gsm.segments, 1, 'ASCII segments');

let extension = core.analyse_text('[]{}^~\\|€');
equal(extension.encoding, 'GSM-7', 'GSM extension encoding');
equal(extension.units, 18, 'GSM extension septets');

let chinese = core.analyse_text('短信测试');
equal(chinese.encoding, 'UCS2', 'Chinese encoding');
equal(chinese.units, 4, 'Chinese code units');

let invalid = core.encode_submit('12;AT', 'test', 7);
equal(invalid.ok, false, 'number validation');
equal(invalid.error_code, 'INVALID_NUMBER', 'number validation code');

let submit_gsm = core.encode_submit('+8613800000000', '0720test', 7);
equal(submit_gsm.ok, true, 'GSM submit encode');
equal(length(submit_gsm.pdus), 1, 'GSM submit segments');
equal(substr(submit_gsm.pdus[0].pdu, 2, 2), '01', 'TP-SRR disabled by default');
equal(submit_gsm.pdus[0].message_reference, 0, 'submit TP-MR retained');
equal(submit_gsm.pdus[0].status_report_requested, false, 'submit report metadata');
let decoded_gsm = core.decode_pdu(submit_gsm.pdus[0].pdu);
equal(decoded_gsm.ok, true, 'GSM submit decode');
equal(decoded_gsm.text, '0720test', 'GSM submit round trip');
equal(decoded_gsm.number, '+8613800000000', 'address round trip');
equal(decoded_gsm.message_reference, 0, 'decoded submit TP-MR');
equal(decoded_gsm.status_report_requested, false, 'decoded TP-SRR');
equal(core.decode_pdu(submit_gsm.pdus[0].pdu + '00').error_code, 'TRAILING_PDU_DATA',
	'valid PDU with trailing octet rejected');
let oversized_pdu = '';
for (let i = 0; i < 513; i++) oversized_pdu += '00';
equal(core.decode_pdu(oversized_pdu).ok, false, 'oversized PDU rejected before allocation');

let submit_without_report = core.encode_submit('10086', 'test', 8, false);
equal(substr(submit_without_report.pdus[0].pdu, 2, 2), '01', 'TP-SRR can be disabled');
let submit_with_report = core.encode_submit('10086', 'test', 8, true);
equal(substr(submit_with_report.pdus[0].pdu, 2, 2), '21', 'TP-SRR can be enabled explicitly');

let submit_ucs2 = core.encode_submit('10086', '中文短信', 9);
equal(submit_ucs2.ok, true, 'UCS2 submit encode');
let decoded_ucs2 = core.decode_pdu(submit_ucs2.pdus[0].pdu);
equal(decoded_ucs2.text, '中文短信', 'UCS2 submit round trip');

let long_text = '';
for (let i = 0; i < 200; i++)
	long_text += 'A';
let long_submit = core.encode_submit('10086', long_text, 10);
equal(length(long_submit.pdus), 2, 'long GSM segmentation');
let long_part_1 = core.decode_pdu(long_submit.pdus[0].pdu);
let long_part_2 = core.decode_pdu(long_submit.pdus[1].pdu);
equal(long_part_1.concat.total, 2, 'concat total');
equal(long_part_1.concat.part, 1, 'concat first part');
equal(long_part_2.concat.part, 2, 'concat second part');
equal(long_part_1.text + long_part_2.text, long_text, 'long GSM round trip');

/* An extension character occupies two septets and must never be split after ESC. */
let extension_boundary = '';
for (let i = 0; i < 152; i++)
	extension_boundary += 'A';
extension_boundary += '^BBBBBBBB';
let extension_submit = core.encode_submit('10086', extension_boundary, 11);
equal(length(extension_submit.pdus), 2, 'GSM extension boundary segmentation');
let extension_part_1 = core.decode_pdu(extension_submit.pdus[0].pdu);
let extension_part_2 = core.decode_pdu(extension_submit.pdus[1].pdu);
equal(extension_part_1.text + extension_part_2.text, extension_boundary,
	'GSM extension boundary round trip');

/* A UTF-16 surrogate pair must remain in the same multipart segment. */
let surrogate_boundary = '';
for (let i = 0; i < 66; i++)
	surrogate_boundary += '中';
surrogate_boundary += '😺文文文文文';
let surrogate_submit = core.encode_submit('10086', surrogate_boundary, 12);
equal(length(surrogate_submit.pdus), 2, 'UCS2 surrogate boundary segmentation');
let surrogate_part_1 = core.decode_pdu(surrogate_submit.pdus[0].pdu);
let surrogate_part_2 = core.decode_pdu(surrogate_submit.pdus[1].pdu);
equal(surrogate_part_1.text + surrogate_part_2.text, surrogate_boundary,
	'UCS2 surrogate boundary round trip');

/*
 * Independent Android Open Source Project vector (GsmSmsTest.testAddressing):
 * https://android.googlesource.com/platform/frameworks/base/+/9a069c80fe6195c4e3d813712881b902da25cd5a/telephony/tests/telephonytests/src/com/android/internal/telephony/GsmSmsTest.java
 */
let android_deliver = '07914151551512F2040B916105551511F100006060605130308A04D4F29C0E';
let delivered = core.decode_pdu(android_deliver);
equal(delivered.ok, true, 'AOSP SMS-DELIVER decode');
equal(delivered.direction, 'inbound', 'AOSP delivery direction');
equal(delivered.number, '+16505551111', 'AOSP originating address');
equal(delivered.text, 'Test', 'AOSP delivery body');
equal(delivered.timestamp, '2006-06-06T15:03:03-07:00', 'SCTS timezone decode');

/* AOSP CPHS vector proves TP-OA Address-Length is semi-octets for TON=alphanumeric. */
let android_alpha = '07912160130310F20404D0110041006060627171118A0120';
let alpha = core.decode_pdu(android_alpha);
equal(alpha.ok, true, 'AOSP alphanumeric TP-OA decode');
equal(alpha.number, '_@', 'alphanumeric TP-OA septet count');
equal(alpha.text, ' ', 'alphanumeric TP-OA body alignment');

/* AOSP status report vector used by ImsSmsDispatcherTest. */
let android_report = '0006000681214365919061800000639190618000006300';
let report = core.decode_pdu(android_report);
equal(report.ok, true, 'AOSP SMS-STATUS-REPORT decode');
equal(report.direction, 'status-report', 'status report direction');
equal(report.number, '123456', 'status report recipient');
equal(report.message_reference, 0, 'status report TP-MR');
equal(report.status, 'delivered', 'completed TP-Status');
equal(report.delivery_category, 'completed', 'completed status category');
equal(report.timestamp, '2019-09-16T08:00:00+09:00', 'status report SCTS');
equal(report.discharge_timestamp, '2019-09-16T08:00:00+09:00', 'status report discharge time');

let report_head = substr(android_report, 0, length(android_report) - 2);
let report_pending = core.decode_pdu(report_head + '20');
equal(report_pending.status, 'delivery-pending', 'temporary status remains pending');
equal(report_pending.delivery_category, 'temporary-error-retrying', 'temporary retry category');
let report_permanent = core.decode_pdu(report_head + '40');
equal(report_permanent.status, 'delivery-failed', 'permanent status failed');
equal(report_permanent.delivery_category, 'permanent-error', 'permanent status category');
let report_expired = core.decode_pdu(report_head + '60');
equal(report_expired.delivery_category, 'temporary-error-expired', 'expired temporary status category');
let report_reserved = core.decode_pdu(report_head + '80');
equal(report_reserved.status, 'unknown', 'reserved TP-Status is not a false failure');

/* DCS 0xE8: store UCS2 message and set the voice-message waiting indication. */
let mwi_ucs2 = core.decode_pdu('00040481214300E842701221436500024E2D');
equal(mwi_ucs2.ok, true, 'UCS2 MWI DCS decode');
equal(mwi_ucs2.encoding, 'UCS2', 'UCS2 MWI alphabet');
equal(mwi_ucs2.text, '中', 'UCS2 MWI body');
equal(mwi_ucs2.mwi.active, true, 'MWI active bit');
equal(mwi_ucs2.mwi.type, 0, 'MWI voice type');

error_code('0004048121430020427012214365000141', 'UNSUPPORTED_COMPRESSED_DCS',
	'compressed DCS');
error_code('000404812143000C427012214365000141', 'UNSUPPORTED_DCS', 'reserved alphabet DCS');
error_code('000404812143000842701221436500014E', 'INVALID_UCS2', 'odd UCS2 payload');
error_code('00040481214300084270122143650002D800', 'INVALID_UCS2', 'unpaired UTF-16 surrogate');
error_code('000404812143000042701221436500011B', 'INVALID_GSM7', 'trailing GSM escape');
error_code('07AA', 'TRUNCATED_PDU', 'oversized SMSC field');
error_code('00GG', 'INVALID_PDU', 'non-hex PDU');

/* Every field boundary in all supported TPDU branches must fail closed. */
all_prefixes_rejected(android_deliver, 'SMS-DELIVER bounds');
all_prefixes_rejected(android_report, 'SMS-STATUS-REPORT bounds');
all_prefixes_rejected(submit_gsm.pdus[0].pdu, 'SMS-SUBMIT bounds');

/* Independent AOSP 153-septet multipart vector, including a real concatenation UDH. */
let android_long = '07916163838408F6440B816105224431F700007060217175830AA005000300020162B1582C168BC562B1582C168BC562B1582C168BC562B1582C168BC562B1582C168BC562B1582C168BC562B1582C168BC562B1582C168BC562B1582C168BC562B1582C168BC562B1582C168BC562B1582C168BC562B1582C168BC562B1582C168BC562B1582C168BC562B1582C168BC562B1582C168BC562B1582C168BC562B1582C168BC562';
let independent_long = core.decode_pdu(android_long);
equal(independent_long.ok, true, 'AOSP multipart decode');
equal(independent_long.concat.reference, 0, 'AOSP multipart reference');
equal(independent_long.concat.total, 2, 'AOSP multipart total');
equal(independent_long.concat.part, 1, 'AOSP multipart part');
equal(length(independent_long.text), 153, 'AOSP multipart septet count');

/* Preview is 80 Unicode code points, never 80 UTF-8 bytes. */
let preview_text = '';
for (let i = 0; i < 100; i++)
	preview_text += '中';
let public_item = core.public_message({
	id: 'sm:1:test', direction: 'inbound', number: '10010', timestamp: null,
	text: preview_text, encoding: 'UCS2', status: 'received', storage_status: 'STO SENT',
	storage: 'SM', indexes: [ 1 ], fingerprint: 'test'
}, false);
equal(length(public_item.preview), 240, 'UTF-8 preview byte length');
equal(core.analyse_text(public_item.preview).encoding, 'UCS2', 'UTF-8 preview remains valid');
equal(public_item.storage_status, 'STO SENT', 'storage status passed through');

let public_unsent = core.public_message({
	id: 'me:2:test', direction: 'outbound', number: '10010', timestamp: null,
	text: 'draft', encoding: 'GSM-7', status: 'stored', storage_status: 'STO UNSENT',
	storage: 'ME', indexes: [ 2 ], fingerprint: 'test2'
}, true);
equal(public_unsent.storage_status, 'STO UNSENT', 'unsent storage status passed through');
equal(public_unsent.text, 'draft', 'safe full text passed through');

equal(core.mask_number('12345'), '12345', 'service short code remains recognizable');
equal(core.mask_number('123456'), '12**56', 'six digit number masks without overlap');
equal(core.mask_number('1234567'), '12***67', 'seven digit number masks without overlap');
equal(core.mask_number('12345678'), '12**5678', 'eight digit number masks middle digits');
equal(core.mask_number('13800138000'), '138****8000', 'mobile number masking');
equal(core.mask_number('+8613800138000'), '+861******8000', 'international number masking');

let oversized_text = '';
for (let i = 0; i < 8193; i++) oversized_text += 'A';
equal(core.analyse_text(oversized_text).error_code, 'MESSAGE_TOO_LONG', 'analyse length limit');

let fingerprint_a = core.message_fingerprint('SM', 1, decoded_gsm);
let fingerprint_b = core.message_fingerprint('SM', 1, decoded_gsm);
equal(fingerprint_a, fingerprint_b, 'stable message fingerprint');
equal(length(fingerprint_a), 16, 'message fingerprint length');

truthy(length(core.bytes_to_hex([ 0, 255 ])) == 4, 'hex helper');
print('core.uc: all tests passed\n');
