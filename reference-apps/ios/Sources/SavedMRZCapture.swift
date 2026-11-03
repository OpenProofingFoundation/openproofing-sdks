import Foundation
import PassportSDK

/// A saved access observation can resume NFC; it does not assert that a chip was read.
struct SavedMRZCapture: Codable, Sendable {
    enum Source: String, Codable, Sendable { case optical, manual }
    let version: Int
    let id: UUID
    let capturedAt: Date
    let source: Source
    let fields: PassportManualAccessFields
    let normalizedLines: [String]?

    init(fields: PassportManualAccessFields, lines: [String]?, capturedAt: Date = Date()) throws {
        version = 1; id = UUID(); self.capturedAt = capturedAt; self.fields = fields
        normalizedLines = lines; source = lines == nil ? .manual : .optical
        try validate()
    }

    func validate() throws {
        guard version == 1, SavedFaceCapture.validDate(capturedAt) else { throw FaceWorkflowStorageFailure.invalidRecord }
        _ = try PassportAccessKey(documentNumber: fields.documentNumber,
            birthDateYYMMDD: fields.birthDateYYMMDD, expiryDateYYMMDD: fields.expiryDateYYMMDD)
        if source == .optical {
            guard let normalizedLines, normalizedLines.count == 2,
                  normalizedLines.allSatisfy({ $0.utf8.count == 44 }),
                  let parsed = PassportMRZOCRParser.parseComplete(candidates: normalizedLines.map { [$0] }),
                  parsed.documentNumber == fields.documentNumber,
                  parsed.birthDateYYMMDD == fields.birthDateYYMMDD,
                  parsed.expiryDateYYMMDD == fields.expiryDateYYMMDD else { throw FaceWorkflowStorageFailure.invalidRecord }
        } else if normalizedLines != nil { throw FaceWorkflowStorageFailure.invalidRecord }
    }

    var printedMRZ: PassportMRZObservation? {
        normalizedLines.flatMap { PassportMRZOCRParser.parseComplete(candidates: $0.map { [$0] }) }
    }
}
