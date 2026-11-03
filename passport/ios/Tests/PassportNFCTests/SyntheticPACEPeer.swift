#if os(iOS)
import CoreNFC
import Foundation
import OpenSSL
import XCTest
@testable import NFCPassportReader

/// Synthetic chip-side exchange using real ECDH and MAC operations. No passport data, NFC,
/// network, fixed terminal randomness, or bypass of production token verification.
final class SyntheticPACEPeer {
    enum Mode { case valid, wrongToken, malformedToken, malformedKey }
    let mode: Mode
    let nonce = [UInt8](repeating: 0x42, count: 16)
    var step = 0
    var key: OpaquePointer?
    var expectedTerminalToken: [UInt8] = []
    var chipToken: [UInt8] = []
    let oid = "0.4.0.127.0.7.2.2.4.2.2"
    init(_ mode: Mode) { self.mode = mode }
    deinit { EVP_PKEY_free(key) }

    func exchange(_ command: NFCISO7816APDU) async throws -> (Data, UInt8, UInt8) {
        if command.instructionCode == 0x22 { return (Data(), 0x90, 0) }
        XCTAssertEqual(command.instructionCode, 0x86)
        XCTAssertEqual(command.instructionClass, step == 3 ? 0 : 0x10)
        let incoming = try unwrapDO(tag: 0x7C, wrappedData: Array(command.data ?? Data()))
        let outgoing: [UInt8]
        switch step {
        case 0:
            XCTAssertTrue(incoming.isEmpty)
            let password = try SecureMessagingSessionKeyGenerator().deriveKey(
                keySeed: calcSHA1Hash(Array("synthetic".utf8)), cipherAlgName: "AES", keyLength: 128,
                nonce: nil, mode: .PACE_MODE, paceKeyReference: 1)
            outgoing = wrapDO(b: 0x80, arr: AESEncrypt(key: password, message: nonce, iv: Array(repeating: 0, count: 16)))
        case 1:
            let info = PACEInfo(oid: oid, version: 2, parameterId: 13)
            let mappingKey = try info.createMappingKey()
            defer { EVP_PKEY_free(mappingKey) }
            let terminalMapping = try unwrapDO(tag: 0x81, wrappedData: incoming)
            let helper = try PACEHandler(cardAccess: syntheticCardAccess(), tagReader: TagReader { _ in
                XCTFail("Peer helper must not send"); return (Data(), 0x90, 0)
            })
            let scalar = try XCTUnwrap(BN_bin2bn(nonce, Int32(nonce.count), nil))
            defer { BN_free(scalar) }
            let params = try helper.doECDHMappingAgreement(mappingKey: mappingKey, passportPublicKeyData: terminalMapping, nonce: scalar)
            defer { EVP_PKEY_free(params) }
            let ec = try XCTUnwrap(EC_KEY_new())
            defer { EC_KEY_free(ec) }
            let paramEC = try XCTUnwrap(EVP_PKEY_get0_EC_KEY(params))
            XCTAssertEqual(EC_KEY_set_group(ec, EC_KEY_get0_group(paramEC)), 1)
            XCTAssertEqual(EC_KEY_generate_key(ec), 1)
            key = try XCTUnwrap(EVP_PKEY_new())
            XCTAssertEqual(EVP_PKEY_set1_EC_KEY(key, ec), 1)
            outgoing = wrapDO(b: 0x82, arr: try XCTUnwrap(OpenSSLUtils.getPublicKeyData(from: mappingKey)))
        case 2:
            let terminalBytes = try unwrapDO(tag: 0x83, wrappedData: incoming)
            let pair = try XCTUnwrap(key)
            let terminal = try XCTUnwrap(OpenSSLUtils.decodePublicKeyFromBytes(pubKeyData: terminalBytes, params: pair))
            defer { EVP_PKEY_free(terminal) }
            let secret = OpenSSLUtils.computeSharedSecret(privateKeyPair: pair, publicKey: terminal)
            let macKey = try SecureMessagingSessionKeyGenerator().deriveKey(
                keySeed: secret, cipherAlgName: "AES", keyLength: 128, mode: .MAC_MODE)
            let helper = try PACEHandler(cardAccess: syntheticCardAccess(), tagReader: TagReader { _ in
                XCTFail("Peer helper must not send"); return (Data(), 0x90, 0)
            })
            expectedTerminalToken = Array(mac(algoName: .AES, key: macKey,
                msg: try helper.encodePublicKey(oid: oid, key: pair)).prefix(8))
            chipToken = Array(mac(algoName: .AES, key: macKey,
                msg: try helper.encodePublicKey(oid: oid, key: terminal)).prefix(8))
            outgoing = mode == .malformedKey ? [0x84, 0x02, 0x01] :
                wrapDO(b: 0x84, arr: try XCTUnwrap(OpenSSLUtils.getPublicKeyData(from: pair)))
        case 3:
            XCTAssertEqual(try unwrapDO(tag: 0x85, wrappedData: incoming), expectedTerminalToken)
            if mode == .wrongToken { chipToken[0] ^= 1 }
            outgoing = mode == .malformedToken ? [] : wrapDO(b: 0x86, arr: chipToken)
        default:
            XCTFail("Unexpected exchange after completion"); throw NFCPassportReaderError.UnexpectedError
        }
        step += 1
        return (Data(wrapDO(b: 0x7C, arr: outgoing)), 0x90, 0)
    }
}

#endif
