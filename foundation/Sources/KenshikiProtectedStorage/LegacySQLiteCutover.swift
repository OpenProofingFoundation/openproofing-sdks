import CryptoKit
import Foundation
import SQLCipher
import KenshikiSQLCipherBridge

extension ProtectedSQLiteStore {
    /// Finish an explicitly configured legacy migration during the adopter's exclusive startup.
    /// Changed input or an active writer is a conflict, never permission to discard newer evidence.
    /// A durable encrypted cleanup plan allows an interrupted deletion to resume safely.
    public func finishLegacyCutover() throws {
        try withFoundationConnection { db in try LegacySQLiteCutover.finish(db: db, destination: databaseURL) }
    }
}

enum LegacySQLiteCutover {
    private struct FilePlan: Codable {
        let suffix: String
        let inode: UInt64
        let digest: String?
    }
    private static let table = "_kenshiki_legacy_cutover"

    static func commitment(_ source: URL) throws -> String {
        var hash = SHA256()
        for suffix in ["", "-wal", "-journal"] {
            let file = URL(fileURLWithPath: source.path + suffix)
            hash.update(data: Data(suffix.utf8))
            if FileManager.default.fileExists(atPath: file.path) {
                hash.update(data: Data([1]))
                hash.update(data: Data(try digest(file).utf8))
            } else { hash.update(data: Data([0])) }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func record(db: OpaquePointer, source: URL, commitment: String) throws {
        try ProtectedSQLiteStore.execute(db, "CREATE TABLE \(table)(singleton INTEGER PRIMARY KEY CHECK(singleton=1),source TEXT NOT NULL,commitment TEXT NOT NULL,plan TEXT,state INTEGER NOT NULL CHECK(state IN(0,1,2)));")
        try ProtectedSQLiteStore.bindAndRun(db,
            "INSERT INTO \(table)(singleton,source,commitment,state) VALUES(1,?,?,0)",
            values: [.text(source.path), .text(commitment)])
    }

    static func finish(db: OpaquePointer, destination: URL, afterIntent: () throws -> Void = {}) throws {
        guard try ProtectedSQLiteStore.scalar(db, "SELECT name FROM sqlite_master WHERE type='table' AND name='\(table)'") != nil else { return }
        guard let state = try ProtectedSQLiteStore.scalar(db, "SELECT state FROM \(table) WHERE singleton=1"),
            let path = try ProtectedSQLiteStore.scalar(db, "SELECT source FROM \(table) WHERE singleton=1") else {
            throw ProtectedSQLiteError.migrationConflict
        }
        if state == "2" { return }
        let source = URL(fileURLWithPath: path)
        guard source != destination, source == source.resolvingSymlinksInPath().standardizedFileURL else {
            throw ProtectedSQLiteError.migrationConflict
        }
        if state == "1" {
            let plan = try loadPlan(db)
            try withSourceWriteExclusion(source) { try remove(plan, source: source) }
        } else if state == "0" {
            // READWRITE without CREATE: missing input cannot become an empty replacement database.
            var pointer: OpaquePointer?
            let status = sqlite3_open_v2(path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
            guard status == SQLITE_OK, let pointer else {
                if let pointer { sqlite3_close_v2(pointer) }
                throw ProtectedSQLiteError.migrationConflict
            }
            defer { sqlite3_close_v2(pointer) }
            guard kenshiki_sqlcipher_preserve_wal_on_close(UnsafeMutableRawPointer(pointer)) == SQLITE_OK else {
                throw ProtectedSQLiteError.migrationConflict
            }
            // Fail immediately if a writer is active, and hold the writer exclusion until removal.
            try ProtectedSQLiteStore.execute(pointer, "BEGIN IMMEDIATE;")
            guard let expected = try ProtectedSQLiteStore.scalar(db, "SELECT commitment FROM \(table) WHERE singleton=1"),
                try commitment(source) == expected else { throw ProtectedSQLiteError.migrationConflict }
            let plan = try makePlan(source)
            let encoded = try JSONEncoder().encode(plan)
            guard let text = String(data: encoded, encoding: .utf8) else { throw ProtectedSQLiteError.migrationConflict }
            try ProtectedSQLiteStore.bindAndRun(db,
                "UPDATE \(table) SET state=1,plan=? WHERE singleton=1 AND state=0", values: [.text(text)])
            // FULL synchronous WAL commit makes this exact deletion plan durable before file removal.
            guard sqlite3_get_autocommit(db) != 0 else { throw ProtectedSQLiteError.migrationConflict }
            try afterIntent()
            try remove(plan, source: source)
        } else { throw ProtectedSQLiteError.migrationConflict }
        try ProtectedSQLiteStore.execute(db, "UPDATE \(table) SET state=2,plan=NULL WHERE singleton=1 AND state=1")
    }

    private static func withSourceWriteExclusion<T>(_ source: URL, _ body: () throws -> T) throws -> T {
        // If the prior deletion already removed the main file, never recreate it to obtain a lock.
        guard FileManager.default.fileExists(atPath: source.path) else { return try body() }
        var pointer: OpaquePointer?
        let status = sqlite3_open_v2(source.path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let pointer else {
            if let pointer { sqlite3_close_v2(pointer) }
            throw ProtectedSQLiteError.migrationConflict
        }
        defer { sqlite3_close_v2(pointer) }
        guard kenshiki_sqlcipher_preserve_wal_on_close(UnsafeMutableRawPointer(pointer)) == SQLITE_OK else {
            throw ProtectedSQLiteError.migrationConflict
        }
        try ProtectedSQLiteStore.execute(pointer, "BEGIN IMMEDIATE;")
        return try body()
    }

    private static func loadPlan(_ db: OpaquePointer) throws -> [FilePlan] {
        guard let text = try ProtectedSQLiteStore.scalar(db, "SELECT plan FROM \(table) WHERE singleton=1"),
            let data = text.data(using: .utf8), data.count <= 8192,
            let plan = try? JSONDecoder().decode([FilePlan].self, from: data), !plan.isEmpty,
            plan.count <= 4, Set(plan.map(\.suffix)).count == plan.count,
            plan.allSatisfy({ ["", "-wal", "-shm", "-journal"].contains($0.suffix) }) else {
            throw ProtectedSQLiteError.migrationConflict
        }
        return plan
    }

    private static func makePlan(_ source: URL) throws -> [FilePlan] {
        try ["", "-wal", "-shm", "-journal"].compactMap { suffix in
            let file = URL(fileURLWithPath: source.path + suffix)
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard let inode = attributes[.systemFileNumber] as? NSNumber,
                attributes[.type] as? FileAttributeType == .typeRegular else {
                throw ProtectedSQLiteError.migrationConflict
            }
            return FilePlan(suffix: suffix, inode: inode.uint64Value,
                digest: suffix == "-shm" ? nil : try digest(file))
        }
    }

    private static func remove(_ plan: [FilePlan], source: URL) throws {
        // Validate ALL remaining files before the first deletion. A writer's replacement file is
        // preserved even when an earlier attempt already removed another member of the family.
        for item in plan {
            let file = URL(fileURLWithPath: source.path + item.suffix)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard let inode = attributes[.systemFileNumber] as? NSNumber,
                inode.uint64Value == item.inode,
                attributes[.type] as? FileAttributeType == .typeRegular,
                try (item.digest == nil || digest(file) == item.digest) else {
                throw ProtectedSQLiteError.migrationConflict
            }
        }
        let expected = Set(plan.map(\.suffix))
        for suffix in ["", "-wal", "-shm", "-journal"] where !expected.contains(suffix) {
            guard !FileManager.default.fileExists(atPath: source.path + suffix) else {
                throw ProtectedSQLiteError.migrationConflict
            }
        }
        for item in plan {
            let file = URL(fileURLWithPath: source.path + item.suffix)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
        try StoreLifecycleFence.synchronizeDirectory(source.deletingLastPathComponent())
    }

    private static func digest(_ url: URL) throws -> String {
        guard url == url.resolvingSymlinksInPath().standardizedFileURL else { throw ProtectedSQLiteError.migrationConflict }
        let reader = try FileHandle(forReadingFrom: url)
        do {
            var hash = SHA256()
            while let block = try reader.read(upToCount: 65_536), !block.isEmpty { hash.update(data: block) }
            try reader.close()
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        } catch { try reader.close(); throw error }
    }
}
