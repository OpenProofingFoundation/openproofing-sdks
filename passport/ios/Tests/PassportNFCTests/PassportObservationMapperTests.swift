#if os(iOS)
  import Foundation
  import XCTest
  @testable import NFCPassportReader
  @testable import PassportSDK
  @testable import PassportNFC

  /// Synthetic TD3/DG11 bytes, a generated public CSCA/DSC and SHA-256 signed CMS LDS object.
  /// Public fixture bytes only: no person, image, chip dump, production trust or private key.
  final class PassportObservationMapperTests: XCTestCase {
    func testAttemptedAAWithEmptyResponseCannotDowngradeToNotPerformed() throws {
      let model = try verifiedModel()
      model.verifyActiveAuthentication(challenge: Array(repeating: 1, count: 8), signature: [])
      XCTAssertFalse(model.activeAuthenticationPassed)
      XCTAssertThrowsError(try PassportObservationMapper.observation(model)) {
        XCTAssertEqual($0 as? PassportReadFailure, .activeAuthenticationFailed)
      }
    }
    func testAuthenticatedDG1NamesCorrespondWhenDG11ExpandsTruncatedGivenNames() throws {
      let model = try verifiedModel()
      XCTAssertEqual(model.firstName, "JANE ANN MARIA ELIZABETH FRANCES ALICE")
      let read = try PassportObservationMapper.observation(model)
      let printed = try printedObservation()
      XCTAssertNotEqual(read.givenNames, model.firstName)
      XCTAssertEqual(PassportCorrespondenceObservation(printed: printed, chip: read).mismatchedFields, [])
      XCTAssertEqual(read.dataGroups["DG1"], Self.dg1)
      XCTAssertEqual(read.dataGroups["DG11"], Self.dg11)
    }

    func testDifferentPrintedDG1SurnameStillFailsCorrespondenceAfterVerifiedRead() throws {
      let read = try PassportObservationMapper.observation(verifiedModel())
      let printed = try printedObservation(first: Self.first.replacingOccurrences(of: "SAMPLE", with: "OTHERX"))
      XCTAssertEqual(PassportCorrespondenceObservation(printed: printed, chip: read).mismatchedFields, [.surname])
    }

    func testDG1NameProjectionDoesNotRequireOptionalDG11() throws {
      let read = try PassportObservationMapper.observation(verifiedModel(includeDG11: false))
      XCTAssertNil(read.dataGroups["DG11"])
      XCTAssertEqual(PassportCorrespondenceObservation(printed: try printedObservation(), chip: read).mismatchedFields, [])
    }

    func testChangedDG1CannotReachNameProjectionWithoutItsSignedHash() throws {
      let altered = Data(String(decoding: Self.dg1, as: UTF8.self)
        .replacingOccurrences(of: "SAMPLE", with: "OTHERX").utf8)
      let model = try verifiedModel(dg1: altered, expectVerified: false)
      XCTAssertEqual(model.passiveAuthenticationVerdict, .integrityFailure)
      XCTAssertThrowsError(try PassportObservationMapper.observation(model)) {
        XCTAssertEqual($0 as? PassportReadFailure, .dataIntegrityFailure)
      }
    }

    private func printedObservation(first: String? = nil) throws -> PassportMRZObservation {
      try XCTUnwrap(PassportMRZOCRParser.parseComplete(candidates: [[first ?? Self.first], [Self.second]]))
    }

    private func verifiedModel(includeDG11: Bool = true, dg1: Data? = nil,
      expectVerified: Bool = true) throws -> NFCPassportModel {
      var dump = ["DG1": (dg1 ?? Self.dg1).base64EncodedString(), "SOD": Self.sod.base64EncodedString()]
      if includeDG11 { dump["DG11"] = Self.dg11.base64EncodedString() }
      let model = NFCPassportModel(from: dump)
      XCTAssertNotNil(model.getDataGroup(.DG1))
      XCTAssertNotNil(model.getDataGroup(.SOD))
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pem")
      try Self.trust.write(to: url)
      defer { try? FileManager.default.removeItem(at: url) }
      model.verifyPassport(masterListURL: url)
      if expectVerified { XCTAssertEqual(model.passiveAuthenticationVerdict, .verified) }
      model.BACStatus = .success
      return model
    }

    private static let first = "P<UTOSAMPLE<<JANE<ANN<MARIA<ELIZABETH<FRANCE"
    private static let second = "X1234567<7UTO8506151F3201015<<<<<<<<<<<<<<08"

    private static let dg1 = Data(base64Encoded: """
      YVtfH1hQPFVUT1NBTVBMRTw8SkFORTxBTk48TUFSSUE8RUxJWkFCRVRIPEZSQU5DRVgxMjM0NTY3PDdVVE84NTA2MTUxRjMy
      MDEwMTU8PDw8PDw8PDw8PDw8PDA4
      """, options: .ignoreUnknownCharacters)!

    private static let dg11 = Data(base64Encoded: """
      azVcAl8OXw4uU0FNUExFPDxKQU5FPEFOTjxNQVJJQTxFTElaQUJFVEg8RlJBTkNFUzxBTElDRQ==
      """, options: .ignoreUnknownCharacters)!

    private static let sod = Data(base64Encoded: """
      d4IFPTCCBTkGCSqGSIb3DQEHAqCCBSowggUmAgEDMQ0wCwYJYIZIAWUDBAIBMHAGBmeBCAEBAaBmBGQwYgIBADANBglghkgB
      ZQMEAgEFADBOMCUCAQEEILSZMMF7tekOIyM6fT+xbbDMoo7a0T09x5xjzvSK2xEWMCUCAQsEIB3kcbvFSL4cWDUW7TrS06ej
      DbKk9xkY34Wcgx5Fy52zoIIC3jCCAtowggHCoAMCAQICAWYwDQYJKoZIhvcNAQELBQAwJjEkMCIGA1UEAwwbU1lOVEhFVElD
      IE1SWiBSRUdSRVNTSU9OIENBMCAXDTIwMDEwMTAwMDAwMFoYDzIxMjAwMTAxMDAwMDAwWjAnMSUwIwYDVQQDDBxTWU5USEVU
      SUMgTVJaIFJFR1JFU1NJT04gRFNDMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAs/FDH1W147xozDWDm2+UDRbZ
      1ypN9+Vc7/8Jdvxv+1pAbjRi1h+YNLjfUinXpvgXOY1SbFTde/cDzuVgQ+A80Hf9befapdBg3Fl22UXEVTX84nX+Eqh7Q3EK
      AypcEBi/gjvhDTz0y08nsLa6uN1X9JxfzEmy68JNfTh8t+MHdFwcrMJ/X8rEZJ2M948s//TiOjwrGHyoQejdrtXS4/z3hIyw
      KPRtCNrLHHMx2xEWK5BIR85jiKq2KChubeYc5CR6AcHY0DqBA8hi1TaGB4wG4x0WJn352Jp481yxCYnx9vGWtCcMuwQKOyOv
      vGxIFLFXngSLSMAiq01oCFppFjmjSQIDAQABoxAwDjAMBgNVHRMBAf8EAjAAMA0GCSqGSIb3DQEBCwUAA4IBAQA+PsrNVRiX
      LLsf94L53woa246jelnMvDaSARUXgalGhGR2FXPafHckJheZXsh5IKMri5sSio0MTT3/dKv/c04la38A52xC+ZAA9t/rMip6
      7ZdB66mtRk2tRWteNrLIo+Xq/wN2TLqOtASP4Hx7ainOQCKdXpXVkkksqGYXEHNiG/tPjBJvyjfTLDMKrNM/UFB5qlbjzObf
      mHB1EL5nCLYJHsV1bHYl/NNeWBbHpPRQ+3Qq13z5g3+Iw7oDydQBFnX1YHjHKSxRH930aaHTR1MQuBi+eWXFAqDN4+TcMszZ
      9k9VxeHBKF5ybHbMCdNjDR05um2x6kQmkZhgSAR64DGJMYIBvDCCAbgCAQEwKzAmMSQwIgYDVQQDDBtTWU5USEVUSUMgTVJa
      IFJFR1JFU1NJT04gQ0ECAWYwCwYJYIZIAWUDBAIBoGYwFQYJKoZIhvcNAQkDMQgGBmeBCAEBATAcBgkqhkiG9w0BCQUxDxcN
      MjYxMDIzMTkxODQwWjAvBgkqhkiG9w0BCQQxIgQg/Wdohhe009Os6KWzv38Eyedb9OFj45/cG78ugQgYr6MwDQYJKoZIhvcN
      AQEBBQAEggEASETNjKXVLlDBwIpE7+44qpIZhptBCTXmqMBD+5aCK0bU8/sB35ZQ7KaNy/F3CnWSnNntkJXh8/8ofrx4//wu
      CJNGLW4J/yW2IMejpPA6o6jIpTuxdtedQdPfQsRu2E+4TygML69cAe7qJdWilHJ+KVJBV1hTlHPtOWdRR/t2/RBq6XcxEAun
      oo4LKds/cy06eRnWfFmowJhue0ylEz/KCz91g9nn4tGY7AVD5XQnjW5r/bfllkc7bPyhNOixz+Yb/Gy6s3D/qdHOiYNvHjdM
      V1y0YhP9K+325XxdY8YbL6QOmbcadZX8pPcWPY203jtqIS8oONw0RfIPrCdXd022Pw==
      """, options: .ignoreUnknownCharacters)!

    private static let trust = Data(base64Encoded: """
      LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSUMzRENDQWNTZ0F3SUJBZ0lCWlRBTkJna3Foa2lHOXcwQkFRc0ZBREFt
      TVNRd0lnWURWUVFEREJ0VFdVNVUKU0VWVVNVTWdUVkphSUZKRlIxSkZVMU5KVDA0Z1EwRXdJQmNOTWpBd01UQXhNREF3TURB
      d1doZ1BNakV5TURBeApNREV3TURBd01EQmFNQ1l4SkRBaUJnTlZCQU1NRzFOWlRsUklSVlJKUXlCTlVsb2dVa1ZIVWtWVFUw
      bFBUaUJEClFUQ0NBU0l3RFFZSktvWklodmNOQVFFQkJRQURnZ0VQQURDQ0FRb0NnZ0VCQU1kT3V2UENuNDkyRGh0UzlCVWQK
      cStLbi94TEpGNm5wcCt0VUlOZ1hxNVNQLzd1ejRqd1pKbVIvcDNFdnVkTi9QZklVaFVpYUhXYmNtSzVUbmFyMwpweEVaUVVO
      U3ZZem16Z1Y3QkJwSE8vRGo2Wlk1dVVBOXVyTVJRVzJJZ3plai9lalZNZVZFYytzbi8rN3lLbGNrCmM3NnBJU3U4WmhrL1Bk
      YlUrMUY3M0ZNWkZSdG9EbTZOSmF5YVpqZ1ZHRnFIVlIwN09Pamp2ZWpyK21LYW02OWYKZFJpaENESTFvTnVYeW56SGI0SjJZ
      U0FYN01yeG8vekJ4RkpiYTk5THhmTGtPSGUvMzkydDlWTi9XQWRueWMzegpmelJUbmQyWm10cllBZi9NQkdJbGE1a1Q3VTk3
      QVk5S3E0NFhielByeWpxeGRtVytaSVd2MEFuSXRGdmR0bGJyCmVMTUNBd0VBQWFNVE1CRXdEd1lEVlIwVEFRSC9CQVV3QXdF
      Qi96QU5CZ2txaGtpRzl3MEJBUXNGQUFPQ0FRRUEKRDFJaityZGZpYW54dHorNFJFVEt6UlAwTm05OXJIN1htN3ZBaHVYOEp5
      VzRTbVNRVUI1Uys2YzdEWFBGWXl3awo0cnhRTHJ2L3B0c2ZJcStuaVZJUWhwZG9hMXJvSkU3OTBuak10Q2QvclZoMUpxdk14
      YURKYVE5SVJvYUk4QWt2CkxwNXdCTnd2UWQ5NjNzaFJDK040V3dWUm5SKzhYZ002WHU3L3Q4cDhySTFubHp0c09xRWEvN014
      U3BGWHpvWG8KWHBYYXpOc0ZaY0VvdzZDdDRhcmdhZnhMb0VmNWg5Z2pRK2V1ZURoYVRMRE5JTWhGVkVsSSttUy85QWdxVzFv
      NwpPRW9Cb2g0eHQzMkhoanlXUzdoTSs0dXpldW9lRFNUSzhoeGc1aEcwRjRzdDJGOXZZZnNXMWhqQWpTNXRUbVV4CnZ3VTIv
      WEQwWFFHV08yUXh4NExuMWc9PQotLS0tLUVORCBDRVJUSUZJQ0FURS0tLS0tCg==
      """, options: .ignoreUnknownCharacters)!
  }
#endif
