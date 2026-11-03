import Foundation

#if os(iOS) && canImport(DeviceCheck)
  import DeviceCheck
#endif

/// Signs only with a registered platform key. Key creation/replacement is outside this API.
/// Apple generateAssertion API contract retrieved 2026-10-17; hardware acceptance is separate.
public actor RegisteredAppAttestSigner {
  public static let shared = RegisteredAppAttestSigner { key, digest in
    try await platformAssertion(key, digest)
  }
  private let generate: @Sendable (String, Data) async throws -> Data
  private var pending: [String: (id: UUID, task: Task<Data, Error>)] = [:]

  // Internal injection exercises scheduling without a device. Production clients use shared.
  init(generate: @escaping @Sendable (String, Data) async throws -> Data) {
    self.generate = generate
  }

  public func assertion(keyID: String, clientDataHash: Data) async throws -> Data {
    guard !keyID.isEmpty, clientDataHash.count == 32 else {
      throw OperationBindingError.invalidField("platform_assertion_input")
    }
    let preceding = pending[keyID]?.task
    let identifier = UUID()
    let generate = self.generate
    let task = Task<Data, Error> {
      if let preceding {
        do { _ = try await preceding.value } catch {
          // A prior failure must not poison the next valid operation.
        }
      }
      try Task.checkCancellation()
      return try await generate(keyID, clientDataHash)
    }
    pending[keyID] = (identifier, task)
    defer {
      if pending[keyID]?.id == identifier { pending.removeValue(forKey: keyID) }
    }
    return try await withTaskCancellationHandler {
      let result = try await task.value
      try Task.checkCancellation()
      return result
    } onCancel: {
      task.cancel()
    }
  }

  private static func platformAssertion(_ keyID: String, _ digest: Data) async throws -> Data {
    #if os(iOS) && canImport(DeviceCheck)
      guard DCAppAttestService.shared.isSupported else {
        throw OperationBindingError.invalidField("platform_assertion_unavailable")
      }
      return try await DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: digest)
    #else
      throw OperationBindingError.invalidField("platform_assertion_unavailable")
    #endif
  }
}
