PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS metadata (
    key TEXT NOT NULL PRIMARY KEY,
    value TEXT NOT NULL
);

INSERT OR IGNORE INTO metadata(key, value) VALUES
    ('schema_version', '2'),
    ('stage_c_schema_version', '1'),
    ('stage_c_delete_enabled', '0'),
    ('snapshot_version', '0'),
    ('recovery_incomplete', '0'),
    ('last_integrity_check_at', '0'),
    ('last_backup_manifest_sha256', '');

CREATE TABLE IF NOT EXISTS messages (
    archive_id TEXT NOT NULL PRIMARY KEY,
    source_identity_digest TEXT NOT NULL CHECK (length(source_identity_digest) = 64
        AND source_identity_digest NOT GLOB '*[^0-9A-Fa-f]*'),
    content_digest TEXT NOT NULL CHECK (length(content_digest) = 64
        AND content_digest NOT GLOB '*[^0-9A-Fa-f]*'),
    direction TEXT NOT NULL CHECK (direction IN ('inbound', 'outbound')),
    number TEXT,
    body TEXT NOT NULL,
    message_time INTEGER,
    encoding TEXT NOT NULL,
    segments_expected INTEGER NOT NULL,
    segments_received INTEGER NOT NULL,
    complete INTEGER NOT NULL CHECK (complete IN (0, 1)),
    archive_quality TEXT NOT NULL,
    association_trust TEXT NOT NULL,
    lossless_archivable INTEGER NOT NULL CHECK (lossless_archivable IN (0, 1)),
    original_source TEXT NOT NULL,
    first_archived_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    deleted_at INTEGER,
    UNIQUE (source_identity_digest, content_digest)
);

CREATE TABLE IF NOT EXISTS message_sources (
    archive_id TEXT NOT NULL,
    storage TEXT NOT NULL,
    storage_index INTEGER NOT NULL,
    scan_epoch TEXT NOT NULL,
    source_generation INTEGER NOT NULL,
    source_token_digest TEXT NOT NULL DEFAULT '' CHECK (source_token_digest = '' OR (
        length(source_token_digest) = 64
        AND source_token_digest NOT GLOB '*[^0-9A-Fa-f]*')),
    segment_no INTEGER NOT NULL DEFAULT 1,
    segment_total INTEGER NOT NULL DEFAULT 1,
    raw_pdu BLOB NOT NULL,
    raw_pdu_sha256 TEXT NOT NULL CHECK (length(raw_pdu_sha256) = 64
        AND raw_pdu_sha256 NOT GLOB '*[^0-9A-Fa-f]*'),
    first_seen_at INTEGER NOT NULL,
    last_seen_at INTEGER NOT NULL,
    PRIMARY KEY (archive_id, storage, storage_index, source_generation),
    FOREIGN KEY (archive_id) REFERENCES messages(archive_id) ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS idx_messages_page
    ON messages(message_time DESC, archive_id DESC);
CREATE INDEX IF NOT EXISTS idx_messages_source
    ON messages(original_source, direction, archive_quality, association_trust);
CREATE INDEX IF NOT EXISTS idx_message_sources_identity
    ON message_sources(storage, storage_index, source_generation);

/* Stage C foundation. These tables are durable state only; no public RPC is
 * allowed to create or execute a destructive job until the separate release
 * gates are complete. Raw PDU, body, number and opaque tokens never belong in
 * this state or audit data; only their digests are retained. */
CREATE TABLE IF NOT EXISTS stage_jobs (
    job_id TEXT NOT NULL PRIMARY KEY,
    request_namespace TEXT NOT NULL,
    request_id TEXT NOT NULL,
    principal_id TEXT NOT NULL,
    operation TEXT NOT NULL CHECK (operation IN ('move_local', 'delete_device')),
    request_digest TEXT NOT NULL CHECK (length(request_digest) = 64
        AND request_digest NOT GLOB '*[^0-9A-Fa-f]*'),
    selection_digest TEXT NOT NULL CHECK (length(selection_digest) = 64
        AND selection_digest NOT GLOB '*[^0-9A-Fa-f]*'),
    token_digest TEXT NOT NULL CHECK (length(token_digest) = 64
        AND token_digest NOT GLOB '*[^0-9A-Fa-f]*'),
    snapshot_version INTEGER NOT NULL,
    worker_generation TEXT NOT NULL,
    state TEXT NOT NULL CHECK (state IN (
        'accepted', 'validating', 'archiving', 'ready', 'deleting',
        'completed', 'failed', 'unknown', 'blocked'
    )),
    error_code TEXT CHECK (error_code IS NULL OR (
        length(error_code) BETWEEN 1 AND 64
        AND error_code NOT GLOB '*[^A-Z0-9_]*')),
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    UNIQUE (request_namespace, request_id)
);

CREATE TABLE IF NOT EXISTS stage_job_items (
    job_id TEXT NOT NULL,
    item_no INTEGER NOT NULL CHECK (item_no >= 0),
    archive_id TEXT NOT NULL,
    source_identity_digest TEXT NOT NULL CHECK (length(source_identity_digest) = 64
        AND source_identity_digest NOT GLOB '*[^0-9A-Fa-f]*'),
    content_digest TEXT NOT NULL CHECK (length(content_digest) = 64
        AND content_digest NOT GLOB '*[^0-9A-Fa-f]*'),
    storage TEXT NOT NULL CHECK (storage IN ('SM', 'ME')),
    storage_index INTEGER NOT NULL CHECK (storage_index >= 0),
    scan_epoch TEXT NOT NULL,
    source_generation INTEGER NOT NULL,
    source_token_digest TEXT NOT NULL CHECK (length(source_token_digest) = 64
        AND source_token_digest NOT GLOB '*[^0-9A-Fa-f]*'),
    segment_no INTEGER NOT NULL CHECK (segment_no >= 1),
    segment_total INTEGER NOT NULL CHECK (segment_total >= segment_no),
    raw_pdu_sha256 TEXT NOT NULL CHECK (length(raw_pdu_sha256) = 64
        AND raw_pdu_sha256 NOT GLOB '*[^0-9A-Fa-f]*'),
    archive_pin TEXT NOT NULL CHECK (length(archive_pin) = 64
        AND archive_pin NOT GLOB '*[^0-9A-Fa-f]*'),
    state TEXT NOT NULL CHECK (state IN (
        'proposed', 'archived', 'ready', 'deleting', 'completed',
        'failed', 'unknown', 'blocked'
    )),
    delete_call_count INTEGER NOT NULL DEFAULT 0 CHECK (delete_call_count IN (0, 1)),
    outcome_unknown INTEGER NOT NULL DEFAULT 0 CHECK (outcome_unknown IN (0, 1)),
    error_code TEXT CHECK (error_code IS NULL OR (
        length(error_code) BETWEEN 1 AND 64
        AND error_code NOT GLOB '*[^A-Z0-9_]*')),
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    PRIMARY KEY (job_id, item_no),
    UNIQUE (job_id, storage, storage_index, source_generation),
    FOREIGN KEY (job_id) REFERENCES stage_jobs(job_id) ON DELETE RESTRICT
);

CREATE TABLE IF NOT EXISTS stage_tombstones (
    tombstone_id TEXT NOT NULL PRIMARY KEY,
    operation TEXT NOT NULL CHECK (operation IN ('move_local', 'delete_device')),
    job_id TEXT NOT NULL,
    item_no INTEGER NOT NULL CHECK (item_no >= 0),
    principal_id TEXT NOT NULL,
    request_namespace TEXT NOT NULL,
    source_identity_digest TEXT NOT NULL CHECK (length(source_identity_digest) = 64
        AND source_identity_digest NOT GLOB '*[^0-9A-Fa-f]*'),
    storage TEXT NOT NULL CHECK (storage IN ('SM', 'ME')),
    storage_index INTEGER NOT NULL CHECK (storage_index >= 0),
    scan_epoch TEXT NOT NULL,
    source_generation INTEGER NOT NULL,
    raw_pdu_sha256 TEXT NOT NULL CHECK (length(raw_pdu_sha256) = 64
        AND raw_pdu_sha256 NOT GLOB '*[^0-9A-Fa-f]*'),
    state TEXT NOT NULL CHECK (state IN ('reserved', 'completed', 'unknown', 'blocked')),
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    UNIQUE (operation, storage, storage_index, scan_epoch, source_generation, raw_pdu_sha256),
    FOREIGN KEY (job_id, item_no) REFERENCES stage_job_items(job_id, item_no) ON DELETE RESTRICT
);

CREATE TABLE IF NOT EXISTS stage_cpms_leases (
    lease_scope TEXT NOT NULL PRIMARY KEY CHECK (lease_scope = 'global'),
    owner_id TEXT NOT NULL,
    owner_nonce_digest TEXT NOT NULL CHECK (length(owner_nonce_digest) = 64
        AND owner_nonce_digest NOT GLOB '*[^0-9A-Fa-f]*'),
    storage TEXT CHECK (storage IS NULL OR storage IN ('SM', 'ME')),
    lease_generation INTEGER NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('active', 'released', 'lost')),
    acquired_at INTEGER NOT NULL,
    renewed_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS stage_cpms_lease_history (
    lease_scope TEXT NOT NULL CHECK (lease_scope = 'global'),
    lease_generation INTEGER NOT NULL CHECK (lease_generation >= 1),
    state TEXT NOT NULL CHECK (state IN ('active', 'released', 'lost')),
    owner_id TEXT NOT NULL,
    owner_nonce_digest TEXT NOT NULL CHECK (length(owner_nonce_digest) = 64
        AND owner_nonce_digest NOT GLOB '*[^0-9A-Fa-f]*'),
    storage TEXT CHECK (storage IS NULL OR storage IN ('SM', 'ME')),
    acquired_at INTEGER NOT NULL,
    renewed_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    recorded_at INTEGER NOT NULL,
    PRIMARY KEY (lease_scope, lease_generation, state)
);

CREATE TABLE IF NOT EXISTS stage_events (
    event_id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
    job_id TEXT,
    item_no INTEGER,
    event TEXT NOT NULL CHECK (length(event) BETWEEN 1 AND 64
        AND event NOT GLOB '*[^A-Z0-9_]*'),
    state TEXT NOT NULL CHECK (state IN (
        'accepted', 'validating', 'archiving', 'ready', 'deleting',
        'completed', 'failed', 'unknown', 'blocked', 'reserved'
    )),
    detail_code TEXT CHECK (detail_code IS NULL OR (
        length(detail_code) BETWEEN 1 AND 64
        AND detail_code NOT GLOB '*[^A-Z0-9_]*')),
    created_at INTEGER NOT NULL,
    FOREIGN KEY (job_id) REFERENCES stage_jobs(job_id) ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS idx_stage_jobs_lookup
    ON stage_jobs(principal_id, request_namespace, request_id);
CREATE INDEX IF NOT EXISTS idx_stage_job_items_state
    ON stage_job_items(job_id, state, item_no);
CREATE INDEX IF NOT EXISTS idx_stage_tombstones_identity
    ON stage_tombstones(operation, storage, storage_index, scan_epoch, source_generation);

CREATE TRIGGER IF NOT EXISTS stage_cpms_lease_history_insert
AFTER INSERT ON stage_cpms_leases
BEGIN
    INSERT INTO stage_cpms_lease_history (
        lease_scope, lease_generation, state, owner_id, owner_nonce_digest,
        storage, acquired_at, renewed_at, expires_at, recorded_at)
    VALUES (NEW.lease_scope, NEW.lease_generation, NEW.state, NEW.owner_id,
        NEW.owner_nonce_digest, NEW.storage, NEW.acquired_at, NEW.renewed_at,
        NEW.expires_at, NEW.renewed_at);
END;

CREATE TRIGGER IF NOT EXISTS stage_cpms_lease_history_update
AFTER UPDATE OF state, lease_generation ON stage_cpms_leases
WHEN NEW.state <> OLD.state OR NEW.lease_generation <> OLD.lease_generation
BEGIN
    INSERT INTO stage_cpms_lease_history (
        lease_scope, lease_generation, state, owner_id, owner_nonce_digest,
        storage, acquired_at, renewed_at, expires_at, recorded_at)
    VALUES (NEW.lease_scope, NEW.lease_generation, NEW.state, NEW.owner_id,
        NEW.owner_nonce_digest, NEW.storage, NEW.acquired_at, NEW.renewed_at,
        NEW.expires_at, NEW.renewed_at);
END;

CREATE TRIGGER IF NOT EXISTS stage_cpms_lease_history_immutable
BEFORE UPDATE ON stage_cpms_lease_history
BEGIN
    SELECT RAISE(ABORT, 'CPMS_LEASE_HISTORY_IMMUTABLE');
END;

CREATE TRIGGER IF NOT EXISTS stage_cpms_lease_history_no_delete
BEFORE DELETE ON stage_cpms_lease_history
BEGIN
    SELECT RAISE(ABORT, 'CPMS_LEASE_HISTORY_IMMUTABLE');
END;

CREATE TRIGGER IF NOT EXISTS stage_events_no_update
BEFORE UPDATE ON stage_events
BEGIN
    SELECT RAISE(ABORT, 'STAGE_EVENT_IMMUTABLE');
END;

CREATE TRIGGER IF NOT EXISTS stage_events_no_delete
BEFORE DELETE ON stage_events
BEGIN
    SELECT RAISE(ABORT, 'STAGE_EVENT_IMMUTABLE');
END;

CREATE TRIGGER IF NOT EXISTS stage_jobs_insert_gate
BEFORE INSERT ON stage_jobs
WHEN NEW.state <> 'accepted'
BEGIN
    SELECT RAISE(ABORT, 'STAGE_JOB_MUST_START_ACCEPTED');
END;

CREATE TRIGGER IF NOT EXISTS stage_jobs_no_delete
BEFORE DELETE ON stage_jobs
BEGIN
    SELECT RAISE(ABORT, 'STAGE_JOB_IMMUTABLE');
END;

CREATE TRIGGER IF NOT EXISTS stage_job_items_no_delete
BEFORE DELETE ON stage_job_items
BEGIN
    SELECT RAISE(ABORT, 'STAGE_ITEM_IMMUTABLE');
END;

CREATE TRIGGER IF NOT EXISTS stage_job_items_insert_gate
BEFORE INSERT ON stage_job_items
WHEN NEW.state <> 'proposed'
    OR NEW.delete_call_count <> 0
    OR NEW.outcome_unknown <> 0
    OR NOT EXISTS (
        SELECT 1 FROM stage_jobs
        WHERE job_id = NEW.job_id
            AND state IN ('accepted', 'validating', 'archiving', 'ready', 'deleting'))
BEGIN
    SELECT RAISE(ABORT, 'STAGE_ITEM_INITIAL_STATE_INVALID');
END;

CREATE TRIGGER IF NOT EXISTS stage_tombstones_insert_gate
BEFORE INSERT ON stage_tombstones
WHEN NEW.state <> 'reserved'
    OR NOT EXISTS (
        SELECT 1
        FROM stage_jobs AS j
        JOIN stage_job_items AS i ON i.job_id = j.job_id AND i.item_no = NEW.item_no
        WHERE j.job_id = NEW.job_id
            AND j.operation = NEW.operation
            AND j.principal_id = NEW.principal_id
            AND j.request_namespace = NEW.request_namespace
            AND j.state IN ('ready', 'deleting')
            AND i.state IN ('ready', 'deleting')
            AND i.source_identity_digest = NEW.source_identity_digest
            AND i.storage = NEW.storage
            AND i.storage_index = NEW.storage_index
            AND i.scan_epoch = NEW.scan_epoch
            AND i.source_generation = NEW.source_generation
            AND i.raw_pdu_sha256 = NEW.raw_pdu_sha256)
BEGIN
    SELECT RAISE(ABORT, 'STAGE_TOMBSTONE_BINDING_INVALID');
END;

CREATE TRIGGER IF NOT EXISTS stage_jobs_identity_immutable
BEFORE UPDATE OF request_namespace, request_id, principal_id, operation,
    request_digest, selection_digest, token_digest, snapshot_version,
    worker_generation, created_at, expires_at ON stage_jobs
WHEN NEW.request_namespace <> OLD.request_namespace
    OR NEW.request_id <> OLD.request_id
    OR NEW.principal_id <> OLD.principal_id
    OR NEW.operation <> OLD.operation
    OR NEW.request_digest <> OLD.request_digest
    OR NEW.selection_digest <> OLD.selection_digest
    OR NEW.token_digest <> OLD.token_digest
    OR NEW.snapshot_version <> OLD.snapshot_version
    OR NEW.worker_generation <> OLD.worker_generation
    OR NEW.created_at <> OLD.created_at
    OR NEW.expires_at <> OLD.expires_at
BEGIN
    SELECT RAISE(ABORT, 'STAGE_JOB_IDENTITY_IMMUTABLE');
END;

CREATE TRIGGER IF NOT EXISTS stage_job_items_identity_immutable
BEFORE UPDATE OF job_id, item_no, archive_id, source_identity_digest, content_digest,
    storage, storage_index, scan_epoch, source_generation, source_token_digest,
    segment_no, segment_total, raw_pdu_sha256, archive_pin ON stage_job_items
WHEN NEW.job_id <> OLD.job_id
    OR NEW.item_no <> OLD.item_no
    OR NEW.archive_id <> OLD.archive_id
    OR NEW.source_identity_digest <> OLD.source_identity_digest
    OR NEW.content_digest <> OLD.content_digest
    OR NEW.storage <> OLD.storage
    OR NEW.storage_index <> OLD.storage_index
    OR NEW.scan_epoch <> OLD.scan_epoch
    OR NEW.source_generation <> OLD.source_generation
    OR NEW.source_token_digest <> OLD.source_token_digest
    OR NEW.segment_no <> OLD.segment_no
    OR NEW.segment_total <> OLD.segment_total
    OR NEW.raw_pdu_sha256 <> OLD.raw_pdu_sha256
    OR NEW.archive_pin <> OLD.archive_pin
BEGIN
    SELECT RAISE(ABORT, 'STAGE_ITEM_IDENTITY_IMMUTABLE');
END;

CREATE TRIGGER IF NOT EXISTS stage_tombstones_identity_immutable
BEFORE UPDATE OF tombstone_id, operation, job_id, item_no, principal_id,
    request_namespace, source_identity_digest, storage, storage_index,
    scan_epoch, source_generation, raw_pdu_sha256, created_at ON stage_tombstones
WHEN NEW.tombstone_id <> OLD.tombstone_id
    OR NEW.operation <> OLD.operation
    OR NEW.job_id <> OLD.job_id
    OR NEW.item_no <> OLD.item_no
    OR NEW.principal_id <> OLD.principal_id
    OR NEW.request_namespace <> OLD.request_namespace
    OR NEW.source_identity_digest <> OLD.source_identity_digest
    OR NEW.storage <> OLD.storage
    OR NEW.storage_index <> OLD.storage_index
    OR NEW.scan_epoch <> OLD.scan_epoch
    OR NEW.source_generation <> OLD.source_generation
    OR NEW.raw_pdu_sha256 <> OLD.raw_pdu_sha256
    OR NEW.created_at <> OLD.created_at
BEGIN
    SELECT RAISE(ABORT, 'STAGE_TOMBSTONE_IMMUTABLE');
END;

CREATE TRIGGER IF NOT EXISTS stage_jobs_terminal_state
BEFORE UPDATE OF state ON stage_jobs
WHEN OLD.state IN ('completed', 'failed', 'unknown', 'blocked')
    AND NEW.state <> OLD.state
BEGIN
    SELECT RAISE(ABORT, 'STAGE_JOB_TERMINAL');
END;

CREATE TRIGGER IF NOT EXISTS stage_jobs_valid_transition
BEFORE UPDATE OF state ON stage_jobs
WHEN NOT (
    (OLD.state = 'accepted' AND NEW.state IN ('validating', 'failed', 'unknown', 'blocked')) OR
    (OLD.state = 'validating' AND NEW.state IN ('archiving', 'ready', 'failed', 'unknown', 'blocked')) OR
    (OLD.state = 'archiving' AND NEW.state IN ('ready', 'failed', 'unknown', 'blocked')) OR
    (OLD.state = 'ready' AND NEW.state IN ('deleting', 'failed', 'unknown', 'blocked')) OR
    (OLD.state = 'deleting' AND NEW.state IN ('completed', 'failed', 'unknown', 'blocked')) OR
    NEW.state = OLD.state
)
BEGIN
    SELECT RAISE(ABORT, 'STAGE_JOB_INVALID_TRANSITION');
END;

CREATE TRIGGER IF NOT EXISTS stage_jobs_completion_parent_state
BEFORE UPDATE OF state ON stage_jobs
WHEN NEW.state = 'completed'
    AND EXISTS (
        SELECT 1 FROM stage_job_items
        WHERE job_id = NEW.job_id AND state <> 'completed')
    OR NEW.state = 'completed'
    AND EXISTS (
        SELECT 1 FROM stage_tombstones AS t
        JOIN stage_job_items AS i ON i.job_id = t.job_id AND i.item_no = t.item_no
        WHERE t.job_id = NEW.job_id AND t.state = 'reserved')
BEGIN
    SELECT RAISE(ABORT, 'STAGE_JOB_CHILDREN_NOT_COMPLETE');
END;

CREATE TRIGGER IF NOT EXISTS stage_job_items_terminal_state
BEFORE UPDATE OF state ON stage_job_items
WHEN OLD.state IN ('completed', 'failed', 'unknown', 'blocked')
    AND NEW.state <> OLD.state
BEGIN
    SELECT RAISE(ABORT, 'STAGE_ITEM_TERMINAL');
END;

CREATE TRIGGER IF NOT EXISTS stage_job_items_failed_reserved_tombstone
BEFORE UPDATE OF state ON stage_job_items
WHEN NEW.state = 'failed'
    AND EXISTS (
        SELECT 1 FROM stage_tombstones
        WHERE job_id = NEW.job_id AND item_no = NEW.item_no AND state = 'reserved')
BEGIN
    SELECT RAISE(ABORT, 'STAGE_ITEM_TOMBSTONE_OPEN');
END;

CREATE TRIGGER IF NOT EXISTS stage_job_items_valid_transition
BEFORE UPDATE OF state ON stage_job_items
WHEN NOT (
    (OLD.state = 'proposed' AND NEW.state IN ('archived', 'failed', 'unknown', 'blocked')) OR
    (OLD.state = 'archived' AND NEW.state IN ('ready', 'failed', 'unknown', 'blocked')) OR
    (OLD.state = 'ready' AND NEW.state IN ('deleting', 'failed', 'unknown', 'blocked')) OR
    (OLD.state = 'deleting' AND NEW.state IN ('completed', 'failed', 'unknown', 'blocked')) OR
    NEW.state = OLD.state
)
BEGIN
    SELECT RAISE(ABORT, 'STAGE_ITEM_INVALID_TRANSITION');
END;

CREATE TRIGGER IF NOT EXISTS stage_job_items_delete_completion_claim
BEFORE UPDATE OF state ON stage_job_items
WHEN NEW.state = 'completed'
    AND (SELECT operation FROM stage_jobs WHERE job_id = NEW.job_id) = 'delete_device'
    AND NEW.delete_call_count <> 1
BEGIN
    SELECT RAISE(ABORT, 'DELETE_COMPLETION_REQUIRES_CLAIM');
END;

CREATE TRIGGER IF NOT EXISTS stage_job_items_delete_call_once
BEFORE UPDATE OF delete_call_count ON stage_job_items
WHEN NEW.delete_call_count < OLD.delete_call_count
    OR NEW.delete_call_count > 1
    OR (OLD.delete_call_count = 1 AND NEW.delete_call_count <> OLD.delete_call_count)
    OR (NEW.delete_call_count = 1 AND (
        NEW.state <> 'deleting'
        OR (SELECT operation FROM stage_jobs WHERE job_id = NEW.job_id) <> 'delete_device'
        OR NOT EXISTS (
            SELECT 1 FROM stage_tombstones
            WHERE job_id = NEW.job_id AND item_no = NEW.item_no AND state = 'reserved')))
BEGIN
    SELECT RAISE(ABORT, 'DELETE_RETRY_FORBIDDEN');
END;

CREATE TRIGGER IF NOT EXISTS stage_tombstones_terminal_state
BEFORE UPDATE OF state ON stage_tombstones
WHEN OLD.state IN ('completed', 'unknown', 'blocked')
    AND NEW.state <> OLD.state
BEGIN
    SELECT RAISE(ABORT, 'STAGE_TOMBSTONE_TERMINAL');
END;

CREATE TRIGGER IF NOT EXISTS stage_tombstones_valid_transition
BEFORE UPDATE OF state ON stage_tombstones
WHEN NOT (
    (OLD.state = 'reserved' AND NEW.state IN ('completed', 'unknown', 'blocked')) OR
    NEW.state = OLD.state
)
BEGIN
    SELECT RAISE(ABORT, 'STAGE_TOMBSTONE_INVALID_TRANSITION');
END;

CREATE TRIGGER IF NOT EXISTS stage_tombstones_parent_state
BEFORE UPDATE OF state ON stage_tombstones
WHEN (NEW.state = 'completed' AND NOT EXISTS (
        SELECT 1 FROM stage_job_items
        WHERE job_id = NEW.job_id AND item_no = NEW.item_no AND state = 'completed'))
    OR (NEW.state = 'unknown' AND NOT EXISTS (
        SELECT 1 FROM stage_job_items
        WHERE job_id = NEW.job_id AND item_no = NEW.item_no AND state = 'unknown'))
    OR (NEW.state = 'blocked' AND NOT EXISTS (
        SELECT 1 FROM stage_job_items
        WHERE job_id = NEW.job_id AND item_no = NEW.item_no AND state = 'blocked'))
BEGIN
    SELECT RAISE(ABORT, 'STAGE_TOMBSTONE_PARENT_STATE_INVALID');
END;

CREATE TRIGGER IF NOT EXISTS stage_cpms_leases_valid_transition
BEFORE UPDATE ON stage_cpms_leases
WHEN NEW.lease_scope <> OLD.lease_scope
    OR NEW.lease_generation < OLD.lease_generation
    OR (OLD.state = 'active' AND NEW.state = 'active'
        AND (NEW.owner_id <> OLD.owner_id
            OR NEW.owner_nonce_digest <> OLD.owner_nonce_digest
            OR NEW.lease_generation <> OLD.lease_generation))
    OR (OLD.state = 'active' AND NEW.state IN ('released', 'lost')
        AND (NEW.owner_id <> OLD.owner_id
            OR NEW.owner_nonce_digest <> OLD.owner_nonce_digest
            OR NEW.storage IS NOT OLD.storage
            OR NEW.lease_generation <> OLD.lease_generation))
    OR (OLD.state IN ('released', 'lost') AND NEW.state IN ('released', 'lost')
        AND (NEW.state <> OLD.state
            OR NEW.owner_id <> OLD.owner_id
            OR NEW.owner_nonce_digest <> OLD.owner_nonce_digest
            OR NEW.storage IS NOT OLD.storage
            OR NEW.lease_generation <> OLD.lease_generation
            OR NEW.acquired_at <> OLD.acquired_at
            OR NEW.renewed_at <> OLD.renewed_at
            OR NEW.expires_at <> OLD.expires_at))
    OR (OLD.state IN ('released', 'lost') AND NEW.state = 'active'
        AND NEW.lease_generation <= OLD.lease_generation)
    OR NEW.state NOT IN ('active', 'released', 'lost')
BEGIN
    SELECT RAISE(ABORT, 'CPMS_LEASE_INVALID_TRANSITION');
END;

CREATE TRIGGER IF NOT EXISTS stage_cpms_leases_insert_gate
BEFORE INSERT ON stage_cpms_leases
WHEN NEW.lease_scope <> 'global'
    OR NEW.state <> 'active'
    OR NEW.lease_generation <> 1
BEGIN
    SELECT RAISE(ABORT, 'CPMS_LEASE_INITIAL_STATE_INVALID');
END;

CREATE TRIGGER IF NOT EXISTS stage_cpms_leases_immutable
BEFORE DELETE ON stage_cpms_leases
BEGIN
    SELECT RAISE(ABORT, 'CPMS_LEASE_IMMUTABLE');
END;

CREATE TRIGGER IF NOT EXISTS stage_tombstones_immutable
BEFORE DELETE ON stage_tombstones
BEGIN
    SELECT RAISE(ABORT, 'TOMBSTONE_IMMUTABLE');
END;
