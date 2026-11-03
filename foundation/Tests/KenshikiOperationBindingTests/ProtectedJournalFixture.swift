import CryptoKit
import Foundation
@_spi(StorageAdapter) import KenshikiOperationBinding
@_spi(StorageTestFixture) import KenshikiProtectedStorage

/// Real SQLCipher with an explicitly synthetic key; never selected by production initializers.
func journalFixture(url: URL, namespace: String,
    retentionPolicy: JournalRetentionPolicy = .ordinary,
    legacyNamespacePolicy: JournalRetentionPolicy? = nil,
    now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }) throws -> OperationJournal {
    let store = try journalStoreFixture(url: url)
    return try OperationJournal(store: store, namespace: namespace, retentionPolicy: retentionPolicy,
        legacyNamespacePolicy: legacyNamespacePolicy, now: now)
}

func journalStoreFixture(url: URL) throws -> ProtectedSQLiteStore {
    let url = url.deletingLastPathComponent().lastPathComponent == url.lastPathComponent + "-protected"
        ? url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(url.lastPathComponent)
        : url
    let destination = url.deletingLastPathComponent()
        .appendingPathComponent(url.lastPathComponent + "-protected", isDirectory: true)
        .appendingPathComponent(url.lastPathComponent)
    let identity = try StoreKeyIdentity(applicationID: "synthetic.operation-journal", storeID: "journal",
        purpose: "tests-only", keychainAccessGroup: "TEST.synthetic.operation-journal",
        accessPolicy: .backgroundAfterFirstUnlock)
    let store = try ProtectedSQLiteStore.testing(databaseURL: destination, identity: identity,
        key: Data(SHA256.hash(data: Data(url.path.utf8))),
        legacyPlaintextURL: FileManager.default.fileExists(atPath: url.path) ? url : nil)
    try store.finishLegacyCutover()
    return store
}
