'use strict';

const fs = require('fs');
const path = require('path');
const { DatabaseSync } = require('node:sqlite');

const schema = fs.readFileSync(path.resolve(__dirname,
	'../packages/modem-sms-archived/files/usr/share/modem-sms/archive_schema.sql'), 'utf8');
const db = new DatabaseSync(':memory:', { allowExtension: false });
db.exec(schema);

const sourceOlder = '1'.repeat(64);
const contentOlder = '2'.repeat(64);
const sourceNewer = '3'.repeat(64);
const contentNewer = '4'.repeat(64);

const insert = db.prepare(`
	INSERT INTO messages (
		archive_id, source_identity_digest, content_digest, direction, number, body,
		message_time, encoding, segments_expected, segments_received, complete,
		archive_quality, association_trust, lossless_archivable, original_source,
		first_archived_at, updated_at
	) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`);

insert.run('a-older', sourceOlder, contentOlder, 'inbound', '+8613800000000', 'fixture older',
	100, 'GSM-7', 1, 1, 1, 'lossless', 'trusted', 1, 'SM', 100, 100);
insert.run('a-newer', sourceNewer, contentNewer, 'outbound', '+8613900000000', 'fixture newer',
	200, 'UCS2', 2, 2, 1, 'lossless', 'trusted', 1, 'ME', 200, 200);

const page = db.prepare(`
	SELECT archive_id FROM messages
	WHERE deleted_at IS NULL
	ORDER BY COALESCE(message_time, 0) DESC, archive_id DESC
	LIMIT ?`).all(10);
if (JSON.stringify(page.map(row => row.archive_id)) !== JSON.stringify(['a-newer', 'a-older']))
	throw new Error('archive ordering is not stable');

const filtered = db.prepare(`
	SELECT COUNT(*) AS count FROM messages
	WHERE deleted_at IS NULL AND direction = ?`).get('inbound');
if (filtered.count !== 1)
	throw new Error(`direction filter failed: ${filtered.count}`);

const duplicate = db.prepare(`
	INSERT INTO messages (
		archive_id, source_identity_digest, content_digest, direction, body,
		encoding, segments_expected, segments_received, complete, archive_quality,
		association_trust, lossless_archivable, original_source, first_archived_at,
		updated_at
	) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`);
let duplicateRejected = false;
try {
	duplicate.run('a-duplicate', sourceOlder, contentOlder, 'inbound', 'duplicate',
		'GSM-7', 1, 1, 1, 'lossless', 'trusted', 1, 'SM', 300, 300);
} catch {
	duplicateRejected = true;
}
if (!duplicateRejected)
	throw new Error('source/content idempotency constraint is missing');

const integrity = db.prepare('PRAGMA integrity_check').get();
if (integrity.integrity_check !== 'ok')
	throw new Error(`integrity check failed: ${integrity.integrity_check}`);

db.close();
console.log('archive-sql.js: SQLite schema and query checks passed');
