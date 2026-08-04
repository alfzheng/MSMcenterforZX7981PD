PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS metadata (
    key TEXT NOT NULL PRIMARY KEY,
    value TEXT NOT NULL
);

INSERT OR IGNORE INTO metadata(key, value) VALUES
    ('schema_version', '1'),
    ('snapshot_version', '0'),
    ('recovery_incomplete', '0'),
    ('last_integrity_check_at', '0'),
    ('last_backup_manifest_sha256', '');

CREATE TABLE IF NOT EXISTS messages (
    archive_id TEXT NOT NULL PRIMARY KEY,
    source_identity_digest TEXT NOT NULL,
    content_digest TEXT NOT NULL,
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
    raw_pdu BLOB NOT NULL,
    raw_pdu_sha256 TEXT NOT NULL,
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
