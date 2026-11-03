import CryptoKit
import Foundation
import KenshikiEvidenceManifest

/// One immutable local artifact. The manifest identifies its role and source links.
public struct CaptureEvidenceRecord: Sendable {
  public let id: UUID
  public let original: Data
  public let manifest: Data
}

public enum CaptureEvidenceStoreError: Error, Equatable {
  case duplicate, invalidRecord, integrityFailure, outsideLiveLookupScope, custodyRevoked,
    custodyInUse
  /// Ciphertext is present but its Keychain key is gone. Records cannot be read; erase still works.
  case custodyKeyMissing
  /// V1/V2 records without a co-sealed signature remain historical evidence, never signed-only admission.
  case unsignedHistoricalRecord
  case signingNotConfigured
}

/// Native-host custody adapter, separate from document capture and identity policy.
/// Evidence payloads and manifests touch disk only in encrypted envelopes.
/// A record becomes visible by atomic rename.
public actor CaptureEvidenceStore {
  private struct Envelope: Codable {
    let version: Int
    let id: UUID
    let original: Data
    let manifest: Data
    let digest: String
  }

  private var revoked = false
  // A maintenance erase can reopen this actor. Suspended signatures retain the old admission.
  private var publicationGeneration = UUID()
  private let keyMissing: Bool
  private var revocationErasureCompleted = false
  private var custodyLease: CaptureCustodyLease?
  private let fileManager: FileManager
  private let directory: URL
  private let cipher: CaptureEvidenceCipher
  private let publicationSigning: CaptureSigningConfiguration?
  private var index: CaptureEvidenceIndex?
  private var indexDirty = false
  private var liveLookup: CaptureEvidenceLiveLookup?
  private(set) var metadataDirectoryScanCount = 0
  private(set) var authenticatedMetadataReadCount = 0
  // Internal diagnostic used to verify lookup work stays proportional to selected evidence.
  private(set) var authenticatedReadCount = 0

  // Raw construction is internal for storage codec tests. Adopters open CaptureCustodyRuntime,
  // which supplies the lease shared by every supported reference to this generation.
  init(directory: URL, key: SymmetricKey) throws {
    try self.init(directory: directory, key: key, custodyLease: nil)
  }

  /// `keyMissing` opens erase-only custody: every read and write refuses with
  /// `custodyKeyMissing`, while `revokeAndRemoveAll()` still deletes the files.
  init(
    directory: URL, key: SymmetricKey, custodyLease: CaptureCustodyLease?, keyMissing: Bool = false,
    signing: CaptureSigningConfiguration? = nil
  ) throws {
    try self.init(directory: directory, cipher: CaptureEvidenceCipher(key: key),
      custodyLease: custodyLease, keyMissing: keyMissing, signing: signing)
  }

  init(directory: URL, cipher: CaptureEvidenceCipher, custodyLease: CaptureCustodyLease?,
    keyMissing: Bool = false, signing: CaptureSigningConfiguration? = nil) throws
  {
    fileManager = FileManager.default
    self.keyMissing = keyMissing
    self.custodyLease = custodyLease
    self.directory = directory
    self.cipher = cipher
    self.publicationSigning = signing
    if try CaptureCustodyErasureState.pending(directory: directory, fileManager: fileManager) {
      // Erase-only reopening must not require directory creation or metadata writes.
      // Those may be exactly what failed while the durable intent remains readable.
      revoked = true
    } else {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      var excluded = directory
      var resources = URLResourceValues()
      resources.isExcludedFromBackup = true
      try excluded.setResourceValues(resources)
      revoked = try CaptureCustodyErasureState.prepare(directory: directory, fileManager: fileManager)
    }
    // Staging ciphertext is never discoverable as evidence. Opening another store
    // must not delete a publication currently being written by an existing actor.
    // Explicit removeAll owns cleanup after the host has stopped its writers.
  }

  public func requireSigningConfiguration() throws -> CaptureSigningConfiguration {
    try requireActiveCustody()
    guard let publicationSigning else { throw CaptureEvidenceStoreError.signingNotConfigured }
    return publicationSigning
  }

  public func store(id: UUID, original: Data, manifest: Data, expectedSHA256: String? = nil) throws
  {
    try publish(id: id, original: original, manifest: manifest, expectedSHA256: expectedSHA256,
      signedManifest: nil)
  }

  private func publish(id: UUID, original: Data, manifest: Data, expectedSHA256: String?,
    signedManifest: SignedCaptureEvidenceManifest?) throws
  {
    try requireActiveCustody()
    guard !original.isEmpty, !manifest.isEmpty else {
      throw CaptureEvidenceStoreError.invalidRecord
    }
    let destination = location(id)
    guard !fileManager.fileExists(atPath: destination.path) else {
      throw CaptureEvidenceStoreError.duplicate
    }
    let staging = directory.appendingPathComponent(UUID().uuidString + ".staging")
    defer { try? fileManager.removeItem(at: staging) }
    try CaptureEvidenceEnvelope.write(
      record: .init(id: id, original: original, manifest: manifest),
      cipher: cipher, to: staging,
      expectedSHA256: expectedSHA256, signedManifest: signedManifest)
    // Refuses an existing destination. Original and manifest are one envelope.
    try fileManager.moveItem(at: staging, to: destination)
    // Deliberate verification, not a cache: decrypts what reached disk and checks it against
    // the in-memory bytes. It is also where a declared `expectedSHA256` is checked against the
    // bytes, since the envelope seals a declared digest without re-hashing.
    do {
      let retained = try read(id: id)
      guard retained.original == original, retained.manifest == manifest else {
        throw CaptureEvidenceStoreError.integrityFailure
      }
    } catch {
      try? fileManager.removeItem(at: destination)
      throw error
    }
    liveLookup?.record(id: id, manifest: manifest)
    do {
      var cache =
        index ?? CaptureEvidenceIndex.load(directory: directory, cipher: cipher) ?? CaptureEvidenceIndex()
      cache.entries[id] = .init(
        manifest: manifest,
        fingerprint: try CaptureEvidenceIndex.Fingerprint(url: destination))
      index = cache
    } catch {
      // Cache observation failure cannot revoke successfully authenticated publication.
      index = nil
    }
    indexDirty = true
  }

  /// Signs before publication, then rechecks this custody generation after the await. Original,
  /// exact capability manifest and proof become visible in one encrypted atomic file publication.
  public func storeSigned(id: UUID, original: Data, manifest: Data,
    publication: CaptureEvidenceManifest, signing: CaptureSigningConfiguration) async throws {
    try requireActiveCustody()
    let admittedGeneration = publicationGeneration
    try publication.requireBinding(context: publication.context, recordID: id,
      payload: original, capabilityManifest: manifest)
    try await signing.requireScope(publication.context, workflowID: publication.context.workflowID,
      attemptID: publication.context.attemptID)
    let trustedKey = try await signing.signer.prepareSigningPublicKeyHash()
    let proof = try await signing.signer.sign(publication)
    let signed = SignedCaptureEvidenceManifest(manifest: publication, proof: proof)
    try await signed.verify(using: signing.signer, trustedSigningPublicKeyHash: trustedKey,
      expectedContext: publication.context, expectedRecordID: id,
      payload: original, capabilityManifest: manifest)
    try await signing.requireScope(publication.context, workflowID: publication.context.workflowID,
      attemptID: publication.context.attemptID)
    try requirePublicationGeneration(admittedGeneration)
    try Task.checkCancellation()
    try publish(id: id, original: original, manifest: manifest,
      expectedSHA256: publication.payloadSHA256, signedManifest: signed)
  }

  /// Strict admission never upgrades historical unsigned records or trusts a key carried in a proof.
  public func readSigned(id: UUID, workflowID: UUID, attemptID: UUID,
    signing: CaptureSigningConfiguration) async throws -> SignedCaptureEvidenceRecord {
    try requireActiveCustody()
    let admittedGeneration = publicationGeneration
    let handle = try FileHandle(forReadingFrom: location(id))
    let record: CaptureEvidenceRecord
    let signed: SignedCaptureEvidenceManifest
    do {
      guard let header = try CaptureEvidenceEnvelope.header(id: id, cipher: cipher, handle: handle),
        let retained = header.metadata.signedManifest
      else { throw CaptureEvidenceStoreError.unsignedHistoricalRecord }
      record = .init(id: id, original: try CaptureEvidenceEnvelope.payload(header, cipher: cipher, handle: handle),
        manifest: header.metadata.manifest)
      signed = retained
      try handle.close()
    } catch { try? handle.close(); throw error }
    try await signing.requireScope(signed.manifest.context, workflowID: workflowID, attemptID: attemptID)
    guard let trustedKey = try await signing.signer.existingSigningPublicKeyHash()
    else { throw EvidenceManifestError.untrustedSigningKey }
    try await signed.verify(using: signing.signer, trustedSigningPublicKeyHash: trustedKey,
      expectedContext: signed.manifest.context, expectedRecordID: id,
      payload: record.original, capabilityManifest: record.manifest)
    try await signing.requireScope(signed.manifest.context, workflowID: workflowID, attemptID: attemptID)
    try requirePublicationGeneration(admittedGeneration)
    try Task.checkCancellation()
    return .init(record: record, publication: signed)
  }

  /// Capacity observation for bounded local recording; unavailable remains explicit.
  public func availableCapacityForRecording() throws -> Int64? {
    try requireActiveCustody()
    return try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
      .volumeAvailableCapacityForImportantUsage
  }

  public func read(id: UUID) throws -> CaptureEvidenceRecord {
    try requireActiveCustody()
    authenticatedReadCount += 1
    let handle = try FileHandle(forReadingFrom: location(id))
    defer { try? handle.close() }
    if let header = try CaptureEvidenceEnvelope.header(id: id, cipher: cipher, handle: handle) {
      return CaptureEvidenceRecord(
        id: id,
        original: try CaptureEvidenceEnvelope.payload(header, cipher: cipher, handle: handle),
        manifest: header.metadata.manifest)
    }
    return try readLegacy(id: id)
  }

  /// Authenticates V2 routing metadata without reading image ciphertext. Legacy V1 must decode its envelope.
  public func metadata(id: UUID) throws -> Data {
    try requireActiveCustody()
    authenticatedMetadataReadCount += 1
    let handle = try FileHandle(forReadingFrom: location(id))
    defer { try? handle.close() }
    if let header = try CaptureEvidenceEnvelope.header(id: id, cipher: cipher, handle: handle) {
      return header.metadata.manifest
    }
    authenticatedReadCount += 1
    return try readLegacy(id: id).manifest
  }

  private func readLegacy(id: UUID) throws -> CaptureEvidenceRecord {
    let encoded = try Data(contentsOf: location(id))
    let plaintext = try cipher.open(encoded, binding(id))
    let envelope = try JSONDecoder().decode(Envelope.self, from: plaintext)
    guard envelope.version == 1, envelope.id == id,
      envelope.digest == CaptureEvidenceEnvelope.hash(envelope.original)
    else { throw CaptureEvidenceStoreError.integrityFailure }
    return CaptureEvidenceRecord(id: id, original: envelope.original, manifest: envelope.manifest)
  }

  /// One-time key cutover verifies original metadata AND payloads before retiring legacy custody.
  /// Unpublished staging files and the expendable index are never promoted to evidence here.
  static func verifyRetainedCiphertext(directory: URL, cipher: CaptureEvidenceCipher) throws {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: directory.path) else { return }
    for url in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    where ["evidence", "journey"].contains(url.pathExtension) {
      guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
        throw CaptureEvidenceStoreError.invalidRecord
      }
      if url.pathExtension == "journey" {
        _ = try CaptureCheckpointCodec.load(workflowID: id, directory: directory, cipher: cipher)
      } else {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        if let header = try CaptureEvidenceEnvelope.header(id: id, cipher: cipher, handle: handle) {
          _ = try CaptureEvidenceEnvelope.payload(header, cipher: cipher, handle: handle)
        } else {
          let plaintext = try cipher.open(Data(contentsOf: url),
            Data(("IdentityEvidenceStorage/v1/" + id.uuidString).utf8))
          let envelope = try JSONDecoder().decode(Envelope.self, from: plaintext)
          guard envelope.version == 1, envelope.id == id,
            envelope.digest == CaptureEvidenceEnvelope.hash(envelope.original) else {
            throw CaptureEvidenceStoreError.integrityFailure
          }
        }
      }
    }
  }

  /// Every returned identity has passed authenticated readback, not just a file lookup.
  public func list() throws -> [UUID] {
    try requireActiveCustody()
    let urls = try fileManager.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "evidence" }
    return try urls.map { url in
      guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
        throw CaptureEvidenceStoreError.invalidRecord
      }
      _ = try read(id: id)
      return id
    }.sorted { $0.uuidString < $1.uuidString }
  }

  /// Candidate identities selected by authenticated manifest metadata. Call `read` and
  /// validate source links before use. Unlike `list`, this is not an integrity audit
  /// of unrelated image payloads. Nil filters match any value, including absence.
  /// Existing manifests without these fields remain accessible by ID or `list`.
  public func matchingRecordIDs(
    captureID: UUID? = nil, sessionID: UUID? = nil, recordKind: String? = nil,
    recordingID: UUID? = nil
  ) throws -> [UUID] {
    try requireActiveCustody()
    var cache =
      index ?? CaptureEvidenceIndex.load(directory: directory, cipher: cipher)
      ?? CaptureEvidenceIndex()
    metadataDirectoryScanCount += 1
    let urls = try fileManager.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "evidence" }
    var present: Set<UUID> = []
    var changed = index == nil || indexDirty
    for url in urls {
      guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
        throw CaptureEvidenceStoreError.invalidRecord
      }
      present.insert(id)
      let fingerprint = try CaptureEvidenceIndex.Fingerprint(url: url)
      let needsRecordingSelector = recordingID != nil && cache.entries[id]?.recordingIDKnown != true
      if cache.entries[id]?.fingerprint != fingerprint || needsRecordingSelector {
        let manifest = try metadata(id: id)
        cache.entries[id] = .init(manifest: manifest, fingerprint: fingerprint)
        changed = true
      }
    }
    if Set(cache.entries.keys) != present {
      cache.entries = cache.entries.filter { present.contains($0.key) }
      changed = true
    }
    // Publication is independent of this expendable cache. A crash or failed index
    // write leaves the immutable evidence discoverable on the next reconciliation.
    indexDirty = changed
    index = cache
    return cache.entries.filter { _, entry in
      (captureID == nil || entry.captureID == captureID)
        && (sessionID == nil || entry.sessionID == sessionID)
        && (recordKind == nil || entry.recordKind == recordKind)
        && (recordingID == nil || entry.recordingID == recordingID)
    }.map(\.key).sorted { $0.uuidString < $1.uuidString }
  }

  /// Explicit single-writer acquisition scope. It never changes ordinary lookup discovery.
  /// The owner ends this scope after recording and admitted capture publications settle.
  public func beginLiveLookupScope(id: UUID, seedCaptureIDs: Set<UUID> = []) throws {
    try requireActiveCustody()
    guard liveLookup == nil else { throw CaptureEvidenceStoreError.invalidRecord }
    // Historical dependencies are reconciled before acquisition; a fresh scope
    // does no directory work. No actor publication can interleave with this seed.
    let seed =
      seedCaptureIDs.isEmpty
      ? CaptureEvidenceLookupSnapshot(candidates: [])
      : try lookupSnapshot(captureIDs: seedCaptureIDs)
    liveLookup = CaptureEvidenceLiveLookup(id: id, captureIDs: seedCaptureIDs, seed: seed)
  }

  /// Admit a newly generated capture identity before its first publication. Historical
  /// identities must use reconciled lookup; another writer is outside this scope.
  public func admitLiveCapture(captureID: UUID, scopeID: UUID) throws {
    try requireActiveCustody()
    guard liveLookup?.id == scopeID,
      !fileManager.fileExists(atPath: location(captureID).path),
      liveLookup?.captureIDs.contains(captureID) == false
    else { throw CaptureEvidenceStoreError.invalidRecord }
    liveLookup?.captureIDs.insert(captureID)
  }

  /// An old settlement cannot invalidate a later acquisition's catalog.
  public func endLiveLookupScope(id: UUID) {
    if liveLookup?.id == id { liveLookup = nil }
  }

  /// Pre-acquisition reconciled seeds and successful publications by this actor.
  /// Nil means acquisition is inactive. Missing scope dependencies fail explicitly;
  /// they cannot trigger archive reconciliation while recording. Callers still `read`.
  public func liveLookupSnapshot(captureIDs: Set<UUID>) throws -> CaptureEvidenceLookupSnapshot? {
    try requireActiveCustody()
    return try liveLookup?.snapshot(captureIDs: captureIDs)
  }

  /// Reconcile the live directory once, then freeze only the requested captures'
  /// authenticated routing selectors. Existing lookup APIs retain live discovery.
  public func lookupSnapshot(captureIDs: Set<UUID>) throws -> CaptureEvidenceLookupSnapshot {
    _ = try matchingRecordIDs()
    guard let index else { throw CaptureEvidenceStoreError.integrityFailure }
    return CaptureEvidenceLookupSnapshot(entries: index.entries, captureIDs: captureIDs)
  }

  /// Candidate originals only; caller must authenticate payload and verify its manifest identity.
  public func originalRecordIDs() throws -> [UUID] {
    let candidates = try matchingRecordIDs()
    return candidates.filter { id in
      guard let entry = index?.entries[id] else { return false }
      return entry.isOriginal ?? (entry.captureID == id && entry.recordKind == nil)
    }
  }

  /// Flush expendable routing cache at workflow boundaries, never for each video frame.
  public func checkpointMetadataIndex() throws {
    try requireActiveCustody()
    guard indexDirty, let index else { return }
    try index.persist(directory: directory, cipher: cipher)
    indexDirty = false
  }

  public func checkpoint(workflowID: UUID) throws -> CaptureCheckpointRecord? {
    try requireActiveCustody()
    return try CaptureCheckpointCodec.load(workflowID: workflowID, directory: directory, cipher: cipher)
  }

  /// Compare-and-swap through this custody actor prevents late workflow writes from
  /// replacing newer selections. A missing checkpoint is distinct from corruption.
  public func saveCheckpoint(
    _ value: CaptureCheckpointRecord, expectedRevision: UInt64?
  ) throws {
    try requireActiveCustody()
    try CaptureCheckpointCodec.withLock(directory: directory) {
      let previous = try checkpoint(workflowID: value.workflowID)
      if previous == value { return }
      guard previous?.revision == expectedRevision else {
        throw CaptureCheckpointError.staleRevision
      }
      guard expectedRevision != UInt64.max, value.revision > 0,
        value.revision == (expectedRevision ?? 0) + 1
      else { throw CaptureCheckpointError.invalidCheckpoint }
      try CaptureCheckpointCodec.save(value, directory: directory, cipher: cipher)
      guard try checkpoint(workflowID: value.workflowID) == value else {
        throw CaptureCheckpointError.invalidCheckpoint
      }
    }
  }

  /// Permanently closes this runtime before deletion. Actor serialization drains already admitted IO;
  /// queued and delayed mutations cannot recreate erased records or checkpoints.
  public func revokeAndRemoveAll() throws {
    // A completed generation must never touch this path again: a replacement may now own it.
    // Failed removal still retries while publication remains permanently closed.
    guard !revocationErasureCompleted else { return }
    try prepareErasure()
    try removeRecords()
    revocationErasureCompleted = true
  }

  /// Close admission and persist intent before any fallible native settlement or deletion.
  func prepareErasure() throws {
    guard !revocationErasureCompleted else { return }
    revoked = true
    publicationGeneration = UUID()
    index = nil
    liveLookup = nil
    try CaptureCustodyErasureState.markPending(directory: directory, fileManager: fileManager)
  }

  private func requirePublicationGeneration(_ admitted: UUID) throws {
    try requireActiveCustody()
    guard publicationGeneration == admitted else { throw CaptureEvidenceStoreError.custodyRevoked }
  }

  private func requireActiveCustody() throws {
    guard !revoked else { throw CaptureEvidenceStoreError.custodyRevoked }
    guard !keyMissing else { throw CaptureEvidenceStoreError.custodyKeyMissing }
  }

  // Reuses the custody lock so compare-and-publish is atomic even across internal store facades.
  func withCompletedResultPublication<Value>(_ body: () throws -> Value) throws -> Value {
    try requireActiveCustody()
    return try CaptureCheckpointCodec.withLock(directory: directory, operation: body)
  }

  /// Record-only maintenance. Successful completion keeps this generation usable;
  /// use `CaptureCustodyRuntime.erase()` to permanently revoke it and delete its key.
  /// Failure closes this instance. Once erase intent is durably recorded, partial deletion
  /// stays fenced across reopening. An unwritable intent fails before any records are removed.
  public func removeAll() throws {
    try requireActiveCustody()
    try prepareErasure()
    try removeRecords()
    try CaptureCustodyErasureState.completeMaintenance(directory: directory, fileManager: fileManager)
    revoked = false
  }

  private func removeRecords() throws {
    try CaptureCheckpointCodec.withLock(directory: directory) {
      index = nil
      liveLookup = nil
      let indexURL = CaptureEvidenceIndex.location(directory)
      if fileManager.fileExists(atPath: indexURL.path) {
        try fileManager.removeItem(at: indexURL)
      }
      for url in try fileManager.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil
      ) where ["evidence", "staging", "journey"].contains(url.pathExtension) {
        try fileManager.removeItem(at: url)
      }
      let remaining = try fileManager.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
      // Unknown files can be quarantined ciphertext. Do not retire the only usable key while an
      // unregistered artifact remains; report pending erasure for an explicit inventory repair.
      guard remaining.allSatisfy({ ["custody.erasure", "journey.lock"].contains($0.lastPathComponent) })
      else { throw CaptureEvidenceStoreError.integrityFailure }
    }
  }

  /// Deletes one published record. Callers hold the custody lock and choose a safe order.
  func removeRecord(id: UUID) throws {
    try requireActiveCustody()
    let url = location(id)
    guard fileManager.fileExists(atPath: url.path) else { return }
    try fileManager.removeItem(at: url)
    index?.entries[id] = nil
    indexDirty = true
  }

  private func location(_ id: UUID) -> URL {
    directory.appendingPathComponent(id.uuidString + ".evidence")
  }

  private func binding(_ id: UUID) -> Data {
    Data(("IdentityEvidenceStorage/v1/" + id.uuidString).utf8)
  }
}
