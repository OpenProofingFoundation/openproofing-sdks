import Foundation

/// The holder's names as the identity subfile's elements carry them, across AAMVA DL/ID generations:
/// DAB/DAC or comma-positioned DAA in 2000; DCS/DCT in 2003/2005; DCS/DAC thereafter.
/// https://github.com/ksoftllc/license-parser/tree/55803fd6c4a39724a06725b3be31aa37b2d450ff
///
/// Ported from Pulse iOS AAMVAIdentityNames (removed from the app in 68f4fc7c), with the same
/// elements, placeholders and DAA slots. It now names the element each reading came from, so a
/// caller can apply that element's truncation flag, and it reports which part conflicts instead of
/// refusing every part. Conflicting representations still cannot select different people: a
/// conflicting part has no single reading for a caller to use.
public struct AAMVAIdentityNames: Equatable, Sendable {
  public enum Part: String, CaseIterable, Sendable { case family, given, middle }

  /// A trimmed, non-placeholder value and the element it was read from.
  public struct Reading: Equatable, Sendable {
    public let value: String
    public let element: String
  }

  /// Every reading of each part, in element precedence: family DCS, DAB, DAA; given DAC, DCT, DAA;
  /// middle DAD, DCT, DAA. A part with no reading is absent.
  public let readings: [Part: [Reading]]

  public init(_ elements: [String: String]) {
    var readings: [Part: [Reading]] = [:]
    func add(_ part: Part, _ element: String, _ raw: String?) {
      if let value = Self.value(raw) { readings[part, default: []].append(Reading(value: value, element: element)) }
    }
    add(.given, "DAC", elements["DAC"])
    add(.family, "DCS", elements["DCS"])
    add(.family, "DAB", elements["DAB"])
    add(.middle, "DAD", elements["DAD"])
    if let combined = Self.value(elements["DCT"]) {
      let parts = combined.components(separatedBy: ",")
      add(.given, "DCT", parts[0])
      add(.middle, "DCT", parts.dropFirst().joined(separator: ","))
    }
    if let combined = Self.value(elements["DAA"]) {
      let parts = combined.components(separatedBy: ",")
      // Empty positions matter: LAST,FIRST,,JR has a suffix and no middle name.
      if (2...4).contains(parts.count) {
        add(.family, "DAA", parts[0])
        add(.given, "DAA", parts[1])
        if parts.count > 2 { add(.middle, "DAA", parts[2]) }
      }
    }
    self.readings = readings
  }

  /// The part's reading when every representation agrees; nil when it has none or they conflict.
  public func reading(_ part: Part) -> Reading? {
    guard let first = readings[part]?.first, !conflicts(part) else { return nil }
    return first
  }

  /// Whether two representations of the part carry different values.
  public func conflicts(_ part: Part) -> Bool {
    guard let values = readings[part]?.map(\.value), let first = values.first else { return false }
    return values.contains { $0 != first }
  }

  private static func value(_ raw: String?) -> String? {
    guard let value = raw?.trimmingCharacters(in: .whitespaces), !value.isEmpty,
      !["NONE", "UNAVL", "UNAVAIL"].contains(value.uppercased())
    else { return nil }
    return value
  }
}
