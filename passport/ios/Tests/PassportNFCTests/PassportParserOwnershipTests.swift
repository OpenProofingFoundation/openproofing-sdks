#if os(iOS)
import Foundation
import OpenSSL
import XCTest
@testable import NFCPassportReader

final class PassportParserOwnershipTests: XCTestCase {
    func testShortAndTruncatedDataGroupEnvelopesThrowBeforeDispatch() {
        let malformed: [(bytes: [UInt8], invalidEnvelope: Bool)] = [
            ([], true), ([0x63], false), ([0x63, 0x81], false),
            ([0x63, 0x82], false), ([0x63, 0x82, 0x01], false),
            ([0x63, 0x01], true), ([0x63, 0x02, 0x00], true), ([0x63, 0x81, 0x01], true),
            ([0x63, 0x82, 0x01, 0x00], true), ([0x63, 0x80], false), ([0x63, 0x83, 0x00, 0x00], false),
        ]
        for vector in malformed {
            XCTAssertThrowsError(try DataGroupParser().parseDG(data: vector.bytes), "Accepted truncated outer TLV: \(vector.bytes)") {
                switch $0 {
                case NFCPassportReaderError.InvalidASN1Value: XCTAssertTrue(vector.invalidEnvelope)
                case NFCPassportReaderError.CannotDecodeASN1Length: XCTAssertFalse(vector.invalidEnvelope)
                default: XCTFail("Unexpected outer TLV error: \($0)")
                }
            }
        }
    }

    func testValidShortDataGroupEnvelopesPreserveOriginalBytes() throws {
        // DG3 is deliberately opaque to this reader, so no inner parser is involved.
        for body: [UInt8] in [[], [0x01], [0x01, 0x02]] {
            let bytes = [0x63, UInt8(body.count)] + body
            let group = try DataGroupParser().parseDG(data: bytes)
            XCTAssertTrue(group is NotImplementedDG)
            XCTAssertEqual(group.data, bytes)
            XCTAssertEqual(group.body, body)
        }
        XCTAssertThrowsError(try DataGroupParser().parseDG(data: [0xFF, 0x00])) {
            guard case NFCPassportReaderError.UnknownTag = $0 else { return XCTFail("Unexpected tag error: \($0)") }
        }
    }

    func testChipAuthenticationPublicKeyOwnerReleasesExactlyItsOpenSSLReference() throws {
        let index = CRYPTO_get_ex_new_index(CRYPTO_EX_INDEX_EVP_PKEY, 0, nil, nil, nil,
            { _, pointer, _, _, _, _ in
                pointer?.assumingMemoryBound(to: Int.self).pointee += 1
            })
        XCTAssertGreaterThanOrEqual(index, 0)
        guard index >= 0 else { return }
        for retainExternalReference in [false, true] {
            let released = UnsafeMutablePointer<Int>.allocate(capacity: 1)
            released.initialize(to: 0)
            defer { released.deinitialize(count: 1); released.deallocate() }
            let key = try XCTUnwrap(EVP_PKEY_new())
            guard EVP_PKEY_set_ex_data(key, index, released) == 1 else {
                EVP_PKEY_free(key); XCTFail("Cannot attach the release observer"); return
            }
            if retainExternalReference, EVP_PKEY_up_ref(key) != 1 {
                EVP_PKEY_free(key); XCTFail("Cannot retain the external OpenSSL reference"); return
            }
            var owner: ChipAuthenticationPublicKeyInfo? = .init(oid: SecurityInfo.ID_PK_ECDH_OID, pubKey: key)
            weak var observed = owner
            withExtendedLifetime(owner) { XCTAssertEqual(released.pointee, 0) }
            owner = nil
            XCTAssertNil(observed)
            XCTAssertEqual(released.pointee, retainExternalReference ? 0 : 1,
                "Releasing the Swift owner must release exactly its one OpenSSL reference")
            if retainExternalReference { EVP_PKEY_free(key) }
            XCTAssertEqual(released.pointee, 1)
            // A failed pre-fix assertion must not leave the synthetic key allocated.
            if released.pointee == 0 { EVP_PKEY_free(key) }
        }
    }
}
#endif
