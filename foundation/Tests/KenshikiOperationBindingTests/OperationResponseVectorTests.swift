import Foundation
import XCTest
@testable import KenshikiOperationBinding

final class OperationResponseVectorTests: XCTestCase {
    func testFlatAndWrappedWireHashTheExactSameInnerResult() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("contracts/operation-response-v1.vectors.json"))
        let fixture = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        func bytes(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) }
        let operation = try JSONDecoder().decode(SealedOperation.self, from: bytes(fixture["operation"]!))
        let canonical = Data((fixture["resultCanonical"] as! String).utf8)
        let wrapped = fixture["wrapped"] as! [String: Any]
        var flat = fixture["flat"] as! [String: Any]
        let flatReceipt = flat.removeValue(forKey: "receipt")!
        XCTAssertEqual(try bytes(flat), canonical)
        XCTAssertEqual(try bytes(wrapped["result"]!), canonical)
        XCTAssertEqual(try bytes(flatReceipt), try bytes(wrapped["receipt"]!))
        let receipt = try JSONDecoder().decode(OperationReceipt.self, from: bytes(flatReceipt))
        try receipt.validate(for: operation, canonicalResult: canonical, now: operation.issuedAt)
        XCTAssertThrowsError(try receipt.validate(for: operation, canonicalResult: bytes(["result": wrapped["result"]!]), now: operation.issuedAt))
        try receipt.validatePreviouslyAccepted(for: operation, canonicalResult: canonical)
    }
}
