#if os(iOS)
import CryptoKit
import Foundation
import OpenSSL
import XCTest
@testable import NFCPassportReader

/// Generated in-process keys and structural records only; no private key, identity or image asset is retained.
enum ReaderProtocolFixture {
    struct ProtectedTerminalVector {
        let accessAES: Bool
        let terminalAES: Bool
        let bodyDigests: [String]
        let replies: [String]
    }
    // Independently assembled with Python cryptography 49.0.0 AES-CBC/CMAC and
    // DES-EDE3/ISO9797-1 algorithm3; no Swift production helper supplies an oracle.
    // SSC=1,3,5 for commands and 2,4,6 for responses, initial SSC=0.
    static let protectedTerminalVectors: [ProtectedTerminalVector] = [
        .init(accessAES: false, terminalAES: false,
            bodyDigests: [
                "91d7a93f3bba1775066e69684622ae4c1c8125978e2a665ddb4a38f10b8dc75b"],
            replies: [
                "990290008e08341548c95f8e6f47"]),
        .init(accessAES: false, terminalAES: true,
            bodyDigests: [
                "14bab6bbf2a897845f137e72661f8c68e19e6ce86a67bc82858bc24b6ed30c76",
                "e0deda99e9cf23ebe7bc4badeb9187cf096ce71fa41ef3c2990b7341c4a8ef08",
                "9384cf91a0107f8e2c014354a700352e435917dfdd3b0425726d4c2582568433"],
            replies: [
                "990290008e08341548c95f8e6f47",
                "8709010e6851ecb34d95d1990290008e0813ad1d3a80703299",
                "8709010e6851ecb34d95d1990290008e08d38c355e3e7b8db8"]),
        .init(accessAES: true, terminalAES: false,
            bodyDigests: [
                "1305216efb5d0625bdf450a1a4517926bab52d42422979b279514d4dccf8fb63"],
            replies: [
                "990290008e08e03639b852d1be6f"]),
        .init(accessAES: true, terminalAES: true,
            bodyDigests: [
                "c7b683eea9be2f1de1ecfbc2d3b1090ff4051eacc5c3f977082bf171f039ed35",
                "f648dc661139c29202a6f4ca12102c211cb69719f8532954da57af649175de24",
                "024de952f7dabf2c48893174e2a3446e2ba018ff3c253f47497a928c730ce964"],
            replies: [
                "990290008e08e03639b852d1be6f",
                "871101cb2fc4e5e810ae83026436b707646cd5990290008e0861424b956eb0b059",
                "871101663a27e52ae01865d729639b69fd4e15990290008e0814f6f5745d0b6107"]),
    ]
    static func integer(_ value: Int, width: Int) -> [UInt8] {
        (0..<width).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }
    static func tlv(_ tag: [UInt8], _ body: [UInt8]) -> [UInt8] {
        let length = body.count < 128 ? [UInt8(body.count)] : [0x82] + integer(body.count, width: 2)
        return tag + length + body
    }
    static func dg2(_ record: [UInt8]) -> [UInt8] {
        tlv([0x75], tlv([0x7F, 0x61], [2, 1, 1]
            + tlv([0x7F, 0x60], [0xA1, 0] + tlv([0x5F, 0x2E], record))))
    }
    static func faceRecord(image: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0xFF, 0xD9]) -> [UInt8] {
        let face = integer(32 + image.count, width: 4) + Array(repeating: UInt8(0), count: 16)
            + [1, 0, 0, 12, 0, 8, 1, 0, 0, 0, 0, 0] + image
        return Array("FAC\0".utf8) + [0x30, 0x31, 0x30, 0] + integer(14 + face.count, width: 4) + [0, 1] + face
    }
    static func lifecycle(model: NFCPassportModel) -> PassportTagAttemptLifecycle {
        var value = PassportTagAttemptLifecycle()
        guard case .beginAttempt = value.handle(.tagDetected([])) else { preconditionFailure("Synthetic attempt admission failed") }
        value.attemptState?.passport = model
        return value
    }
    static func ecModel(key: P256.Signing.PrivateKey) -> NFCPassportModel {
        NFCPassportModel(from: ["DG15": Data(tlv([0x6F], Array(key.publicKey.derRepresentation))).base64EncodedString()])
    }
    static func caGroup() throws -> DataGroup14 {
        let key = P256.Signing.PrivateKey()
        let info = tlv([0x30], [6, 9, 4, 0, 0x7F, 0, 7, 2, 2, 1, 2] + Array(key.publicKey.derRepresentation))
        return try DataGroup14(tlv([0x6E], tlv([0x31], info)))
    }
    static func rsaKey(bits: Int32 = 1024) throws -> OpaquePointer {
        let rsa = try XCTUnwrap(RSA_new())
        defer { RSA_free(rsa) }
        let exponent = try XCTUnwrap(BN_new())
        defer { BN_free(exponent) }
        XCTAssertEqual(BN_set_word(exponent, 65537), 1)
        XCTAssertEqual(RSA_generate_key_ex(rsa, bits, exponent, nil), 1)
        let key = try XCTUnwrap(EVP_PKEY_new())
        guard EVP_PKEY_set1_RSA(key, rsa) == 1 else { EVP_PKEY_free(key); throw NFCPassportReaderError.UnexpectedError }
        return key
    }
    static func rsaModel(_ key: OpaquePointer) throws -> NFCPassportModel {
        let count = i2d_PUBKEY(key, nil)
        guard count > 0 else { throw NFCPassportReaderError.UnexpectedError }
        var der = Array(repeating: UInt8(0), count: Int(count))
        der.withUnsafeMutableBufferPointer { buffer in
            var pointer = buffer.baseAddress
            XCTAssertEqual(i2d_PUBKEY(key, &pointer), count)
        }
        return NFCPassportModel(from: ["DG15": Data(tlv([0x6F], der)).base64EncodedString()])
    }
    static func rsaSignature(key: OpaquePointer, recovered: [UInt8]) throws -> [UInt8] {
        let rsa = try XCTUnwrap(EVP_PKEY_get0_RSA(key))
        var signature = Array(repeating: UInt8(0), count: Int(RSA_size(rsa)))
        XCTAssertEqual(Int(RSA_private_encrypt(Int32(recovered.count), recovered, &signature, rsa, RSA_NO_PADDING)), signature.count)
        return signature
    }
    static func recoveredRSA(challenge: [UInt8], size: Int, sha256: Bool = false,
                             header: UInt8 = 0x6A, trailer: [UInt8]? = nil,
                             messageByte: UInt8 = 0x42) -> [UInt8] {
        let trailer: [UInt8] = trailer ?? (sha256 ? [0x34, 0xCC] : [0xBC])
        let digestLength = sha256 ? 32 : 20
        let message = Array(repeating: messageByte, count: size - 1 - digestLength - trailer.count)
        let data = Data(message + challenge)
        let digest = sha256 ? Array(SHA256.hash(data: data)) : Array(Insecure.SHA1.hash(data: data))
        return [header] + message + digest + trailer
    }
}
#endif
