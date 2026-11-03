import Foundation
import XCTest
@testable import KenshikiOperationBinding

final class CanonicalJSONTests: XCTestCase {
    private func canonical(_ text: String) throws -> String {
        String(decoding: try CanonicalJSON.canonicalize(Data(text.utf8)), as: UTF8.self)
    }
    func testActualFoundationNumericProbeMatchesWorker() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("contracts/canonical-number-v1.vectors.json")
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        for row in fixture["cases"] as! [[String: String]] {
            XCTAssertEqual(try canonical(row["foundationCanonical"]!), row["workerCanonical"]!)
            let object = try JSONSerialization.jsonObject(with: Data(row["foundationCanonical"]!.utf8))
            XCTAssertEqual(String(decoding: try CanonicalJSON.data(withJSONObject: object), as: UTF8.self), row["workerCanonical"]!)
        }
    }
    func testRFC8785AppendixBIEEE754Goldens() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("contracts/canonical-number-v1.vectors.json")
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        let rows = fixture["rfc8785AppendixB"] as! [[String: Any]]
        XCTAssertEqual(rows.count, 26)
        for row in rows {
            let value = Double(bitPattern: UInt64(row["ieee754"] as! String, radix: 16)!)
            if let expected = row["json"] as? String {
                XCTAssertEqual(String(decoding: try CanonicalJSON.data(withJSONObject: [value]), as: UTF8.self), "["+expected+"]")
            } else { XCTAssertThrowsError(try CanonicalJSON.data(withJSONObject: [value])) }
        }
    }
    func testRFC8785NumbersAndUTF16PropertyOrder() throws {
        XCTAssertEqual(try canonical("[333333333.33333329,1E30,4.50,2e-3,0.000000000000000000000000001]"),
            "[333333333.3333333,1e+30,4.5,0.002,1e-27]")
        XCTAssertEqual(try canonical("{\"2\":0,\"10\":0,\"😀\":0,\"דּ\":0,\"€\":0,\"ö\":0,\"1\":0,\"\\r\":0}"),
            "{\"\\r\":0,\"1\":0,\"10\":0,\"2\":0,\"ö\":0,\"€\":0,\"😀\":0,\"דּ\":0}")
        XCTAssertEqual(try canonical("[-0,0.0,1.0,1e-6,1e-7,1e20,1e21]"),
            "[0,0,1,0.000001,1e-7,100000000000000000000,1e+21]")
    }
    func testRejectsInvalidNonFiniteDuplicateAndSurrogateValues() throws {
        for text in ["[1e999]", "{\"a\":1,\"a\":2}", "{\"a\":1,\"\\u0061\":2}", "[\"\\ud800\"]", "{\"\\udc00\":1}", "NaN", "{} trailing"] {
            XCTAssertThrowsError(try canonical(text), text)
        }
        XCTAssertThrowsError(try CanonicalJSON.data(withJSONObject: ["number": Double.infinity]))
        XCTAssertThrowsError(try CanonicalJSON.data(withJSONObject: ["number": Double.nan]))
    }
    func testStringsEscapesNestedObjectsAndNoNormalization() throws {
        XCTAssertEqual(try canonical("{\"z\":[{\"b\":true,\"a\":null}],\"x\":\"e\\u0301/\\n\\\\\\\"\"}"),
            "{\"x\":\"é/\\n\\\\\\\"\",\"z\":[{\"a\":null,\"b\":true}]}")
        XCTAssertThrowsError(try canonical(String(repeating: "[", count: 130)+"0"+String(repeating: "]", count: 130)))
    }
}
