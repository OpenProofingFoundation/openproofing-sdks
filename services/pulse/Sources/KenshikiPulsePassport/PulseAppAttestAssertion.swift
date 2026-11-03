import Foundation

/// Wire assertion in exactly one representation: the complete CBOR object, or its two components.
/// Codable validates shape and nonempty fields; the service must authenticate their contents.
public struct PulseAppAttestAssertion: Codable, Equatable, Sendable {
    public let keyID: String
    public let clientDataHash: String
    public let authenticatorData: String?
    public let signature: String?
    public let assertionObject: String?

    /// Keeps the existing construction API. Empty values are rejected when encoded for transport.
    public init(keyID: String, clientDataHash: String, authenticatorData: String, signature: String) {
        self.keyID = keyID
        self.clientDataHash = clientDataHash
        self.authenticatorData = authenticatorData
        self.signature = signature
        self.assertionObject = nil
    }

    /// Keeps the existing construction API. Empty values are rejected when encoded for transport.
    public init(keyID: String, clientDataHash: String, assertionObject: String) {
        self.keyID = keyID
        self.clientDataHash = clientDataHash
        self.authenticatorData = nil
        self.signature = nil
        self.assertionObject = assertionObject
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyID = try container.decode(String.self, forKey: .keyID)
        clientDataHash = try container.decode(String.self, forKey: .clientDataHash)
        if container.contains(.assertionObject) {
            guard !container.contains(.authenticatorData), !container.contains(.signature) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "App Attest assertion representations must not be mixed."))
            }
            assertionObject = try container.decode(String.self, forKey: .assertionObject)
            authenticatorData = nil
            signature = nil
        } else {
            authenticatorData = try container.decode(String.self, forKey: .authenticatorData)
            signature = try container.decode(String.self, forKey: .signature)
            assertionObject = nil
        }
        guard hasNonemptyFields else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "App Attest assertion fields must not be empty."))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        guard hasNonemptyFields else {
            throw EncodingError.invalidValue(self, .init(
                codingPath: encoder.codingPath,
                debugDescription: "App Attest assertion fields must not be empty."))
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyID, forKey: .keyID)
        try container.encode(clientDataHash, forKey: .clientDataHash)
        try container.encodeIfPresent(authenticatorData, forKey: .authenticatorData)
        try container.encodeIfPresent(signature, forKey: .signature)
        try container.encodeIfPresent(assertionObject, forKey: .assertionObject)
    }

    private var hasNonemptyFields: Bool {
        let fields = [keyID, clientDataHash, authenticatorData, signature, assertionObject].compactMap { $0 }
        return fields.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    enum CodingKeys: String, CodingKey {
        case keyID = "key_id"
        case clientDataHash = "client_data_hash"
        case authenticatorData = "authenticator_data"
        case signature
        case assertionObject = "assertion_object"
    }
}
