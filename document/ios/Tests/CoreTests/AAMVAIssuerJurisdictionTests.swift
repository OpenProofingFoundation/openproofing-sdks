import Testing
@testable import DocumentSDK

@Test func aamvaIssuerJurisdictionPreservesCriticalWorkerMappings() {
  #expect(AAMVAIssuerJurisdiction.resolve("636005") == "SC")
  #expect(AAMVAIssuerJurisdiction.resolve("636045") == "WA")
  #expect(AAMVAIssuerJurisdiction.resolve("636020") == "CO")
  #expect(AAMVAIssuerJurisdiction.resolve(" 636014\n") == "CA")
  #expect(AAMVAIssuerJurisdiction.resolve("604427") == "AS")
  #expect(AAMVAIssuerJurisdiction.resolve("604430") == "MP")
  #expect(AAMVAIssuerJurisdiction.resolve("604431") == "PR")
  #expect(AAMVAIssuerJurisdiction.resolve("636019") == "GU")
  #expect(AAMVAIssuerJurisdiction.resolve("636062") == "VI")
}

@Test func aamvaIssuerJurisdictionDoesNotGuessForeignDiplomaticOrMalformedInputs() {
  for iin in ["636012", "604428", "636056", "636057", "636027", "999999",
              "", "63601", "6360050", "636 005", "SC", "WA", "US-SC"] {
    #expect(AAMVAIssuerJurisdiction.resolve(iin) == nil)
  }
}

@Test func aamvaIssuerJurisdictionCoversWorkerUSCodesWithoutDuplicatingAnAuthority() {
  let states = Set("AL AK AZ AR CA CO CT DE FL GA HI ID IL IN IA KS KY LA ME MD MA MI MN MS MO MT NE NV NH NJ NM NY NC ND OH OK OR PA RI SC SD TN TX UT VT VA WA WV WI WY DC GU VI".split(separator: " ").map(String.init))
  let resolved = (636000...636062).compactMap { AAMVAIssuerJurisdiction.resolve(String($0)) }
  #expect(Set(resolved) == states)
  #expect(resolved.count == states.count)
}

@Test func aamvaIssuerComparisonUsesHeaderDespiteDifferentAddressState() {
  // Jurisdiction comparison accepts an IIN only; neither a residence code nor the complete
  // document can accidentally become a lookup input for this API.
  #expect(AAMVAIssuerJurisdiction.resolve("636005") == "SC")
  #expect(AAMVAIssuerJurisdiction.resolve("DAJWA") == nil)
}
