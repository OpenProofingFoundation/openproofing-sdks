import Foundation
import KenshikiProtectedStorage
import SQLCipher

/// Immutable schema history for this dedicated store. Version zero is an empty database;
/// it never means guess the format. Future or inconsistent versions are preserved and refused.
enum PassportCaptureSchema {
    static let currentVersion = 4
    static let historySQL = "CREATE TABLE passport_schema_migrations( version INTEGER PRIMARY KEY NOT NULL CHECK(version > 0), migration_sha256 TEXT NOT NULL CHECK(length(migration_sha256) = 64), applied_at_ms INTEGER NOT NULL CHECK(applied_at_ms > 0) ) STRICT"
    static let captureSQL = "CREATE TABLE passport_checkpoint( slot INTEGER PRIMARY KEY NOT NULL CHECK(slot = 1), capture_id TEXT UNIQUE NOT NULL CHECK(length(capture_id) = 36), captured_at_ms INTEGER NOT NULL CHECK(captured_at_ms > 0), verification_scope TEXT NOT NULL CHECK(verification_scope = 'local_nfc'), payload_version INTEGER NOT NULL CHECK(payload_version = 1), payload_sha256 TEXT NOT NULL CHECK(length(payload_sha256) = 64), portrait_sha256 TEXT NOT NULL CHECK(length(portrait_sha256) = 64), sod_sha256 TEXT NOT NULL CHECK(length(sod_sha256) = 64), payload BLOB NOT NULL CHECK(length(payload) > 0 AND length(payload) <= 20971520) ) STRICT"
    static var migrationDigest: String {
        SavedPassportCapture.digest(Data((historySQL + "\n" + captureSQL).utf8))
    }
    static let faceSQL = "CREATE TABLE face_capture( operation_id TEXT PRIMARY KEY NOT NULL CHECK(length(operation_id)=36), workflow_id TEXT CHECK(workflow_id IS NULL OR length(workflow_id)=36), recorded_at_ms INTEGER NOT NULL CHECK(recorded_at_ms>0), reference_sha256 TEXT NOT NULL CHECK(length(reference_sha256)=64), selfie_sha256 TEXT NOT NULL CHECK(length(selfie_sha256)=64), payload_sha256 TEXT NOT NULL CHECK(length(payload_sha256)=64), payload BLOB NOT NULL CHECK(length(payload)>0 AND length(payload)<=41943040) ) STRICT"
    static let stageSQL = "CREATE TABLE face_stage( stage_id TEXT PRIMARY KEY NOT NULL CHECK(length(stage_id)=36), operation_id TEXT NOT NULL REFERENCES face_capture(operation_id), engine TEXT NOT NULL CHECK(engine IN ('aura','liquid')), sequence INTEGER NOT NULL CHECK(sequence>0), recorded_at_ms INTEGER NOT NULL CHECK(recorded_at_ms>0), preceding_aura_id TEXT REFERENCES face_stage(stage_id), payload_sha256 TEXT NOT NULL CHECK(length(payload_sha256)=64), payload BLOB NOT NULL CHECK(length(payload)>0 AND length(payload)<=1048576), UNIQUE(operation_id,engine,sequence) ) STRICT"
    static let eventSQL = "CREATE TABLE workflow_event( event_id TEXT PRIMARY KEY NOT NULL CHECK(length(event_id)=36), workflow_id TEXT NOT NULL CHECK(length(workflow_id)=36), sequence INTEGER NOT NULL CHECK(sequence>0), occurred_at_ms INTEGER NOT NULL CHECK(occurred_at_ms>0), action TEXT NOT NULL CHECK(length(action)>0 AND length(action)<=128), payload_sha256 TEXT NOT NULL CHECK(length(payload_sha256)=64), payload BLOB NOT NULL CHECK(length(payload)>0 AND length(payload)<=262144), UNIQUE(workflow_id,sequence) ) STRICT"
    static var workflowMigrationDigest: String {
        SavedPassportCapture.digest(Data(([faceSQL, stageSQL, eventSQL].joined(separator: "\n")).utf8))
    }

    static let passSQL = "CREATE TABLE liquid_pass_event( event_id TEXT PRIMARY KEY NOT NULL CHECK(length(event_id)=36), attempt_id TEXT NOT NULL CHECK(length(attempt_id)=36), operation_id TEXT NOT NULL REFERENCES face_capture(operation_id), aura_id TEXT NOT NULL REFERENCES face_stage(stage_id), pass TEXT NOT NULL CHECK(pass IN ('quality','comparison','presentation')), status TEXT NOT NULL CHECK(status IN ('pending','completed','failed')), recorded_at_ms INTEGER NOT NULL CHECK(recorded_at_ms>0), payload_sha256 TEXT NOT NULL CHECK(length(payload_sha256)=64), payload BLOB NOT NULL CHECK(length(payload)>0 AND length(payload)<=65536), UNIQUE(attempt_id,status) ) STRICT"
    static let passIndexSQL = "CREATE INDEX liquid_pass_operation ON liquid_pass_event(operation_id)"
    static var passMigrationDigest: String { SavedPassportCapture.digest(Data((passSQL + "\n" + passIndexSQL).utf8)) }

    // v1-v3 SQL and digests above are immutable installed history.
    static let passV4SQL = passSQL.replacingOccurrences(of: "CREATE TABLE liquid_pass_event(", with: "CREATE TABLE liquid_pass_event_v4(")
        .replacingOccurrences(of: "'quality','comparison','presentation'", with: "'quality','comparison','age','presentation','sensor_consistency'")
    static let snapshotSQL = "CREATE TABLE comparison_snapshot( operation_id TEXT PRIMARY KEY NOT NULL REFERENCES face_capture(operation_id), payload_sha256 TEXT NOT NULL CHECK(length(payload_sha256)=64), payload BLOB NOT NULL CHECK(length(payload)>0 AND length(payload)<=9437184) ) STRICT"
    static let v4Statements = [passV4SQL,
        "INSERT INTO liquid_pass_event_v4 SELECT * FROM liquid_pass_event ORDER BY rowid",
        "DROP TABLE liquid_pass_event", "ALTER TABLE liquid_pass_event_v4 RENAME TO liquid_pass_event", passIndexSQL, snapshotSQL]
    static var snapshotMigrationDigest: String { SavedPassportCapture.digest(Data(v4Statements.joined(separator: "\n").utf8)) }
    static var installedPassV4SQL: String {
        passV4SQL.replacingOccurrences(of: "CREATE TABLE liquid_pass_event_v4(", with: "CREATE TABLE \"liquid_pass_event\"(")
    }

    static func prepare(_ db: OpaquePointer) throws {
        let version = try integer(db, "PRAGMA user_version")
        guard version <= currentVersion else { throw PassportCaptureStorageFailure.unsupportedVersion }
        if version < currentVersion {
            try execute(db, "BEGIN IMMEDIATE")
            do {
                // Another owner may have completed initialization while this handle waited.
                if try integer(db, "PRAGMA user_version") == 0 {
                    guard try integer(db, "SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT GLOB '_kenshiki_*' AND name NOT GLOB 'sqlite_*'") == 0 else {
                        throw PassportCaptureStorageFailure.invalidCapture
                    }
                    try execute(db, historySQL)
                    try execute(db, captureSQL)
                    try recordMigration(db, version: 1, digest: migrationDigest)
                    try execute(db, "PRAGMA user_version=1")
                }
                if try integer(db, "PRAGMA user_version") == 1 {
                    try validate(db, version: 1)
                    try execute(db, faceSQL)
                    try execute(db, stageSQL)
                    try execute(db, eventSQL)
                    try recordMigration(db, version: 2, digest: workflowMigrationDigest)
                    try execute(db, "PRAGMA user_version=2")
                }
                if try integer(db, "PRAGMA user_version") == 2 {
                    try validate(db, version: 2)
                    try execute(db, passSQL)
                    try execute(db, passIndexSQL)
                    try recordMigration(db, version: 3, digest: passMigrationDigest)
                    try execute(db, "PRAGMA user_version=3")
                }
                if try integer(db, "PRAGMA user_version") == 3 {
                    try validate(db, version: 3)
                    for sql in v4Statements.prefix(2) { try execute(db, sql) }
                    // Bidirectional byte comparison detects dropped or changed records before old storage is removed.
                    guard try integer(db, "SELECT count(*) FROM (SELECT * FROM liquid_pass_event EXCEPT SELECT * FROM liquid_pass_event_v4)") == 0,
                          try integer(db, "SELECT count(*) FROM (SELECT * FROM liquid_pass_event_v4 EXCEPT SELECT * FROM liquid_pass_event)") == 0 else {
                        throw PassportCaptureStorageFailure.invalidCapture
                    }
                    for sql in v4Statements.dropFirst(2) { try execute(db, sql) }
                    try recordMigration(db, version: 4, digest: snapshotMigrationDigest)
                    try execute(db, "PRAGMA user_version=4")
                }
                try validate(db)
                try execute(db, "COMMIT")
            } catch {
                try? execute(db, "ROLLBACK")
                throw error
            }
        } else {
            try validate(db)
        }
    }

    private static func validate(_ db: OpaquePointer, version: Int = currentVersion) throws {
        guard try integer(db, "PRAGMA user_version") == version,
              try integer(db, "SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT GLOB '_kenshiki_*' AND name NOT GLOB 'sqlite_*'") == (version == 1 ? 2 : (version == 2 ? 5 : (version == 3 ? 6 : 7))),
              try integer(db, "SELECT count(*) FROM passport_schema_migrations") == version,
              try string(db, "SELECT migration_sha256 FROM passport_schema_migrations WHERE version=1") == migrationDigest,
              try string(db, "SELECT sql FROM sqlite_master WHERE type='table' AND name='passport_checkpoint'") == captureSQL,
              try string(db, "SELECT sql FROM sqlite_master WHERE type='table' AND name='passport_schema_migrations'") == historySQL else {
            throw PassportCaptureStorageFailure.invalidCapture
        }
        if version >= 2 {
            guard try string(db, "SELECT migration_sha256 FROM passport_schema_migrations WHERE version=2") == workflowMigrationDigest,
                  try string(db, "SELECT sql FROM sqlite_master WHERE name='face_capture'") == faceSQL,
                  try string(db, "SELECT sql FROM sqlite_master WHERE name='face_stage'") == stageSQL,
                  try string(db, "SELECT sql FROM sqlite_master WHERE name='workflow_event'") == eventSQL else {
                throw PassportCaptureStorageFailure.invalidCapture
            }
        }
        if version >= 3 {
            guard try string(db, "SELECT migration_sha256 FROM passport_schema_migrations WHERE version=3") == passMigrationDigest,
                  try string(db, "SELECT sql FROM sqlite_master WHERE name='liquid_pass_event'") == (version == 3 ? passSQL : installedPassV4SQL),
                  try string(db, "SELECT sql FROM sqlite_master WHERE name='liquid_pass_operation'") == passIndexSQL else {
                throw PassportCaptureStorageFailure.invalidCapture
            }
        }
        if version >= 4 {
            guard try string(db, "SELECT migration_sha256 FROM passport_schema_migrations WHERE version=4") == snapshotMigrationDigest,
                  try string(db, "SELECT sql FROM sqlite_master WHERE name='comparison_snapshot'") == snapshotSQL else {
                throw PassportCaptureStorageFailure.invalidCapture
            }
        }
    }

    private static func recordMigration(_ db: OpaquePointer, version: Int32, digest: String) throws {
        let query = try statement(db, "INSERT INTO passport_schema_migrations VALUES(?, ?, ?)")
        defer { sqlite3_finalize(query) }
        try check(sqlite3_bind_int(query, 1, version))
        try bind(digest, at: 2, to: query)
        try check(sqlite3_bind_int64(query, 3, Int64(Date().timeIntervalSince1970 * 1000)))
        try done(query)
    }

    static func statement(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var prepared: OpaquePointer?
        let status = sqlite3_prepare_v2(db, sql, -1, &prepared, nil)
        guard status == SQLITE_OK, let prepared else {
            if let prepared { sqlite3_finalize(prepared) }
            throw ProtectedSQLiteError.unavailable(status)
        }
        return prepared
    }

    static func execute(_ db: OpaquePointer, _ sql: String) throws {
        try check(sqlite3_exec(db, sql, nil, nil, nil))
    }

    static func bind(_ value: String, at index: Int32, to statement: OpaquePointer) throws {
        try check(sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)))
    }

    static func check(_ status: Int32) throws {
        guard status == SQLITE_OK else { throw ProtectedSQLiteError.unavailable(status) }
    }

    static func done(_ statement: OpaquePointer) throws {
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE else { throw ProtectedSQLiteError.unavailable(status) }
    }

    static func string(_ db: OpaquePointer, _ sql: String) throws -> String? {
        let query = try statement(db, sql)
        defer { sqlite3_finalize(query) }
        let status = sqlite3_step(query)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw ProtectedSQLiteError.unavailable(status) }
        guard let value = sqlite3_column_text(query, 0) else { return nil }
        return String(cString: value)
    }

    static func integer(_ db: OpaquePointer, _ sql: String) throws -> Int {
        guard let value = try string(db, sql), let integer = Int(value) else {
            throw PassportCaptureStorageFailure.invalidCapture
        }
        return integer
    }
}
