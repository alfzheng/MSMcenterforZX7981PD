'use strict';

const fs = require('fs');
const path = require('path');
const { DatabaseSync } = require('node:sqlite');

const schema = fs.readFileSync(path.resolve(__dirname,
	'../packages/modem-sms-archived/files/usr/share/modem-sms/archive_schema.sql'), 'utf8');
const db = new DatabaseSync(':memory:', { allowExtension: false });
db.exec(schema);

const digest = 'a'.repeat(64);
const digestB = 'b'.repeat(64);
const digestC = 'c'.repeat(64);
const now = 100;

const job = db.prepare(`
	INSERT INTO stage_jobs (
		job_id, request_namespace, request_id, principal_id, operation,
		request_digest, selection_digest, token_digest, snapshot_version,
		worker_generation, state, created_at, updated_at, expires_at
	) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`);
job.run('job-1', 'sms-stage-c-v1', 'request-1', 'principal-1', 'move_local',
	digest, digestB, digestC, 7, 'worker-1', 'accepted', now, now, 200);

let duplicateRequestRejected = false;
try {
	job.run('job-2', 'sms-stage-c-v1', 'request-1', 'principal-2', 'move_local',
		digest, digestB, digestC, 7, 'worker-1', 'accepted', now, now, 200);
} catch {
	duplicateRequestRejected = true;
}
if (!duplicateRequestRejected)
	throw new Error('request namespace/idempotency uniqueness is missing');

let invalidDigestRejected = false;
try {
	job.run('job-invalid', 'sms-stage-c-v1', 'request-invalid', 'principal-1', 'move_local',
		'g'.repeat(64), digestB, digestC, 7, 'worker-1', 'accepted', now, now, 200);
} catch {
	invalidDigestRejected = true;
}
if (!invalidDigestRejected)
	throw new Error('non-hex request digest was accepted');

let directDeletingJobRejected = false;
try {
	job.run('job-direct-delete', 'sms-stage-c-v1', 'request-direct-delete', 'principal-1', 'move_local',
		digest, digestB, digestC, 7, 'worker-1', 'deleting', now, now, 200);
} catch {
	directDeletingJobRejected = true;
}
if (!directDeletingJobRejected)
	throw new Error('job could be inserted directly in deleting state');

let deleteWithoutLeaseRejected = false;
try {
	job.run('job-delete-closed', 'sms-stage-c-v1', 'request-delete-closed', 'principal-1', 'delete_device',
		digest, digestB, digestC, 7, 'worker-1', 'accepted', now, now, 200);
} catch {
	deleteWithoutLeaseRejected = true;
}
if (!deleteWithoutLeaseRejected)
	throw new Error('device-delete job bypassed the closed gate or lease binding');

const item = db.prepare(`
	INSERT INTO stage_job_items (
		job_id, item_no, archive_id, source_identity_digest, content_digest,
		storage, storage_index, scan_epoch, source_generation, source_token_digest,
		segment_no, segment_total, raw_pdu_sha256, archive_pin,
		state, created_at, updated_at
	) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`);
item.run('job-1', 0, 'archive-1', digest, digestB, 'SM', 7, 'epoch-1', 3,
	digestC, 1, 1, digest, digestB, 'proposed', now, now);
db.prepare("UPDATE stage_job_items SET state = 'archived' WHERE job_id = 'job-1' AND item_no = 0").run();
db.prepare("UPDATE stage_job_items SET state = 'ready' WHERE job_id = 'job-1' AND item_no = 0").run();
db.prepare("UPDATE stage_jobs SET state = 'validating' WHERE job_id = 'job-1'").run();
db.prepare("UPDATE stage_jobs SET state = 'archiving' WHERE job_id = 'job-1'").run();
db.prepare("UPDATE stage_jobs SET state = 'ready' WHERE job_id = 'job-1'").run();

const tombstone = db.prepare(`
	INSERT INTO stage_tombstones (
		tombstone_id, operation, job_id, item_no, principal_id, request_namespace,
		source_identity_digest, storage, storage_index, scan_epoch,
		source_generation, raw_pdu_sha256, state, created_at, updated_at
	) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`);
tombstone.run('tombstone-1', 'move_local', 'job-1', 0, 'principal-1', 'sms-stage-c-v1',
	digest, 'SM', 7, 'epoch-1', 3, digest, 'reserved', now, now);

let tombstoneIdentityUpdateRejected = false;
try {
	db.prepare("UPDATE stage_tombstones SET principal_id = 'principal-2' WHERE tombstone_id = 'tombstone-1'").run();
} catch {
	tombstoneIdentityUpdateRejected = true;
}
if (!tombstoneIdentityUpdateRejected)
	throw new Error('tombstone identity was mutable');

const lease = db.prepare(`
	INSERT INTO stage_cpms_leases (
		lease_scope, owner_id, owner_nonce_digest, storage, lease_generation,
		state, acquired_at, renewed_at, expires_at
	) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`);
let invalidLeaseInsertRejected = false;
try {
	lease.run('global', 'owner-invalid', digest, 'SM', 0, 'released', now, now, 200);
} catch {
	invalidLeaseInsertRejected = true;
}
if (!invalidLeaseInsertRejected)
	throw new Error('invalid initial CPMS lease was accepted');
lease.run('global', 'owner-1', digest, 'SM', 1, 'active', now, now, 200);
let activeLeaseOwnerSwapRejected = false;
try {
	db.prepare("UPDATE stage_cpms_leases SET owner_id = 'owner-2' WHERE lease_scope = 'global'").run();
} catch {
	activeLeaseOwnerSwapRejected = true;
}
if (!activeLeaseOwnerSwapRejected)
	throw new Error('active CPMS lease owner was mutable');
let activeLeaseStorageSwapRejected = false;
try {
	db.prepare("UPDATE stage_cpms_leases SET storage = 'ME' WHERE lease_scope = 'global'").run();
} catch {
	activeLeaseStorageSwapRejected = true;
}
if (!activeLeaseStorageSwapRejected)
	throw new Error('active CPMS lease storage was mutable');
let activeLeaseAcquiredAtRewriteRejected = false;
try {
	db.prepare('UPDATE stage_cpms_leases SET acquired_at = 999 WHERE lease_scope = \'global\'').run();
} catch {
	activeLeaseAcquiredAtRewriteRejected = true;
}
if (!activeLeaseAcquiredAtRewriteRejected)
	throw new Error('active CPMS lease acquired_at was mutable');
db.prepare("UPDATE stage_cpms_leases SET state = 'released' WHERE lease_scope = 'global'").run();
let releasedLeaseRewriteRejected = false;
try {
	db.prepare("UPDATE stage_cpms_leases SET owner_id = 'forged-owner' WHERE lease_scope = 'global'").run();
} catch {
	releasedLeaseRewriteRejected = true;
}
if (!releasedLeaseRewriteRejected)
	throw new Error('released CPMS lease history was mutable');
db.prepare(`UPDATE stage_cpms_leases SET owner_id = 'owner-2', owner_nonce_digest = ?,
	lease_generation = 2, state = 'active' WHERE lease_scope = 'global'`).run(digestB);
if (db.prepare('SELECT COUNT(*) AS count FROM stage_cpms_lease_history').get().count !== 3)
	throw new Error('CPMS lease history was not append-only recorded');
let leaseDeleteRejected = false;
try {
	db.prepare("DELETE FROM stage_cpms_leases WHERE lease_scope = 'global'").run();
} catch {
	leaseDeleteRejected = true;
}
if (!leaseDeleteRejected)
	throw new Error('CPMS lease deletion was allowed');
let leaseHistoryDeleteRejected = false;
try {
	db.prepare("DELETE FROM stage_cpms_lease_history WHERE lease_scope = 'global'").run();
} catch {
	leaseHistoryDeleteRejected = true;
}
if (!leaseHistoryDeleteRejected)
	throw new Error('CPMS lease history deletion was allowed');

let unsafeAuditDetailRejected = false;
try {
	db.prepare(`INSERT INTO stage_events (job_id, event, state, detail_code, created_at)
		VALUES ('job-1', 'DELETE_STARTED', 'deleting', 'body leaked', 100)`).run();
} catch {
	unsafeAuditDetailRejected = true;
}
if (!unsafeAuditDetailRejected)
	throw new Error('unsafe audit detail was accepted');
const safeEvent = db.prepare(`
	INSERT INTO stage_events (job_id, item_no, event, state, detail_code, created_at)
	VALUES ('job-1', 0, 'DELETE_STARTED', 'deleting', 'PRECHECK_OK', 100)`);
safeEvent.run();
const safeEventId = db.prepare('SELECT max(event_id) AS event_id FROM stage_events').get().event_id;
let auditUpdateRejected = false;
try {
	db.prepare("UPDATE stage_events SET detail_code = 'FORGED' WHERE event_id = ?").run(safeEventId);
} catch {
	auditUpdateRejected = true;
}
if (!auditUpdateRejected)
	throw new Error('audit event was mutable');
let auditDeleteRejected = false;
try {
	db.prepare("DELETE FROM stage_events WHERE event_id = ?").run(safeEventId);
} catch {
	auditDeleteRejected = true;
}
if (!auditDeleteRejected)
	throw new Error('audit event deletion was allowed');

const setJobState = db.prepare('UPDATE stage_jobs SET state = ?, updated_at = ? WHERE job_id = ?');
let moveLocalDeleteStateRejected = false;
try {
	setJobState.run('deleting', now + 1, 'job-1');
} catch {
	moveLocalDeleteStateRejected = true;
}
if (!moveLocalDeleteStateRejected)
	throw new Error('move_local job was allowed to enter deleting state');

job.run('job-unknown', 'sms-stage-c-v1', 'request-unknown', 'principal-1', 'move_local',
	digest, digestB, digestC, 7, 'worker-1', 'accepted', now, now, 200);
setJobState.run('unknown', now + 1, 'job-unknown');

let unknownResumeRejected = false;
try {
	setJobState.run('deleting', now + 2, 'job-unknown');
} catch {
	unknownResumeRejected = true;
}
if (!unknownResumeRejected)
	throw new Error('unknown job was allowed to resume');

const setItemState = db.prepare('UPDATE stage_job_items SET state = ?, updated_at = ? WHERE job_id = ? AND item_no = ?');
let moveLocalDeleteItemStateRejected = false;
try {
	setItemState.run('deleting', now + 1, 'job-1', 0);
} catch {
	moveLocalDeleteItemStateRejected = true;
}
if (!moveLocalDeleteItemStateRejected)
	throw new Error('move_local item was allowed to enter deleting state');

db.prepare("UPDATE metadata SET value = '1' WHERE key = 'stage_c_delete_enabled'").run();
const deleteJob = db.prepare(`
	INSERT INTO stage_jobs (
		job_id, request_namespace, request_id, principal_id, operation,
		request_digest, selection_digest, token_digest, snapshot_version,
		worker_generation, lease_generation, lease_acquired_at, lease_owner_id, lease_nonce_digest,
		lease_storage, state, created_at, updated_at, expires_at
	) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`);
let deleteAcquiredAtMismatchRejected = false;
try {
	deleteJob.run('job-delete-mismatch', 'sms-stage-c-v1', 'request-delete-mismatch', 'principal-1', 'delete_device',
		digest, digestB, digestC, 7, 'worker-1', 2, 99, 'owner-2', digestB, 'SM',
		'accepted', now, now, 200);
} catch {
	deleteAcquiredAtMismatchRejected = true;
}
if (!deleteAcquiredAtMismatchRejected)
	throw new Error('device-delete job bypassed lease acquired_at binding');
deleteJob.run('job-delete', 'sms-stage-c-v1', 'request-delete', 'principal-1', 'delete_device',
		digest, digestB, digestC, 7, 'worker-1', 2, 100, 'owner-2', digestB, 'SM',
	'accepted', now, now, 200);
item.run('job-delete', 0, 'archive-2', digest, digestB, 'SM', 8, 'epoch-1', 3,
	digestC, 1, 1, digest, digestB, 'proposed', now, now);
for (const state of ['validating', 'archiving', 'ready', 'deleting'])
	setJobState.run(state, now + 1, 'job-delete');
for (const state of ['archived', 'ready', 'deleting'])
	setItemState.run(state, now + 1, 'job-delete', 0);

tombstone.run('tombstone-2', 'delete_device', 'job-delete', 0, 'principal-1', 'sms-stage-c-v1',
	digest, 'SM', 8, 'epoch-1', 3, digest, 'reserved', now, now);

let deleteCompletionWithoutClaimRejected = false;
try {
	setItemState.run('completed', now + 2, 'job-delete', 0);
} catch {
	deleteCompletionWithoutClaimRejected = true;
}
if (!deleteCompletionWithoutClaimRejected)
	throw new Error('device-delete completion without a claim was allowed');

const claimDelete = db.prepare(`
	UPDATE stage_job_items
	SET delete_call_count = 1, updated_at = ?
	WHERE job_id = ? AND item_no = ? AND state = 'deleting' AND delete_call_count = 0`);
	claimDelete.run(now + 2, 'job-delete', 0);
	if (db.prepare('SELECT changes() AS count').get().count !== 1)
	throw new Error('first delete claim was not recorded');
	claimDelete.run(now + 3, 'job-delete', 0);
	if (db.prepare('SELECT changes() AS count').get().count !== 0)
	throw new Error('delete claim was replayed');
	setItemState.run('completed', now + 4, 'job-delete', 0);
	let openTombstoneParentRejected = false;
	try {
		setJobState.run('completed', now + 4, 'job-delete');
	} catch {
		openTombstoneParentRejected = true;
	}
	if (!openTombstoneParentRejected)
		throw new Error('job completed with an open tombstone');
	db.prepare("UPDATE stage_tombstones SET state = 'completed' WHERE tombstone_id = 'tombstone-2'").run();
	setJobState.run('completed', now + 4, 'job-delete');

let deleteClaimResetRejected = false;
try {
	db.prepare(`UPDATE stage_job_items SET delete_call_count = 0
		WHERE job_id = 'job-delete' AND item_no = 0`).run();
} catch {
	deleteClaimResetRejected = true;
}
if (!deleteClaimResetRejected)
	throw new Error('delete claim reset was allowed');

let jobDeleteRejected = false;
try {
	db.prepare("DELETE FROM stage_jobs WHERE job_id = 'job-unknown'").run();
} catch {
	jobDeleteRejected = true;
}
if (!jobDeleteRejected)
	throw new Error('durable job deletion was allowed');
let itemDeleteRejected = false;
try {
	db.prepare("DELETE FROM stage_job_items WHERE job_id = 'job-1' AND item_no = 0").run();
} catch {
	itemDeleteRejected = true;
}
if (!itemDeleteRejected)
	throw new Error('durable item deletion was allowed');

let tombstoneDeleteRejected = false;
try {
	db.prepare("DELETE FROM stage_tombstones WHERE tombstone_id = 'tombstone-1'").run();
} catch {
	tombstoneDeleteRejected = true;
}
if (!tombstoneDeleteRejected)
	throw new Error('tombstone deletion was allowed');

const tables = db.prepare(`
	SELECT name FROM sqlite_master
	WHERE type = 'table' AND name LIKE 'stage_%'
	ORDER BY name`).all().map(row => row.name);
const expected = ['stage_cpms_lease_history', 'stage_cpms_leases', 'stage_events',
	'stage_job_items', 'stage_jobs', 'stage_tombstones'];
if (JSON.stringify(tables) !== JSON.stringify(expected))
	throw new Error(`Stage C tables mismatch: ${JSON.stringify(tables)}`);

const integrity = db.prepare('PRAGMA integrity_check').get();
if (integrity.integrity_check !== 'ok')
	throw new Error(`integrity check failed: ${integrity.integrity_check}`);

db.close();
console.log('stagec-sql.js: durable Stage C state and fail-closed transition checks passed');
