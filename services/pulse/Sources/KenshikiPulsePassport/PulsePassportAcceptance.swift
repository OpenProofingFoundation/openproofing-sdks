import Foundation
import CryptoKit

/// Private server capability. Persist only through protectedRepresentation in protected storage.
/// Deliberately no Codable, description, JSON export, or plaintext token accessor.
public struct PulsePassportHolderCapability: Sendable, Equatable {
    private struct Record: Codable, Sendable {let version:Int;let origin:URL;let installationID:String;let securityObjectSHA256:String;let binding:String}
    private let record:Record
    init(binding:String,origin:URL,installationID:String,securityObjectSHA256:String) throws {
        guard binding.range(of:"^[A-Za-z0-9_-]{43}$",options:.regularExpression) != nil else {throw PulsePassportFailure.invalidResponse}
        record = .init(version:1,origin:origin,installationID:installationID,securityObjectSHA256:securityObjectSHA256,binding:binding)
    }
    public func protectedRepresentation() throws -> Data {try JSONEncoder().encode(record)}
    public static func restore(_ bytes:Data,expectedOrigin:URL,installationID:String,securityObjectSHA256:String) throws -> Self {
        guard bytes.count <= 16_384 else {throw PulsePassportFailure.invalidResponse}
        let value=try JSONDecoder().decode(Record.self,from:bytes)
        guard value.version==1,value.origin==expectedOrigin,value.installationID==installationID,
              value.securityObjectSHA256==securityObjectSHA256 else {throw PulsePassportFailure.invalidResponse}
        return try .init(binding:value.binding,origin:value.origin,installationID:value.installationID,securityObjectSHA256:value.securityObjectSHA256)
    }
    public static func == (lhs:Self,rhs:Self)->Bool {lhs.record.origin==rhs.record.origin && lhs.record.installationID==rhs.record.installationID && lhs.record.securityObjectSHA256==rhs.record.securityObjectSHA256 && lhs.record.binding==rhs.record.binding}
}

/// Receipt context is associated only with the exact service request and SOD it verified.
public struct PulsePassportAcceptance: Sendable {
    public let origin:URL
    public let installationID:String
    public let sessionID:String
    public let nonceID:String
    public let clientReceivedAt:Date
    public let securityObjectSHA256:String
    public let report:PulsePassportValidationReport
    public let holderCapability:PulsePassportHolderCapability?
    init(client:PulsePassportClient,prepared:PulsePreparedPassport,proof:PulsePassportChipProof,verdict:PulsePassportVerification,now:Date) throws {
        try self.init(client:client,nonce:prepared.nonce,proof:proof,verdict:verdict,now:now)
    }
    init(client:PulsePassportClient,nonce:PulsePassportNonce,proof:PulsePassportChipProof,verdict:PulsePassportVerification,now:Date) throws {
        guard verdict.status == .verified,let report=verdict.validationReport else {throw PulsePassportFailure.invalidResponse}
        try report.validate()
        self.origin=client.baseURL;self.installationID=client.deviceID;self.sessionID=nonce.sessionID
        self.nonceID=nonce.nonceID;self.clientReceivedAt=now;self.report=report
        let digest=SHA256.hash(data:proof.securityObject).map{String(format:"%02x",$0)}.joined()
        securityObjectSHA256=digest
        holderCapability=try verdict.holderBinding.map{try .init(binding:$0,origin:client.baseURL,installationID:client.deviceID,securityObjectSHA256:digest)}
    }
}
public struct PulsePassportRead<Read:Sendable>:Sendable {
    public let read:Read
    public let proof:PulsePassportChipProof
    public let chipAuthenticationResponse:Data?
    public init(read:Read,proof:PulsePassportChipProof,chipAuthenticationResponse:Data?) {self.read=read;self.proof=proof;self.chipAuthenticationResponse=chipAuthenticationResponse}
}
public struct PulsePassportAcceptedRead<Read:Sendable>:Sendable {
    public let read:Read
    public let acceptance:PulsePassportAcceptance
    public let verification:PulsePassportVerification
}
