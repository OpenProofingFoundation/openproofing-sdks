import Foundation

struct ManifestField: CodingKey {
  let stringValue: String
  let intValue: Int? = nil
  init?(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { return nil }
}

func requireManifestFields(_ decoder: Decoder, required: Set<String>, optional: Set<String> = []) throws {
  let fields = Set(try decoder.container(keyedBy: ManifestField.self).allKeys.map(\.stringValue))
  guard required.isSubset(of: fields), fields.isSubset(of: required.union(optional))
  else { throw EvidenceManifestError.invalidManifest }
}
