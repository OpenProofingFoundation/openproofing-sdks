import Testing

@testable import DocumentSDK

@Test func licenceFrontReadsTheStatePrintedAcrossTheTop() {
  let front = LicenseFrontVisualFields.extract(lines: [
    "WASHINGTON", "DRIVER LICENSE", "4d DLN WDL0000000X0", "1 SAMPLE", "2 ALEX ROBIN",
    "8 100 EXAMPLE WAY", "OLYMPIA, WA 98501",
  ])
  #expect(front.issuingJurisdiction == "WA")
  #expect(front.issuingJurisdictionLine == "WASHINGTON")
}

@Test func licenceFrontAcceptsTitleWordsBesideTheName() {
  #expect(LicenseFrontVisualFields.headerJurisdiction("California USA DRIVER LICENSE") == "CA")
  #expect(LicenseFrontVisualFields.headerJurisdiction("Commonwealth of Pennsylvania") == "PA")
  #expect(LicenseFrontVisualFields.headerJurisdiction("DISTRICT OF COLUMBIA") == "DC")
  #expect(LicenseFrontVisualFields.headerJurisdiction("West Virginia") == "WV")
  #expect(LicenseFrontVisualFields.headerJurisdiction("VIRGINIA") == "VA")
  #expect(LicenseFrontVisualFields.headerJurisdiction("New York State ENHANCED") == "NY")
}

@Test func licenceFrontIgnoresAddressesAndOtherText() {
  #expect(LicenseFrontVisualFields.headerJurisdiction("WASHINGTON DC 20001") == nil)
  #expect(LicenseFrontVisualFields.headerJurisdiction("VIRGINIA BEACH VA 23451") == nil)
  #expect(LicenseFrontVisualFields.headerJurisdiction("OREGON CITY OR 97045") == nil)
  #expect(LicenseFrontVisualFields.headerJurisdiction("KANSASVILLE") == nil)
  #expect(LicenseFrontVisualFields.headerJurisdiction("") == nil)
}

@Test func licenceFrontGivesNothingForTwoStatesOrNone() {
  #expect(LicenseFrontVisualFields.extract(lines: ["WASHINGTON", "OREGON"]).issuingJurisdiction == nil)
  #expect(LicenseFrontVisualFields.extract(lines: ["DRIVER LICENSE"]).issuingJurisdiction == nil)
  #expect(LicenseFrontVisualFields.extract(lines: ["WASHINGTON", "Washington"]).issuingJurisdiction == "WA")
}
