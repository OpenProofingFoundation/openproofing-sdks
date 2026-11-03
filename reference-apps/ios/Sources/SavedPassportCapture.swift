import CryptoKit
import Foundation
import PassportSDK

enum PassportCaptureStorageFailure: Error { case invalidCapture, unsupportedVersion, unavailable }

/// One explicit, reusable local reference. A stored read is not a fresh NFC session or server verdict.
struct SavedPassportCapture: Codable, Sendable {
    let version: Int
    let id: UUID
    let capturedAt: Date
    let localTrustBundleSHA256: String?
    let portraitSHA256: String
    let securityObjectSHA256: String
    let printedMRZLines: [String]?
    let nfc: SavedPassportNFC
    let serverVerification: PassportServerVerification?

    init(_ accepted: AcceptedPassportPortrait, capturedAt: Date? = nil, trustBundleSHA256: String? = nil) throws {
        version = 1
        id = accepted.attemptID
        self.capturedAt = capturedAt ?? accepted.capturedAt
        localTrustBundleSHA256 = trustBundleSHA256
        portraitSHA256 = Self.digest(accepted.read.portrait ?? Data())
        securityObjectSHA256 = Self.digest(accepted.read.securityObject)
        printedMRZLines = accepted.printedMRZ?.normalizedLines
        nfc = SavedPassportNFC(accepted.read)
        serverVerification = accepted.serverVerification
        try validate()
    }

    func validate() throws {
        guard version == 1 else { throw PassportCaptureStorageFailure.unsupportedVersion }
        guard capturedAt.timeIntervalSince1970.isFinite,
              (0..<253402300800).contains(capturedAt.timeIntervalSince1970),
              let portrait = nfc.portrait, !portrait.isEmpty,
              let dg2 = nfc.dg2, !dg2.isEmpty, !nfc.securityObject.isEmpty,
              nfc.basicAccessControl == .succeeded || nfc.pace == .succeeded,
              nfc.countrySigningChain == .succeeded, nfc.documentSignature == .succeeded,
              nfc.dataGroupHashes == .succeeded, nfc.activeAuthentication != .failed,
              nfc.chipAuthentication != .failed,
              Self.digest(portrait) == portraitSHA256,
              Self.digest(nfc.securityObject) == securityObjectSHA256 else {
            throw PassportCaptureStorageFailure.invalidCapture
        }
        if let serverVerification {
            do { try serverVerification.validate(securityObject: nfc.securityObject, capturedAt: capturedAt) }
            catch { throw PassportCaptureStorageFailure.invalidCapture }
        }
        let proofBytes = [nfc.documentSigningCertificateDER, nfc.activeAuthenticationChallenge,
            nfc.activeAuthenticationSignature, nfc.chipAuthenticationResponse].compactMap { $0 }
        let byteCount = (Array(nfc.dataGroups.values) + proofBytes).reduce(portrait.count + dg2.count + nfc.securityObject.count) { $0 + $1.count }
        guard byteCount <= 16 * 1024 * 1024,
              dg2.range(of: portrait) != nil,
              let computedDigest = Self.groupDigest(dg2, algorithm: nfc.dg2DigestAlgorithm),
              nfc.dg2Digest == computedDigest,
              localTrustBundleSHA256.map({ $0.count == 64 && $0.allSatisfy(\.isHexDigit) }) ?? true else {
            throw PassportCaptureStorageFailure.invalidCapture
        }
        if let lines = printedMRZLines {
            guard lines.count == 2,
                  let mrz = PassportMRZOCRParser.parseComplete(candidates: lines.map { [$0] }),
                  mrz.documentNumber == nfc.documentNumber,
                  mrz.birthDateYYMMDD == nfc.birthDateYYMMDD,
                  mrz.expiryDateYYMMDD == nfc.expiryDateYYMMDD else {
                throw PassportCaptureStorageFailure.invalidCapture
            }
        }
    }

    func encoded() throws -> Data {
        try validate()
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let bytes = try encoder.encode(self)
        guard bytes.count <= Self.maximumBytes else { throw PassportCaptureStorageFailure.invalidCapture }
        return bytes
    }

    static let maximumBytes = 20 * 1024 * 1024

    static func decode(_ bytes: Data) throws -> Self {
        guard bytes.count <= maximumBytes else { throw PassportCaptureStorageFailure.invalidCapture }
        let record = try PropertyListDecoder().decode(Self.self, from: bytes)
        try record.validate()
        return record
    }

    static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func groupDigest(_ bytes: Data, algorithm: String?) -> String? {
        let digest: [UInt8]
        switch algorithm {
        case "SHA-1": digest = Array(Insecure.SHA1.hash(data: bytes))
        case "SHA-256": digest = Array(SHA256.hash(data: bytes))
        case "SHA-384": digest = Array(SHA384.hash(data: bytes))
        case "SHA-512": digest = Array(SHA512.hash(data: bytes))
        default: return nil
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// App-owned archival values. Decoding never creates a new SDK verification result.
struct SavedPassportNFC: Codable, Sendable {
    let paceFailure: PassportPACEFailure?
    let documentNumber: String
    let surname: String
    let givenNames: String
    let nationality: String
    let issuingState: String
    let birthDateYYMMDD: String
    let expiryDateYYMMDD: String
    let sex: String
    let personalNumber: String?
    let dateOfIssue: String?
    let issuingAuthority: String?
    let placeOfBirth: String?
    let basicAccessControl: PassportProtocolObservation
    let pace: PassportProtocolObservation
    let activeAuthentication: PassportProtocolObservation
    let chipAuthentication: PassportProtocolObservation
    let countrySigningChain: PassportProtocolObservation
    let documentSignature: PassportProtocolObservation
    let dataGroupHashes: PassportProtocolObservation
    let documentSigningCertificateDER: Data?
    let activeAuthenticationChallenge: Data?
    let activeAuthenticationSignature: Data?
    let securityObject: Data
    let dataGroups: [String: Data]
    let declaredDataGroups: [String]
    let dg2: Data?
    let portrait: Data?
    let dg2Digest: String?
    let dg2DigestAlgorithm: String?
    let chipAuthenticationResponse: Data?

    init(_ read: PassportReadObservation) {
        paceFailure = read.paceFailure
        documentNumber = read.documentNumber
        surname = read.surname
        givenNames = read.givenNames
        nationality = read.nationality
        issuingState = read.issuingState
        birthDateYYMMDD = read.birthDateYYMMDD
        expiryDateYYMMDD = read.expiryDateYYMMDD
        sex = read.sex
        personalNumber = read.personalNumber
        dateOfIssue = read.dateOfIssue
        issuingAuthority = read.issuingAuthority
        placeOfBirth = read.placeOfBirth
        basicAccessControl = read.basicAccessControl
        pace = read.pace
        activeAuthentication = read.activeAuthentication
        chipAuthentication = read.chipAuthentication
        countrySigningChain = read.countrySigningChain
        documentSignature = read.documentSignature
        dataGroupHashes = read.dataGroupHashes
        documentSigningCertificateDER = read.documentSigningCertificateDER
        activeAuthenticationChallenge = read.activeAuthenticationChallenge
        activeAuthenticationSignature = read.activeAuthenticationSignature
        securityObject = read.securityObject
        dataGroups = read.dataGroups
        declaredDataGroups = read.declaredDataGroups
        dg2 = read.dg2
        portrait = read.portrait
        dg2Digest = read.dg2Digest
        dg2DigestAlgorithm = read.dg2DigestAlgorithm
        chipAuthenticationResponse = read.chipAuthenticationResponse
    }
}
