// Responsibility: Converts a verified reader model into the public passport observation.
// Control: Requires passive authentication, rejects failed chip protocols and admits DG2 only through its digest binding.
// App counterpart: PassportChipRead receives these results through PassportChipReader.
// Specification: RFC-0002 §§4.2–4.3; capability-evidence-and-assurance-plan §3.12.

import Foundation
import PassportSDK

#if os(iOS)
  @preconcurrency import NFCPassportReader

  /// Accepts only verified chip evidence and keeps biometric bytes out of general data groups.
  enum PassportObservationMapper {
    static func observation(_ model: NFCPassportModel) throws -> PassportReadObservation
    {
      switch model.passiveAuthenticationVerdict {
      case .verified: break
      case .trustAnchorNotFound: throw PassportReadFailure.trustAnchorNotFound
      case .integrityFailure: throw PassportReadFailure.dataIntegrityFailure
      }
      guard let sod = model.dataGroupsRead[.SOD],
        let dg1 = model.dataGroupsRead[.DG1] as? DataGroup1,
        let mrzName = dg1.elements["5B"] else {
        throw PassportReadFailure.dataIntegrityFailure
      }
      // DG11 can expand or differently encode names truncated in the printed MRZ. Compare the
      // reviewed page with the authenticated DG1 MRZ, retaining DG11 separately in original groups.
      let names = mrzName.components(separatedBy: "<<")
      let surname = names[0].replacingOccurrences(of: "<", with: " ")
      let givenNames = names.dropFirst().map {
        $0.replacingOccurrences(of: "<", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
      }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
      var groups: [String: Data] = [:]
      for (id, group) in model.dataGroupsRead where id != .DG2 {
        groups[id.getName()] = Data(group.data)
      }
      let portraitGroup = model.dataGroupsRead[.DG2] as? DataGroup2
      let portrait = PassportAuthenticatedPortrait.admit(
        dg2: portraitGroup.map { Data($0.data) }, portrait: portraitGroup.map { Data($0.imageData) },
        sodDigest: model.dataGroupHashes[.DG2]?.sodHash,
        reportedMatch: model.dataGroupHashes[.DG2]?.match == true)
      let certificate = model.documentSigningCertificate.flatMap { certificate in
        Data(
          base64Encoded: certificate.certToPEM().split(separator: "\n")
            .filter { !$0.hasPrefix("-----") }.joined())
      }
      let dg12 = model.dataGroupsRead[.DG12] as? DataGroup12
      func present(_ text: String?) -> String? { text?.isEmpty == false ? text : nil }
      let activeAuthentication: PassportProtocolObservation =
        model.activeAuthenticationChallenge.isEmpty && model.activeAuthenticationSignature.isEmpty
        ? .notPerformed : (model.activeAuthenticationPassed ? .succeeded : .failed)
      let chipAuthentication = protocolObservation(model.chipAuthenticationStatus)
      try PassportChipAuthenticity.require(
        activeAuthentication: activeAuthentication, chipAuthentication: chipAuthentication)
      var observation = PassportReadObservation(
        documentNumber: model.documentNumber, surname: surname, givenNames: givenNames,
        nationality: model.nationality, issuingState: model.issuingAuthority,
        birthDateYYMMDD: model.dateOfBirth, expiryDateYYMMDD: model.documentExpiryDate,
        sex: model.gender.isEmpty ? "<" : model.gender,
        personalNumber: present(model.personalNumber),
        dateOfIssue: present(dg12?.dateOfIssue), issuingAuthority: present(dg12?.issuingAuthority),
        placeOfBirth: present(model.placeOfBirth),
        basicAccessControl: protocolObservation(model.BACStatus),
        pace: protocolObservation(model.PACEStatus),
        activeAuthentication: activeAuthentication,
        chipAuthentication: chipAuthentication,
        countrySigningChain: .succeeded, documentSignature: .succeeded, dataGroupHashes: .succeeded,
        documentSigningCertificateDER: certificate,
        activeAuthenticationChallenge: model.activeAuthenticationChallenge.isEmpty
          ? nil : Data(model.activeAuthenticationChallenge),
        activeAuthenticationSignature: model.activeAuthenticationSignature.isEmpty
          ? nil : Data(model.activeAuthenticationSignature),
        securityObject: Data(sod.data), dataGroups: groups,
        declaredDataGroups: model.dataGroupsPresent,
        dg2: portrait?.dg2, portrait: portrait?.portrait,
        dg2Digest: portrait?.digest, dg2DigestAlgorithm: portrait?.algorithm,
        chipAuthenticationResponse: model.chipAuthenticationTerminalResponse.isEmpty
          ? nil : Data(model.chipAuthenticationTerminalResponse)
      )
      if let stage = model.paceFailureStage, let code = model.paceFailureCode {
        observation.paceFailure = PassportPACEFailure(
          stage: stage, code: code, statusWord: model.paceFailureStatusWord)
      }
      return observation
    }

    private static func protocolObservation(_ value: PassportAuthenticationStatus)
      -> PassportProtocolObservation
    {
      switch value {
      case .notDone: .notPerformed
      case .success: .succeeded
      case .failed: .failed
      }
    }
  }
#endif
