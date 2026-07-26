'use strict';

const SCHEMA_VERSION = '1.0';
const MAX_PDU_HEX_LENGTH = 1024;

/* Unicode code points for the GSM 03.38 default alphabet. */
const GSM_BASIC = [
	0x0040, 0x00a3, 0x0024, 0x00a5, 0x00e8, 0x00e9, 0x00f9, 0x00ec,
	0x00f2, 0x00c7, 0x000a, 0x00d8, 0x00f8, 0x000d, 0x00c5, 0x00e5,
	0x0394, 0x005f, 0x03a6, 0x0393, 0x039b, 0x03a9, 0x03a0, 0x03a8,
	0x03a3, 0x0398, 0x039e, 0x001b, 0x00c6, 0x00e6, 0x00df, 0x00c9,
	0x0020, 0x0021, 0x0022, 0x0023, 0x00a4, 0x0025, 0x0026, 0x0027,
	0x0028, 0x0029, 0x002a, 0x002b, 0x002c, 0x002d, 0x002e, 0x002f,
	0x0030, 0x0031, 0x0032, 0x0033, 0x0034, 0x0035, 0x0036, 0x0037,
	0x0038, 0x0039, 0x003a, 0x003b, 0x003c, 0x003d, 0x003e, 0x003f,
	0x00a1, 0x0041, 0x0042, 0x0043, 0x0044, 0x0045, 0x0046, 0x0047,
	0x0048, 0x0049, 0x004a, 0x004b, 0x004c, 0x004d, 0x004e, 0x004f,
	0x0050, 0x0051, 0x0052, 0x0053, 0x0054, 0x0055, 0x0056, 0x0057,
	0x0058, 0x0059, 0x005a, 0x00c4, 0x00d6, 0x00d1, 0x00dc, 0x00a7,
	0x00bf, 0x0061, 0x0062, 0x0063, 0x0064, 0x0065, 0x0066, 0x0067,
	0x0068, 0x0069, 0x006a, 0x006b, 0x006c, 0x006d, 0x006e, 0x006f,
	0x0070, 0x0071, 0x0072, 0x0073, 0x0074, 0x0075, 0x0076, 0x0077,
	0x0078, 0x0079, 0x007a, 0x00e4, 0x00f6, 0x00f1, 0x00fc, 0x00e0
];

const GSM_EXT_DECODE = {
	'10': 0x000c,
	'20': 0x005e,
	'40': 0x007b,
	'41': 0x007d,
	'47': 0x005c,
	'60': 0x005b,
	'61': 0x007e,
	'62': 0x005d,
	'64': 0x007c,
	'101': 0x20ac
};

let gsm_basic_encode = {};
let gsm_ext_encode = {};

for (let i = 0; i < length(GSM_BASIC); i++)
	gsm_basic_encode[`${GSM_BASIC[i]}`] = i;

for (let code in GSM_EXT_DECODE)
	gsm_ext_encode[`${GSM_EXT_DECODE[code]}`] = +code;

function utf8_codepoints(text) {
	let points = [];

	for (let i = 0; i < length(text);) {
		let b0 = ord(text, i);
		let b1 = i + 1 < length(text) ? ord(text, i + 1) : -1;
		let b2 = i + 2 < length(text) ? ord(text, i + 2) : -1;
		let b3 = i + 3 < length(text) ? ord(text, i + 3) : -1;
		let cp;
		let n;

		if (b0 < 0x80) {
			cp = b0;
			n = 1;
		}
		else if (b0 >= 0xc2 && b0 <= 0xdf && b1 >= 0x80 && b1 <= 0xbf) {
			cp = ((b0 & 0x1f) << 6) | (b1 & 0x3f);
			n = 2;
		}
		else if (b0 >= 0xe0 && b0 <= 0xef && b1 >= 0x80 && b1 <= 0xbf &&
			b2 >= 0x80 && b2 <= 0xbf && !(b0 == 0xe0 && b1 < 0xa0) &&
			!(b0 == 0xed && b1 >= 0xa0)) {
			cp = ((b0 & 0x0f) << 12) | ((b1 & 0x3f) << 6) | (b2 & 0x3f);
			n = 3;
		}
		else if (b0 >= 0xf0 && b0 <= 0xf4 && b1 >= 0x80 && b1 <= 0xbf &&
			b2 >= 0x80 && b2 <= 0xbf && b3 >= 0x80 && b3 <= 0xbf &&
			!(b0 == 0xf0 && b1 < 0x90) && !(b0 == 0xf4 && b1 >= 0x90)) {
			cp = ((b0 & 0x07) << 18) | ((b1 & 0x3f) << 12) |
				((b2 & 0x3f) << 6) | (b3 & 0x3f);
			n = 4;
		}
		else
			return null;

		push(points, cp);
		i += n;
	}

	return points;
}

function codepoint_to_utf8(cp) {
	if (cp <= 0x7f)
		return chr(cp);
	if (cp <= 0x7ff)
		return chr(0xc0 | (cp >> 6), 0x80 | (cp & 0x3f));
	if (cp <= 0xffff)
		return chr(0xe0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f));
	return chr(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3f),
		0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f));
}

function utf8_prefix(text, max_points) {
	let value = text ?? '';
	let points = utf8_codepoints(value);
	if (points == null)
		return '[invalid UTF-8]';
	let out = '';
	let limit = length(points) < max_points ? length(points) : max_points;
	for (let i = 0; i < limit; i++)
		out += codepoint_to_utf8(points[i]);
	return out;
}

function safe_utf8(text) {
	let value = text ?? '';
	return utf8_codepoints(value) == null ? '[invalid UTF-8]' : value;
}

function utf16be_bytes(text) {
	let out = [];
	let points = utf8_codepoints(text);
	if (points == null)
		return null;

	for (let cp in points) {
		if (cp <= 0xffff && !(cp >= 0xd800 && cp <= 0xdfff)) {
			push(out, (cp >> 8) & 0xff, cp & 0xff);
		}
		else if (cp <= 0x10ffff) {
			cp -= 0x10000;
			let hi = 0xd800 | ((cp >> 10) & 0x3ff);
			let lo = 0xdc00 | (cp & 0x3ff);
			push(out, hi >> 8, hi & 0xff, lo >> 8, lo & 0xff);
		}
		else {
			push(out, 0xff, 0xfd);
		}
	}

	return out;
}

function utf16be_decode(bytes) {
	if (length(bytes) % 2)
		return null;

	let out = '';

	for (let i = 0; i + 1 < length(bytes); i += 2) {
		let unit = (bytes[i] << 8) | bytes[i + 1];

		if (unit >= 0xd800 && unit <= 0xdbff && i + 3 < length(bytes)) {
			let low = (bytes[i + 2] << 8) | bytes[i + 3];
			if (low >= 0xdc00 && low <= 0xdfff) {
				out += codepoint_to_utf8(0x10000 + ((unit - 0xd800) << 10) + (low - 0xdc00));
				i += 2;
				continue;
			}
		}

		if (unit >= 0xd800 && unit <= 0xdfff)
			return null;

		out += codepoint_to_utf8(unit);
	}

	return out;
}

function gsm7_septets(text) {
	let out = [];
	let points = utf8_codepoints(text);
	if (points == null)
		return null;

	for (let cp in points) {
		let key = `${cp}`;
		if (exists(gsm_basic_encode, key) && gsm_basic_encode[key] != 0x1b)
			push(out, gsm_basic_encode[key]);
		else if (exists(gsm_ext_encode, key))
			push(out, 0x1b, gsm_ext_encode[key]);
		else
			return null;
	}

	return out;
}

function gsm7_decode(septets) {
	let out = '';

	for (let i = 0; i < length(septets); i++) {
		let code = septets[i] & 0x7f;
		if (code == 0x1b) {
			if (i + 1 >= length(septets))
				return null;
			let ext = septets[++i];
			if (!exists(GSM_EXT_DECODE, `${ext}`))
				return null;
			out += codepoint_to_utf8(GSM_EXT_DECODE[`${ext}`]);
		}
		else {
			out += codepoint_to_utf8(GSM_BASIC[code] ?? 0x20);
		}
	}

	return out;
}

function pack_septets(septets, header) {
	let head = header ?? [];
	let header_septets = length(head) ? int((length(head) * 8 + 6) / 7) : 0;
	let bit_start = header_septets * 7;
	let total_bits = bit_start + length(septets) * 7;
	let out = [];

	for (let i = 0; i < int((total_bits + 7) / 8); i++)
		push(out, 0);

	for (let i = 0; i < length(head); i++)
		out[i] = head[i];

	for (let i = 0; i < length(septets); i++) {
		let bit = bit_start + i * 7;
		let octet = int(bit / 8);
		let shift = bit % 8;
		out[octet] |= (septets[i] << shift) & 0xff;
		if (shift > 1)
			out[octet + 1] |= septets[i] >> (8 - shift);
	}

	return { bytes: out, header_septets: header_septets };
}

function unpack_septets(bytes, count, bit_start) {
	let out = [];
	let start = bit_start ?? 0;
	if (count < 0 || start < 0)
		return null;

	for (let i = 0; i < count; i++) {
		let bit = start + i * 7;
		if (bit + 6 >= length(bytes) * 8)
			return null;
		let octet = int(bit / 8);
		let shift = bit % 8;
		let value = (bytes[octet] >> shift) & 0x7f;
		if (shift > 1 && octet + 1 < length(bytes))
			value |= (bytes[octet + 1] << (8 - shift)) & 0x7f;
		push(out, value);
	}

	return out;
}

function bytes_to_hex(bytes) {
	let out = '';
	for (let b in bytes)
		out += sprintf('%02X', b & 0xff);
	return out;
}

function hex_to_bytes(value) {
	let clean = replace(uc(`${value ?? ''}`), /\s/g, '');
	if (!length(clean) || length(clean) > MAX_PDU_HEX_LENGTH || length(clean) % 2 || match(clean, /[^0-9A-F]/))
		return null;

	let out = [];
	for (let i = 0; i < length(clean); i += 2)
		push(out, hex(substr(clean, i, 2)));
	return out;
}

function encode_address(number) {
	let international = substr(number, 0, 1) == '+';
	let digits = international ? substr(number, 1) : number;
	let bytes = [];

	for (let i = 0; i < length(digits); i += 2) {
		let lo = ord(digits, i) - 48;
		let hi = (i + 1 < length(digits)) ? ord(digits, i + 1) - 48 : 0x0f;
		push(bytes, lo | (hi << 4));
	}

	return { length: length(digits), toa: international ? 0x91 : 0x81, bytes: bytes };
}

function address_octets(address_length) {
	return int((address_length + 1) / 2);
}

function decode_address(bytes, address_length, toa) {
	if (address_length < 1 || address_length > 20 || !(toa & 0x80) ||
		length(bytes) < address_octets(address_length))
		return null;

	/* For TON=alphanumeric, TP-OA length is expressed in useful semi-octets. */
	if ((toa & 0x70) == 0x50) {
		let septet_count = int(address_length * 4 / 7);
		let septets = unpack_septets(bytes, septet_count, 0);
		return septets == null ? null : gsm7_decode(septets);
	}

	let out = ((toa & 0x70) == 0x10) ? '+' : '';
	const bcd = [ '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', '*', '#', 'a', 'b', 'c' ];
	for (let digit = 0; digit < address_length; digit++) {
		let nibble = digit % 2 ? ((bytes[int(digit / 2)] >> 4) & 0x0f) : (bytes[int(digit / 2)] & 0x0f);
		if (nibble >= length(bcd))
			return null;
		out += bcd[nibble];
	}
	if (address_length % 2 && ((bytes[int(address_length / 2)] >> 4) & 0x0f) != 0x0f)
		return null;
	return out;
}

function split_units(units, max_units) {
	let parts = [];
	for (let i = 0; i < length(units); i += max_units)
		push(parts, slice(units, i, i + max_units));
	return parts;
}

function split_gsm_septets(septets, max_units) {
	let parts = [];
	for (let start = 0; start < length(septets);) {
		let end = start + max_units;
		if (end > length(septets))
			end = length(septets);
		if (end < length(septets) && septets[end - 1] == 0x1b)
			end--;
		push(parts, slice(septets, start, end));
		start = end;
	}
	return parts;
}

function split_ucs2_bytes(bytes, max_units) {
	let parts = [];
	let max_bytes = max_units * 2;
	for (let start = 0; start < length(bytes);) {
		let end = start + max_bytes;
		if (end > length(bytes))
			end = length(bytes);
		if (end < length(bytes) && end - start >= 2) {
			let unit = (bytes[end - 2] << 8) | bytes[end - 1];
			if (unit >= 0xd800 && unit <= 0xdbff)
				end -= 2;
		}
		push(parts, slice(bytes, start, end));
		start = end;
	}
	return parts;
}

function analyse_text(text) {
	if (length(text) > 8192)
		return { ok: false, error_code: 'MESSAGE_TOO_LONG' };
	if (utf8_codepoints(text) == null)
		return { ok: false, error_code: 'INVALID_UTF8' };

	let septets = gsm7_septets(text);
	if (septets != null) {
		let count = length(septets);
		return {
			ok: true,
			encoding: 'GSM-7',
			units: count,
			segments: count <= 160 ? 1 : length(split_gsm_septets(septets, 153)),
			single_limit: 160,
			concat_limit: 153
		};
	}

	let ucs2 = utf16be_bytes(text);
	if (ucs2 == null)
		return { ok: false, error_code: 'INVALID_UTF8' };
	let units = int(length(ucs2) / 2);
	return {
		ok: true,
		encoding: 'UCS2',
		units: units,
		segments: units <= 70 ? 1 : length(split_ucs2_bytes(ucs2, 67)),
		single_limit: 70,
		concat_limit: 67
	};
}

function encode_submit(number, text, reference, request_status_report) {
	if (!match(number, /^\+?[0-9]{3,20}$/))
		return { ok: false, error_code: 'INVALID_NUMBER' };
	if (!length(text))
		return { ok: false, error_code: 'EMPTY_MESSAGE' };
	if (length(text) > 8192)
		return { ok: false, error_code: 'MESSAGE_TOO_LONG' };

	let analysis = analyse_text(text);
	if (!analysis.ok)
		return { ok: false, error_code: analysis.error_code };
	let address = encode_address(number);
	let ref = reference ?? (clock()[1] & 0xff);
	/* Delivery reports occupy modem storage and cannot safely update a request
	 * until the daemon has a durable TP-MR reconciliation table. Keep them
	 * opt-in; the public send path reports modem submission, not delivery. */
	let status_report_requested = request_status_report ?? false;
	let message_reference = 0;
	let payload_parts;

	if (analysis.encoding == 'GSM-7') {
		let septets = gsm7_septets(text);
		payload_parts = split_gsm_septets(septets, analysis.segments > 1 ? 153 : 160);
	}
	else {
		let bytes = utf16be_bytes(text);
		payload_parts = split_ucs2_bytes(bytes, analysis.segments > 1 ? 67 : 70);
	}

	let result = [];
	let total = length(payload_parts);

	for (let i = 0; i < total; i++) {
		let header = total > 1 ? [0x05, 0x00, 0x03, ref, total, i + 1] : [];
		let user_data;
		let udl;
		let dcs;

		if (analysis.encoding == 'GSM-7') {
			let packed = pack_septets(payload_parts[i], header);
			user_data = packed.bytes;
			udl = packed.header_septets + length(payload_parts[i]);
			dcs = 0x00;
		}
		else {
			user_data = header;
			for (let b in payload_parts[i])
				push(user_data, b);
			udl = length(user_data);
			dcs = 0x08;
		}

		let first_octet = (total > 1 ? 0x41 : 0x01) | (status_report_requested ? 0x20 : 0);
		let tpdu = [first_octet, message_reference, address.length, address.toa];
		for (let b in address.bytes)
			push(tpdu, b);
		push(tpdu, 0x00, dcs, udl);
		for (let b in user_data)
			push(tpdu, b);

		let pdu = [0x00];
		for (let b in tpdu)
			push(pdu, b);

		push(result, {
			pdu: bytes_to_hex(pdu),
			tpdu_length: length(tpdu),
			part: i + 1,
			total: total,
			encoding: analysis.encoding,
			message_reference: message_reference,
			status_report_requested: status_report_requested
		});
	}

	return { ok: true, analysis: analysis, pdus: result };
}

function swapped_decimal(value) {
	let tens = value & 0x0f;
	let units = (value >> 4) & 0x0f;
	return tens <= 9 && units <= 9 ? tens * 10 + units : null;
}

function days_in_month(year, month) {
	if (month == 2)
		return (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)) ? 29 : 28;
	if (month == 4 || month == 6 || month == 9 || month == 11)
		return 30;
	return 31;
}

function decode_timestamp(bytes) {
	if (length(bytes) < 7)
		return null;
	let short_year = swapped_decimal(bytes[0]);
	let month = swapped_decimal(bytes[1]);
	let day = swapped_decimal(bytes[2]);
	let hour = swapped_decimal(bytes[3]);
	let minute = swapped_decimal(bytes[4]);
	let second = swapped_decimal(bytes[5]);
	let timezone_quarters = swapped_decimal(bytes[6] & 0xf7);
	if (short_year == null || month == null || day == null || hour == null || minute == null ||
		second == null || timezone_quarters == null)
		return null;
	let year = short_year >= 70 ? 1900 + short_year : 2000 + short_year;
	if (month < 1 || month > 12 || day < 1 || day > days_in_month(year, month) ||
		hour > 23 || minute > 59 || second > 59 || timezone_quarters > 79)
		return null;
	let sign = bytes[6] & 0x08 ? '-' : '+';
	let timezone_hour = int(timezone_quarters / 4);
	let timezone_minute = (timezone_quarters % 4) * 15;
	return sprintf('%04d-%02d-%02dT%02d:%02d:%02d%s%02d:%02d', year, month, day,
		hour, minute, second, sign, timezone_hour, timezone_minute);
}

function parse_udh(bytes) {
	if (!length(bytes))
		return { ok: false, error_code: 'TRUNCATED_UDH' };

	let end = 1 + bytes[0];
	if (end > length(bytes))
		return { ok: false, error_code: 'TRUNCATED_UDH' };

	let info = null;
	for (let i = 1; i < end;) {
		if (i + 2 > end)
			return { ok: false, error_code: 'INVALID_UDH' };
		let iei = bytes[i++];
		let len = bytes[i++];
		if (i + len > end)
			return { ok: false, error_code: 'INVALID_UDH' };
		if (iei == 0x00 && len == 3)
			info = { reference: bytes[i], total: bytes[i + 1], part: bytes[i + 2], reference_bits: 8 };
		else if (iei == 0x08 && len == 4)
			info = { reference: (bytes[i] << 8) | bytes[i + 1], total: bytes[i + 2], part: bytes[i + 3], reference_bits: 16 };
		i += len;
	}
	if (info != null && (info.total < 1 || info.part < 1 || info.part > info.total))
		return { ok: false, error_code: 'INVALID_CONCAT_UDH' };
	return { ok: true, concat: info, header_bytes: end };
}

function classify_dcs(dcs) {
	let alphabet;
	let message_class = null;
	let mwi = null;

	if ((dcs & 0xc0) == 0x00) {
		if (dcs & 0x20)
			return { ok: false, error_code: 'UNSUPPORTED_COMPRESSED_DCS' };
		let alphabet_bits = dcs & 0x0c;
		if (alphabet_bits == 0x00)
			alphabet = 'GSM-7';
		else if (alphabet_bits == 0x04)
			alphabet = '8-bit';
		else if (alphabet_bits == 0x08)
			alphabet = 'UCS2';
		else
			return { ok: false, error_code: 'UNSUPPORTED_DCS' };
		if (dcs & 0x10)
			message_class = dcs & 0x03;
	}
	else if ((dcs & 0xf0) == 0xc0 || (dcs & 0xf0) == 0xd0 || (dcs & 0xf0) == 0xe0) {
		alphabet = (dcs & 0xf0) == 0xe0 ? 'UCS2' : 'GSM-7';
		mwi = {
			active: !!(dcs & 0x08),
			type: dcs & 0x03,
			discard: (dcs & 0xf0) == 0xc0
		};
	}
	else if ((dcs & 0xf0) == 0xf0) {
		alphabet = dcs & 0x04 ? '8-bit' : 'GSM-7';
		message_class = dcs & 0x03;
	}
	else
		return { ok: false, error_code: 'UNSUPPORTED_DCS' };

	return { ok: true, alphabet: alphabet, message_class: message_class, mwi: mwi };
}

function decode_user_data(bytes, pos, udl, dcs, udhi) {
	let coding = classify_dcs(dcs);
	if (!coding.ok)
		return coding;

	let octets = coding.alphabet == 'GSM-7' ? int((udl * 7 + 7) / 8) : udl;
	if (octets > 140)
		return { ok: false, error_code: 'INVALID_UDL' };
	if (pos + octets > length(bytes))
		return { ok: false, error_code: 'TRUNCATED_PDU' };
	let user_data = slice(bytes, pos, pos + octets);
	let header_bytes = 0;
	let concat = null;
	if (udhi) {
		let header = parse_udh(user_data);
		if (!header.ok)
			return header;
		header_bytes = header.header_bytes;
		concat = header.concat;
	}

	let text;
	if (coding.alphabet == 'GSM-7') {
		let header_septets = header_bytes ? int((header_bytes * 8 + 6) / 7) : 0;
		if (udl < header_septets)
			return { ok: false, error_code: 'INVALID_UDL' };
		let septets = unpack_septets(user_data, udl - header_septets, header_septets * 7);
		if (septets == null)
			return { ok: false, error_code: 'TRUNCATED_PDU' };
		text = gsm7_decode(septets);
		if (text == null)
			return { ok: false, error_code: 'INVALID_GSM7' };
	}
	else if (coding.alphabet == 'UCS2') {
		if (header_bytes > udl || (udl - header_bytes) % 2)
			return { ok: false, error_code: 'INVALID_UCS2' };
		text = utf16be_decode(slice(user_data, header_bytes, udl));
		if (text == null)
			return { ok: false, error_code: 'INVALID_UCS2' };
	}
	else {
		if (header_bytes > udl)
			return { ok: false, error_code: 'INVALID_UDL' };
		text = sprintf('[%d bytes binary SMS]', udl - header_bytes);
	}

	return {
		ok: true,
		encoding: coding.alphabet,
		text: text,
		concat: concat,
		message_class: coding.message_class,
		mwi: coding.mwi,
		consumed: octets
	};
}

function delivery_status(status) {
	if (status <= 0x1f)
		return { status: 'delivered', category: 'completed' };
	if (status <= 0x3f)
		return { status: 'delivery-pending', category: 'temporary-error-retrying' };
	if (status <= 0x5f)
		return { status: 'delivery-failed', category: 'permanent-error' };
	if (status <= 0x7f)
		return { status: 'delivery-failed', category: 'temporary-error-expired' };
	return { status: 'unknown', category: 'reserved' };
}

function decode_pdu(pdu_hex) {
	let bytes = hex_to_bytes(pdu_hex);
	if (bytes == null || length(bytes) < 2)
		return { ok: false, error_code: 'INVALID_PDU' };

	let pos = 0;
	let smsc_len = bytes[pos++];
	if (pos + smsc_len > length(bytes))
		return { ok: false, error_code: 'TRUNCATED_PDU' };
	pos += smsc_len;
	if (pos >= length(bytes))
		return { ok: false, error_code: 'TRUNCATED_PDU' };

	let first = bytes[pos++];
	let mti = first & 0x03;
	let udhi = !!(first & 0x40);
	let direction;
	let number;
	let timestamp = null;
	let status = 'unknown';
	let pid;
	let dcs;
	let message_reference = null;

	if (mti == 0) {
		direction = 'inbound';
		if (pos + 2 > length(bytes))
			return { ok: false, error_code: 'TRUNCATED_PDU' };
		let digits = bytes[pos++];
		let toa = bytes[pos++];
		let count = address_octets(digits);
		if (pos + count + 9 > length(bytes))
			return { ok: false, error_code: 'TRUNCATED_PDU' };
		number = decode_address(slice(bytes, pos, pos + count), digits, toa);
		if (number == null)
			return { ok: false, error_code: 'INVALID_ADDRESS' };
		pos += count;
		pid = bytes[pos++];
		dcs = bytes[pos++];
		timestamp = decode_timestamp(slice(bytes, pos, pos + 7));
		if (timestamp == null)
			return { ok: false, error_code: 'INVALID_TIMESTAMP' };
		pos += 7;
		status = 'received';
	}
	else if (mti == 1) {
		direction = 'outbound';
		if (pos + 3 > length(bytes))
			return { ok: false, error_code: 'TRUNCATED_PDU' };
		message_reference = bytes[pos++];
		let digits = bytes[pos++];
		let toa = bytes[pos++];
		let count = address_octets(digits);
		if (pos + count + 2 > length(bytes))
			return { ok: false, error_code: 'TRUNCATED_PDU' };
		number = decode_address(slice(bytes, pos, pos + count), digits, toa);
		if (number == null)
			return { ok: false, error_code: 'INVALID_ADDRESS' };
		pos += count;
		pid = bytes[pos++];
		dcs = bytes[pos++];
		let vpf = first & 0x18;
		let validity_octets = vpf == 0x10 ? 1 : ((vpf == 0x08 || vpf == 0x18) ? 7 : 0);
		if (pos + validity_octets > length(bytes))
			return { ok: false, error_code: 'TRUNCATED_PDU' };
		pos += validity_octets;
		status = 'stored';
	}
	else if (mti == 2) {
		direction = 'status-report';
		if (pos + 3 > length(bytes))
			return { ok: false, error_code: 'TRUNCATED_PDU' };
		let mr = bytes[pos++];
		let digits = bytes[pos++];
		let toa = bytes[pos++];
		let count = address_octets(digits);
		if (pos + count + 15 > length(bytes))
			return { ok: false, error_code: 'TRUNCATED_PDU' };
		number = decode_address(slice(bytes, pos, pos + count), digits, toa);
		if (number == null)
			return { ok: false, error_code: 'INVALID_ADDRESS' };
		pos += count;
		timestamp = decode_timestamp(slice(bytes, pos, pos + 7));
		let discharge_timestamp = decode_timestamp(slice(bytes, pos + 7, pos + 14));
		if (timestamp == null || discharge_timestamp == null)
			return { ok: false, error_code: 'INVALID_TIMESTAMP' };
		pos += 14;
		let delivery = bytes[pos++];
		let delivery_info = delivery_status(delivery);
		let report_pid = null;
		let report_dcs = null;
		let report_data = { ok: true, encoding: 'status-report', text: '', concat: null,
			message_class: null, mwi: null };
		if (pos < length(bytes)) {
			let pi = bytes[pos++];
			if (pi & 0x80)
				return { ok: false, error_code: 'UNSUPPORTED_PARAMETER_INDICATOR' };
			if (pi & 0x01) {
				if (pos >= length(bytes))
					return { ok: false, error_code: 'TRUNCATED_PDU' };
				report_pid = bytes[pos++];
			}
			if (pi & 0x02) {
				if (pos >= length(bytes))
					return { ok: false, error_code: 'TRUNCATED_PDU' };
				report_dcs = bytes[pos++];
			}
			if (pi & 0x04) {
				if (pos >= length(bytes))
					return { ok: false, error_code: 'TRUNCATED_PDU' };
				let report_udl = bytes[pos++];
				report_data = decode_user_data(bytes, pos, report_udl, report_dcs ?? 0, udhi);
				if (!report_data.ok)
					return report_data;
				pos += report_data.consumed;
			}
		}
		if (pos != length(bytes))
			return { ok: false, error_code: 'TRAILING_PDU_DATA' };
		return {
			ok: true,
			direction: direction,
			number: number,
			timestamp: timestamp,
			discharge_timestamp: discharge_timestamp,
			status: delivery_info.status,
			delivery_category: delivery_info.category,
			message_reference: mr,
			delivery_status: delivery,
			encoding: report_data.encoding,
			text: report_data.text,
			concat: report_data.concat,
			dcs: report_dcs,
			pid: report_pid,
			message_class: report_data.message_class,
			mwi: report_data.mwi
		};
	}
	else {
		return { ok: false, error_code: 'UNSUPPORTED_PDU_TYPE' };
	}

	if (pos >= length(bytes))
		return { ok: false, error_code: 'TRUNCATED_PDU' };

	let udl = bytes[pos++];
	let decoded = decode_user_data(bytes, pos, udl, dcs, udhi);
	if (!decoded.ok)
		return decoded;
	if (pos + decoded.consumed != length(bytes))
		return { ok: false, error_code: 'TRAILING_PDU_DATA' };

	return {
		ok: true,
		direction: direction,
		number: number,
		timestamp: timestamp,
		status: status,
		encoding: decoded.encoding,
		text: decoded.text,
		concat: decoded.concat,
		dcs: dcs,
		pid: pid,
		message_reference: message_reference,
		status_report_requested: direction == 'outbound' ? !!(first & 0x20) : null,
		message_class: decoded.message_class,
		mwi: decoded.mwi
	};
}

function mask_number(number) {
	if (!number)
		return '';
	let prefix = substr(number, 0, 1) == '+' ? '+' : '';
	let digits = prefix ? substr(number, 1) : number;
	if (length(digits) <= 5)
		return number;
	let visible_left = length(digits) >= 10 ? 3 : 2;
	let visible_right = length(digits) >= 8 ? 4 : 2;
	if (visible_left + visible_right >= length(digits))
		visible_right = length(digits) - visible_left - 1;
	let hidden = '';
	for (let i = 0; i < length(digits) - visible_left - visible_right; i++)
		hidden += '*';
	return prefix + substr(digits, 0, visible_left) + hidden + substr(digits, -visible_right);
}

/*
 * A deterministic, non-cryptographic fingerprint used only as an optimistic
 * concurrency guard when deleting messages. Keeping this in pure ucode avoids
 * coupling the package to an optional digest module on target images.
 */
function stable_hash(text) {
	let forward = 2166136261;
	let reverse = 2246822519;

	for (let i = 0; i < length(text); i++) {
		forward = ((forward ^ ord(text, i)) * 16777619) & 0xffffffff;
		reverse = ((reverse ^ ord(text, length(text) - i - 1)) * 16777619) & 0xffffffff;
	}

	return sprintf('%08x%08x', forward, reverse);
}

function message_fingerprint(storage, index, decoded) {
	return stable_hash(`${storage}|${index}|${decoded.direction}|${decoded.number}|${decoded.timestamp}|${decoded.text}`);
}

function message_id(storage, index, fingerprint) {
	return `${lc(storage)}:${index}:${substr(fingerprint, 0, 12)}`;
}

function public_message(message, include_text) {
	let item = {
		id: message.id,
		direction: message.direction,
		number: mask_number(message.number),
		timestamp: message.timestamp,
		preview: utf8_prefix(message.text, 80),
		encoding: message.encoding,
		segments: message.segments ?? 1,
		parts_received: message.parts_received ?? 1,
		complete: message.complete ?? true,
		status: message.status,
		storage_status: message.storage_status,
		storage: message.storage,
		indexes: message.indexes,
		fingerprint: message.fingerprint
	};
	if (include_text)
		item.text = safe_utf8(message.text);
	return item;
}

return {
	SCHEMA_VERSION: SCHEMA_VERSION,
	analyse_text: analyse_text,
	decode_pdu: decode_pdu,
	encode_submit: encode_submit,
	hex_to_bytes: hex_to_bytes,
	bytes_to_hex: bytes_to_hex,
	mask_number: mask_number,
	message_fingerprint: message_fingerprint,
	message_id: message_id,
	public_message: public_message
};
