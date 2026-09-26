-- schema.sql — the fixture subset of Apple's ~/Library/Messages/chat.db.
--
-- This is a FIXTURE, not a copy. Every column here is one the roadmap's
-- 01-PHASE-0-SELF-FLOW.md §2.2 names, plus the small number of extra columns
-- IM-04's MessagesCapabilities probes need to have something to probe. Nothing
-- is modelled that a query in MessagesQueries would plausibly read.
--
-- Deliberately absent: every FTS table, every index except the implicit UNIQUE
-- ones, every trigger, and every column not on the list above. A fixture that
-- carried the real database's 200 columns would be a second thing to keep
-- correct and would assert nothing.
--
-- A line ending in `--optional:<name>` is removed in `--degraded` mode, and a
-- line ending in `--optional-audio:<name>` is removed in `--no-audio` mode. That
-- marker is the whole of the removal mechanism: the marker shares the line
-- with the column, so the removal is an exact string match and the full schema
-- and the removed schema cannot drift apart. Exactly three columns carry a
-- marker, one per mode.
--
-- `--degraded` removes two: `attributedBody` and `payload_data`, the two
-- IM-05's decoder needs to know about and the two that decide whether text can
-- be decoded at all. `--no-audio` removes one: `is_audio_message`, and it
-- exists for a reason the other two do not have a reason for. Those two ask
-- "can this Mac read the body of a message"; this one asks "can this Mac tell a
-- voice note from a body it failed to read", and a row is a *different kind of
-- object* when the answer is no — so the absence has to be testable against a
-- database that really does not have the column, rather than against a
-- database that has it and left it NULL. `voice-note-unlabelled --no-audio` is
-- that database, and it is the only case that mode is for.
--
-- No other column may carry either marker: every other column, including
-- `balloon_bundle_id`, `is_sent`, `error` and `handle.uncanonicalized_id`,
-- exists in both modes, because a removed-column fixture is supposed to be
-- this database with one or two columns missing, not a smaller database.

PRAGMA page_size = 4096;
PRAGMA user_version = 1;

-- ---------------------------------------------------------------- handle ---

CREATE TABLE handle (
    ROWID               INTEGER PRIMARY KEY,
    id                  TEXT NOT NULL UNIQUE,
    country             TEXT,
    service             TEXT NOT NULL,
    uncanonicalized_id  TEXT,
    person_centric_id   TEXT
);

-- ------------------------------------------------------------------ chat ---

CREATE TABLE chat (
    ROWID            INTEGER PRIMARY KEY,
    guid             TEXT NOT NULL UNIQUE,
    chat_identifier  TEXT,
    service_name     TEXT,
    display_name     TEXT,
    style            INTEGER,
    state            INTEGER
);

-- --------------------------------------------------------------- message ---
--
-- ROWID is the watermark IM-06 advances, so every fixture pins it explicitly
-- rather than letting an implicit rowid allocation decide it.

CREATE TABLE message (
    ROWID                       INTEGER PRIMARY KEY,
    guid                        TEXT NOT NULL UNIQUE,
    text                        TEXT,
    attributedBody              BLOB, --optional:attributedBody
    version                     INTEGER DEFAULT 0,
    type                        INTEGER DEFAULT 0,
    service                     TEXT,
    handle_id                   INTEGER,
    account                     TEXT,
    account_guid                TEXT,
    destination_caller_id       TEXT,
    subject                     TEXT,
    date                        INTEGER,
    date_read                   INTEGER DEFAULT 0,
    date_delivered              INTEGER DEFAULT 0,
    is_delivered                INTEGER DEFAULT 0,
    is_finished                 INTEGER DEFAULT 0,
    is_from_me                  INTEGER DEFAULT 0,
    is_empty                    INTEGER DEFAULT 0,
    is_sent                     INTEGER DEFAULT 0,
    is_audio_message            INTEGER DEFAULT 0, --optional-audio:is_audio_message
    cache_has_attachments       INTEGER DEFAULT 0,
    balloon_bundle_id           TEXT,
    payload_data                BLOB, --optional:payload_data
    associated_message_guid     TEXT,
    associated_message_type     INTEGER,
    thread_originator_guid      TEXT,
    thread_originator_part      TEXT,
    date_edited                 INTEGER DEFAULT 0,
    is_retracted                INTEGER DEFAULT 0,
    error                       INTEGER DEFAULT 0,
    is_system_message           INTEGER DEFAULT 0
);

-- ------------------------------------------------------------- attachment ---

CREATE TABLE attachment (
    ROWID           INTEGER PRIMARY KEY,
    guid            TEXT NOT NULL UNIQUE,
    filename        TEXT,
    uti             TEXT,
    mime_type       TEXT,
    transfer_state  INTEGER DEFAULT 0,
    total_bytes     INTEGER,
    is_sticker      INTEGER DEFAULT 0,
    hide_attachment INTEGER DEFAULT 0
);

-- ------------------------------------------------------------------ joins ---
--
-- Real chat.db makes these INTEGER PRIMARY KEY rowid aliases over
-- (chat_rowid, message_rowid) / (message_rowid, attachment_rowid) /
-- (chat_rowid, handle_rowid). They are modelled with their own ROWIDs so a
-- fixture's join row count is directly assertable with
-- `SELECT count(*) FROM message_attachment_join` — which is the whole of
-- IM-06's settling-race fixture, and which a composite-key table would make
-- an assertion about a constraint instead.

CREATE TABLE chat_message_join (
    ROWID         INTEGER PRIMARY KEY,
    chat_rowid    INTEGER NOT NULL,
    message_rowid INTEGER NOT NULL
);

CREATE TABLE message_attachment_join (
    ROWID            INTEGER PRIMARY KEY,
    message_rowid    INTEGER NOT NULL,
    attachment_rowid INTEGER NOT NULL
);

CREATE TABLE chat_handle_join (
    ROWID        INTEGER PRIMARY KEY,
    chat_rowid   INTEGER NOT NULL,
    handle_rowid INTEGER NOT NULL
);
