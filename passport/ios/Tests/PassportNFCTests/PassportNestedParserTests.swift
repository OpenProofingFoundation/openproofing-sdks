#if os(iOS)
import Foundation
import XCTest
@testable import NFCPassportReader

final class PassportNestedParserTests: XCTestCase {
    func testNestedCursorRejectsTruncatedTagAndEscapingValue() throws {
        for bytes: [UInt8] in [[0x63, 1, 0x5F], [0x63, 3, 0x5F, 0x1F, 2]] {
            let group = try DataGroup(bytes)
            XCTAssertThrowsError(try { _ = try group.getNextTag(); _ = try group.getNextValue() }())
        }
        let group = try DataGroup([0x63, 7, 0xA1, 3, 2, 2, 1, 4, 0])
        XCTAssertEqual(try group.getNextTag(), 0xA1)
        XCTAssertEqual(try group.getNextLength(), 3)
        XCTAssertEqual(try group.getNextTag(), 2)
        XCTAssertThrowsError(try group.getNextValue(), "A child cannot borrow bytes from its parent's next sibling")
    }

    func testDG1RefusesUnsupportedMRZLengthsAndPreservesSupportedFormats() throws {
        for count in [0, 1, 71, 73, 87, 89, 91] {
            let bytes = ReaderProtocolFixture.tlv([0x61], ReaderProtocolFixture.tlv([0x5F, 0x1F], Array(repeating: 0x41, count: count)))
            XCTAssertThrowsError(try DataGroupParser().parseDG(data: bytes)) {
                guard case NFCPassportReaderError.InvalidASN1Value = $0 else { return XCTFail("Unexpected MRZ bounds failure") }
            }
        }
        for count in [72, 88, 90] {
            let mrz = Array(repeating: UInt8(0x41), count: count)
            let bytes = ReaderProtocolFixture.tlv([0x61], ReaderProtocolFixture.tlv([0x5F, 0x1F], mrz))
            let group = try XCTUnwrap(DataGroupParser().parseDG(data: bytes) as? DataGroup1)
            XCTAssertEqual(group.elements["5F1F"], String(bytes: mrz, encoding: .utf8))
            XCTAssertEqual(group.data, bytes)
        }
    }

    func testDG2RejectsEmptyCountAndEveryTruncatedFacialHeader() {
        XCTAssertThrowsError(try DataGroupParser().parseDG(data: [0x75, 5, 0x7F, 0x61, 2, 2, 0]))
        let valid = ReaderProtocolFixture.faceRecord()
        for end in 0..<46 {
            XCTAssertThrowsError(try DataGroupParser().parseDG(data: ReaderProtocolFixture.dg2(Array(valid.prefix(end)))))
        }
    }

    func testDG2RejectsEachWrongMagicByteAndImpossibleRecordOffsets() {
        let valid = ReaderProtocolFixture.faceRecord()
        for index in 0..<4 {
            var record = valid; record[index] ^= 1
            XCTAssertThrowsError(try DataGroupParser().parseDG(data: ReaderProtocolFixture.dg2(record)))
        }
        for range in [8..<12, 14..<18, 18..<20] {
            var record = valid
            for index in range { record[index] = 0xFF }
            XCTAssertThrowsError(try DataGroupParser().parseDG(data: ReaderProtocolFixture.dg2(record)))
        }
        let image: [UInt8] = [0, 0, 0, 12, 0x6A, 0x50, 0x20, 0x20, 13, 10, 0x87, 10]
            + [0, 0, 0, 1, 0x6A, 0x70, 0x32, 0x63] + Array(repeating: 0xFF, count: 8)
        XCTAssertThrowsError(try DataGroupParser().parseDG(data: ReaderProtocolFixture.dg2(ReaderProtocolFixture.faceRecord(image: image))))
    }

    func testDG14IgnoresIncompleteSecurityInfoWithoutDereferencingMissingChild() throws {
        let group = try DataGroup14(ReaderProtocolFixture.tlv([0x6E], [0x31, 2, 0x30, 0]))
        XCTAssertEqual(group.securityInfos.count, 0)
    }

    func testSODWithoutCertificatesThrowsInsteadOfIndexingEmptySignerList() throws {
        let oid = [UInt8]([6, 9, 0x2A, 0x86, 0x48, 0x86, 0xF7, 13, 1, 7])
        let signed = ReaderProtocolFixture.tlv([0x30], [2, 1, 1, 0x31, 0]
            + ReaderProtocolFixture.tlv([0x30], oid + [1]) + [0x31, 0])
        let cms = ReaderProtocolFixture.tlv([0x30], oid + [2] + ReaderProtocolFixture.tlv([0xA0], signed))
        XCTAssertEqual(try OpenSSLUtils.getX509CertificatesFromPKCS7(pkcs7Der: Data(cms)).count, 0)
        let group = try SOD(ReaderProtocolFixture.tlv([0x77], cms))
        XCTAssertThrowsError(try group.getPublicKey())
    }
}
#endif
