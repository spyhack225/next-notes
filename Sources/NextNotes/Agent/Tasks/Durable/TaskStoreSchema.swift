import Foundation
import SQLite3

enum TaskStoreSchema {
    static let version: Int64 = 2

    /// P6-02a retains current AgentTask fields. Future projections are explicit empty/
    /// zero/nil defaults, not invented instructions, authority or delivery receipts.
    static let sql = """
        CREATE TABLE task (
          id TEXT PRIMARY KEY,
          state TEXT NOT NULL,
          origin TEXT NOT NULL DEFAULT '',
          source TEXT NOT NULL,
          backend TEXT NOT NULL,
          title TEXT NOT NULL DEFAULT '',
          objective TEXT NOT NULL,
          progress TEXT NOT NULL,
          context_references TEXT NOT NULL,
          tool TEXT,
          arguments TEXT NOT NULL,
          meeting_id TEXT,
          acp_cli TEXT NOT NULL,
          compatibility_command TEXT,
          compatibility_cli TEXT,
          compatibility_directory TEXT,
          schedule_id TEXT,
          sort_order INTEGER NOT NULL,
          user_words TEXT NOT NULL DEFAULT '',
          revision INTEGER NOT NULL DEFAULT 0,
          created_at REAL NOT NULL,
          started_at INTEGER,
          finished_at INTEGER,
          result TEXT,
          failure TEXT,
          question TEXT,
          pending_request_id TEXT,
          delivery TEXT NOT NULL DEFAULT '',
          delivery_attempts INTEGER NOT NULL DEFAULT 0,
          durability TEXT
        );
        CREATE INDEX task_state ON task(state);
        CREATE INDEX task_created ON task(created_at DESC);
        CREATE TABLE task_event (
          seq INTEGER PRIMARY KEY AUTOINCREMENT,
          task_id TEXT NOT NULL REFERENCES task(id) ON DELETE CASCADE,
          at INTEGER NOT NULL,
          kind TEXT NOT NULL,
          detail TEXT,
          attempt INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX task_event_task ON task_event(task_id, seq);
        CREATE TABLE task_artifact (
          task_id TEXT NOT NULL REFERENCES task(id) ON DELETE CASCADE,
          path TEXT NOT NULL,
          ordinal INTEGER NOT NULL,
          added_at INTEGER NOT NULL,
          kind TEXT NOT NULL DEFAULT 'link',
          title TEXT,
          PRIMARY KEY (task_id, ordinal)
        );
        CREATE TABLE task_dependency (
          upstream TEXT NOT NULL REFERENCES task(id) ON DELETE CASCADE,
          downstream TEXT NOT NULL REFERENCES task(id) ON DELETE CASCADE,
          requirement TEXT NOT NULL,
          PRIMARY KEY (upstream, downstream)
        );
        """

    static func install(on db: OpaquePointer) throws {
        let current = try TaskStore.integer(db, "PRAGMA user_version")
        guard current == 0 || current == 1 || current == version else { throw TaskStoreError.unsupportedVersion(current) }
        if current == 0 {
            try TaskStore.transaction(db) {
                try TaskStore.exec(db, sql)
                try TaskStore.exec(db, authoritySQL)
                try TaskStore.exec(db, "PRAGMA user_version = \(version)")
            }
        }
        try validateKnown(on: db)
    }

    static let authoritySQL = """
        CREATE TABLE task_authority (
          singleton INTEGER PRIMARY KEY CHECK(singleton=1),
          database_id TEXT NOT NULL,
          generation INTEGER NOT NULL CHECK(generation>0)
        );
        """

    /// Called only inside the import transaction, after strict payload/conflict preflight.
    static func installAuthority(on db: OpaquePointer) throws {
        if try TaskStore.integer(db, "PRAGMA user_version") == 1 {
            try TaskStore.exec(db, authoritySQL)
            try TaskStore.exec(db, "PRAGMA user_version = 2")
        }
        try validateKnown(on: db)
    }

    /// Read-only validation never installs tables, changes WAL or upgrades the version.
    static func validateKnown(on db: OpaquePointer) throws {
        let version = try TaskStore.integer(db, "PRAGMA user_version")
        guard version == 1 || version == Self.version else { throw TaskStoreError.unsupportedVersion(version) }
        if version == 2 {
            let statement = try TaskStore.prepare(db, "SELECT singleton,database_id,generation FROM task_authority LIMIT 0")
            sqlite3_finalize(statement)
        }
        // A known version with missing columns/tables is an error, not permission to erase it.
        let probe = try TaskStore.prepare(db, "SELECT \(TaskStore.columns) FROM task LIMIT 0")
        sqlite3_finalize(probe)
        for query in [
            "SELECT origin,title,user_words,revision,started_at,finished_at,question,pending_request_id,delivery,delivery_attempts FROM task LIMIT 0",
            "SELECT seq,task_id,at,kind,detail,attempt FROM task_event LIMIT 0",
            "SELECT task_id,path,ordinal,added_at,kind,title FROM task_artifact LIMIT 0",
            "SELECT upstream,downstream,requirement FROM task_dependency LIMIT 0"
        ] {
            let statement = try TaskStore.prepare(db, query)
            sqlite3_finalize(statement)
        }
        for (name, columns) in ["task_state": ["state"], "task_created": ["created_at"],
                                 "task_event_task": ["task_id", "seq"]] {
            guard try TaskStore.stringColumn(db, "PRAGMA index_info(\(name))", column: 2) == columns else {
                throw TaskStoreError.invalidRecord
            }
        }
        for (table, expected) in ["task_artifact": ["task_id"], "task_event": ["task_id"],
                                  "task_dependency": ["upstream", "downstream"]] {
            let statement = try TaskStore.prepare(db, "PRAGMA foreign_key_list(\(table))")
            defer { sqlite3_finalize(statement) }
            var found: Set<String> = []
            var code = sqlite3_step(statement)
            while code == SQLITE_ROW {
                guard try TaskStore.text(statement, 2) == "task", try TaskStore.text(statement, 4) == "id",
                      try TaskStore.text(statement, 6) == "CASCADE", let from = try TaskStore.text(statement, 3) else {
                    throw TaskStoreError.invalidRecord
                }
                found.insert(from)
                code = sqlite3_step(statement)
            }
            guard code == SQLITE_DONE, found == Set(expected) else { throw TaskStoreError.invalidRecord }
        }
        var primaryShapes = ["task": ["id"], "task_event": ["seq"],
            "task_artifact": ["task_id", "ordinal"], "task_dependency": ["upstream", "downstream"]]
        if version == 2 { primaryShapes["task_authority"] = ["singleton"] }
        for (table, expected) in primaryShapes {
            let statement = try TaskStore.prepare(db, "PRAGMA table_info(\(table))")
            defer { sqlite3_finalize(statement) }
            var primary: [Int: String] = [:]
            var code = sqlite3_step(statement)
            while code == SQLITE_ROW {
                let position = Int(sqlite3_column_int(statement, 5))
                if position > 0, let name = try TaskStore.text(statement, 1) { primary[position] = name }
                code = sqlite3_step(statement)
            }
            guard code == SQLITE_DONE, primary.keys.sorted().compactMap({ primary[$0] }) == expected else { throw TaskStoreError.invalidRecord }
        }
    }
}
