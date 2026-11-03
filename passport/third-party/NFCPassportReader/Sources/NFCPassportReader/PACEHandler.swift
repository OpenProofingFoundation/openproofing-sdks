//
//  PACEHandler.swift
//  NFCPassportReader
//
//  Created by Andy Qua on 03/03/2021.
//

import Foundation
import OSLog
import OpenSSL
import CryptoTokenKit

#if !os(macOS)
import CoreNFC
import CryptoKit

@available(iOS 15, *)
private enum PACEHandlerError {
    case DHKeyAgreementError(String)
    case ECDHKeyAgreementError(String)
    
    var value: String {
        switch self {
            case .DHKeyAgreementError(let errMsg): return errMsg
            case .ECDHKeyAgreementError(let errMsg): return errMsg

        }
    }
}

@available(iOS 15, *)
extension PACEHandlerError: LocalizedError {
    public var errorDescription: String? {
        return NSLocalizedString(value, comment: "PACEHandlerError")
    }
}

@available(iOS 15, *)
public class PACEHandler {
    
    
    private static let MRZ_PACE_KEY_REFERENCE : UInt8 = 0x01
    private static let CAN_PACE_KEY_REFERENCE : UInt8 = 0x02 // Not currently supported
    private static let PIN_PACE_KEY_REFERENCE : UInt8 = 0x03 // Not currently supported
    private static let CUK_PACE_KEY_REFERENCE : UInt8 = 0x04 // Not currently supported

    /// Closed protocol stage retained by the reader when PACE falls back to BAC.
    public private(set) var stage = "parameters"
    var tagReader : TagReader
    var paceInfo : PACEInfo
    
    var isPACESupported : Bool = false
    var paceError : String = ""
    
    // Negotiated protocol parameters and transient password-derived key material.
    private var paceKey : [UInt8] = []
    private var paceKeyType : UInt8 = 0
    private var paceOID : String = ""
    private var parameterSpec : Int32 = -1
    private var mappingType : PACEMappingType!
    private var agreementAlg : String = ""
    private var cipherAlg : String = ""
    private var digestAlg : String = ""
    private var keyLength : Int = -1
    
    public init(cardAccess : CardAccess, tagReader: TagReader) throws {
        self.tagReader = tagReader
        
        // Only version 2 ECDH Generic Mapping is implemented end to end. Ignore unsupported
        // entries rather than allowing one to hide a later usable entry. IDs 8...18 are EC
        // domains; recognized finite-field IDs are not usable with ECDH.
        guard let pi = cardAccess.securityInfos.compactMap({ $0 as? PACEInfo }).first(where: {
            (try? $0.getMappingType()) == .GM && (try? $0.getKeyAgreementAlgorithm()) == "ECDH"
                && (8...18).contains($0.getParameterId() ?? -1)
                && (try? $0.getParameterSpec()) != nil && $0.getVersion() == 2
        }) else {
            throw NFCPassportReaderError.NotYetSupported( "PACE not supported" )
        }

        self.paceInfo = pi
        isPACESupported = true
    }
    
    public func doPACE( mrzKey : String ) async throws {
        guard isPACESupported else {
            throw NFCPassportReaderError.NotYetSupported( "PACE not supported" )
        }
        
        
        paceOID = paceInfo.getObjectIdentifier()
        parameterSpec = try paceInfo.getParameterSpec()
        
        mappingType = try paceInfo.getMappingType()  // Restricted to GM by initialization.
        agreementAlg = try paceInfo.getKeyAgreementAlgorithm()  // Restricted to ECDH by initialization.
        cipherAlg  = try paceInfo.getCipherAlgorithm()  // Either DESede or AES.
        digestAlg = try paceInfo.getDigestAlgorithm()  // Either SHA-1 or SHA-256.
        keyLength = try paceInfo.getKeyLength()  // Cipher key length in bits.

        paceKeyType = PACEHandler.MRZ_PACE_KEY_REFERENCE
        paceKey = try createPaceKey( from: mrzKey )
        

        // Select the advertised protocol and MRZ password reference before requesting its nonce.
        stage = "mseSetAT"
        _ = try await tagReader.sendMSESetATMutualAuth(oid: paceOID, keyType: paceKeyType)
            
        stage = "nonce"
        let decryptedNonce = try await self.doStep1()

        stage = "mapping"
        let ephemeralParams = try await self.doStep2(passportNonce: decryptedNonce)
        defer { EVP_PKEY_free( ephemeralParams ) }

        stage = "keyExchange"
        let (ephemeralKeyPair, passportPublicKey) = try await self.doStep3KeyExchange(ephemeralParams: ephemeralParams)
        defer { EVP_PKEY_free(ephemeralKeyPair); EVP_PKEY_free(passportPublicKey) }

        stage = "tokenVerification"
        let (encKey, macKey) = try await self.doStep4KeyAgreement( pcdKeyPair: ephemeralKeyPair, passportPublicKey: passportPublicKey)
        stage = "secureMessaging"
        try self.paceCompleted( ksEnc: encKey, ksMac: macKey )
        Logger.pace.debug("PACE SUCCESSFUL" )
    }
    
    /// Records an in-memory error description without logging protocol material.
    func handleError( _ stage: String, _ error: String, needToTerminateGA: Bool = false ) {
        self.paceError = "\(stage) - \(error)"
    }
    
    /// Decrypts the chip's nonce using the MRZ-derived PACE key.
    func doStep1() async throws -> [UInt8] {
        Logger.pace.debug("Doing PACE Step1...")
        let response = try await tagReader.sendGeneralAuthenticate(data: [], isLast: false)
            
        let data = response.data
        let encryptedNonce = try unwrapDO(tag: 0x80, wrappedData: data)
        // BSI TR-03110-3 A.3.3: a positive multiple of the selected cipher block size.
        let blockSize = cipherAlg == "AES" ? 16 : 8
        guard !encryptedNonce.isEmpty, encryptedNonce.count % blockSize == 0 else {
            throw NFCPassportReaderError.PACEError("nonce", "Invalid encrypted nonce length")
        }

        let decryptedNonce: [UInt8]
        if self.cipherAlg == "DESede" {
            let iv = [UInt8](repeating:0, count: 8)
            decryptedNonce = tripleDESDecrypt(key: self.paceKey, message: encryptedNonce, iv: iv)
        } else if self.cipherAlg == "AES" {
            let iv = [UInt8](repeating:0, count: 16)
            decryptedNonce = AESDecrypt(key: self.paceKey, message: encryptedNonce, iv: iv)
        } else {
            throw NFCPassportReaderError.UnsupportedCipherAlgorithm
        }

        guard decryptedNonce.count == encryptedNonce.count else {
            throw NFCPassportReaderError.PACEError("nonce", "Nonce decryption failed")
        }
        return decryptedNonce
    }
    
    
    /// Maps the decrypted nonce into ephemeral domain parameters. Initialization admits only GM.
    func doStep2( passportNonce: [UInt8]) async throws -> OpaquePointer {
        Logger.pace.debug( "Doing PACE Step2...")
        switch(mappingType) {
            case .CAM, .GM:
                Logger.pace.debug( "   Using General Mapping (GM)...")
                return try await doPACEStep2GM(passportNonce: passportNonce)
            case .IM:
                Logger.pace.debug( "   Using Integrated Mapping (IM)...")
                return try await doPACEStep2IM(passportNonce: passportNonce)
            default:
                throw NFCPassportReaderError.PACEError( "Step2GM", "Unsupported Mapping Type" )
        }

    }
    
    /// Exchanges mapping keys and combines their shared point with the chip nonce.
    /// The caller owns the returned EVP_PKEY and must free it.
    func doPACEStep2GM(passportNonce : [UInt8]) async throws -> OpaquePointer {
        
        let mappingKey : OpaquePointer
        mappingKey = try self.paceInfo.createMappingKey( )
        defer { EVP_PKEY_free(mappingKey) }

        guard let pcdMappingEncodedPublicKey = OpenSSLUtils.getPublicKeyData(from: mappingKey) else {
            throw NFCPassportReaderError.PACEError( "Step2GM", "Unable to get public key from mapping key")
        }

        Logger.pace.debug( "Sending public mapping key to passport..")
        let step2Data = wrapDO(b:0x81, arr:pcdMappingEncodedPublicKey)
        let response = try await tagReader.sendGeneralAuthenticate(data:step2Data, isLast:false)

        let piccMappingEncodedPublicKey = try unwrapDO(tag: 0x82, wrappedData: response.data)
            
        Logger.pace.debug( "Received passports public mapping key")

        // Do mapping agreement

        // First, Convert nonce to BIGNUM
        guard let bn_nonce = BN_bin2bn(passportNonce, Int32(passportNonce.count), nil) else {
            throw NFCPassportReaderError.PACEError( "Step2GM", "Unable to convert picc nonce to bignum" )
        }
        defer { BN_free(bn_nonce) }

        // Ownership transfers to doPACE, which frees these parameters after the exchange.
        let ephemeralParams : OpaquePointer
        if self.agreementAlg == "DH" {
            Logger.pace.debug( "Doing DH Mapping agreement")
            ephemeralParams = try self.doDHMappingAgreement(mappingKey: mappingKey, passportPublicKeyData: piccMappingEncodedPublicKey, nonce: bn_nonce )
        } else if self.agreementAlg == "ECDH" {
            Logger.pace.debug( "Doing ECDH Mapping agreement")
            ephemeralParams = try self.doECDHMappingAgreement(mappingKey: mappingKey, passportPublicKeyData: piccMappingEncodedPublicKey, nonce: bn_nonce )
        } else {
            throw NFCPassportReaderError.PACEError( "Step2GM", "Unsupported agreement algorithm" )
        }


        return ephemeralParams
    }
    
    func doPACEStep2IM( passportNonce: [UInt8] ) async throws -> OpaquePointer {
        // Unsupported by this reader; the initializer excludes IM before any APDU is sent.
        throw NFCPassportReaderError.PACEError( "Step2IM", "IM not yet implemented" )
    }
    
    /// Exchanges fresh keys on the mapped EC group. The caller owns both returned EVP_PKEYs.
    func doStep3KeyExchange(ephemeralParams: OpaquePointer) async throws -> (OpaquePointer, OpaquePointer) {
        Logger.pace.debug( "Doing PACE Step3 - Key Exchange")

        // Create a new EC_KEY with the same group
        guard let ephEcKey = EC_KEY_new() else {
            throw NFCPassportReaderError.PACEError( "Step3 KeyEx", "Failed to create EC key" )
        }
        defer { EC_KEY_free(ephEcKey) }

        guard
            let ecParams = EVP_PKEY_get0_EC_KEY(ephemeralParams),
            let group = EC_KEY_get0_group(ecParams),
            EC_KEY_set_group(ephEcKey, group) == 1,
            EC_KEY_generate_key(ephEcKey) == 1 else {
            throw NFCPassportReaderError.PACEError( "Step3 KeyEx", "Failed to generate EC key" )
        }

        // Wrap the EC_KEY into an EVP_PKEY
        var ephKeyPair = EVP_PKEY_new()
        guard let ephemeralKeyPair = ephKeyPair else {
            throw NFCPassportReaderError.PACEError( "Step3 KeyEx", "Unable to get create ephermeral key pair" )
        }
        defer { EVP_PKEY_free(ephKeyPair) }

        guard EVP_PKEY_set1_EC_KEY(ephemeralKeyPair, ephEcKey) == 1 else {
            throw NFCPassportReaderError.PACEError( "Step3 KeyEx", "Failed to set ephemeral key pair private key" )
        }
        
        Logger.pace.debug( "Generated Ephemeral key pair")

        guard let publicKey = OpenSSLUtils.getPublicKeyData( from: ephemeralKeyPair ) else {
            throw NFCPassportReaderError.PACEError( "Step3 KeyEx", "Unable to get public key from ephermeral key pair" )
        }

        // exchange public keys
        Logger.pace.debug( "Sending ephemeral public key to passport")
        let step3Data = wrapDO(b:0x83, arr:publicKey)
        let response = try await tagReader.sendGeneralAuthenticate(data:step3Data, isLast:false)
        let passportEncodedPublicKey = try unwrapDO(tag: 0x84, wrappedData: response.data)
        guard let passportPublicKey = OpenSSLUtils.decodePublicKeyFromBytes(pubKeyData: passportEncodedPublicKey, params: ephemeralKeyPair) else {
            throw NFCPassportReaderError.PACEError( "Step3 KeyEx", "Unable to decode passports ephemeral key" )
        }

        // The chip must contribute a distinct key; reflecting the terminal's key is not agreement.
        guard EVP_PKEY_eq(ephemeralKeyPair, passportPublicKey) == 0 else {
            EVP_PKEY_free(passportPublicKey)
            throw NFCPassportReaderError.PACEError("keyExchange", "Reflected or invalid public key")
        }
        defer { ephKeyPair = nil } // prevent free to return the value on success path
        return (ephemeralKeyPair, passportPublicKey)
    }
    
    /// Derives encryption/MAC keys from the shared secret and verifies the chip's token over
    /// the terminal public key. Keys are returned only after the peer proves possession.
    func doStep4KeyAgreement( pcdKeyPair: OpaquePointer, passportPublicKey: OpaquePointer) async throws -> ([UInt8], [UInt8]) {
        Logger.pace.debug( "Doing PACE Step4 Key Agreement...")

        Logger.pace.debug( "Computing shared secret...")
        let sharedSecret = OpenSSLUtils.computeSharedSecret(privateKeyPair: pcdKeyPair, publicKey: passportPublicKey)
        guard !sharedSecret.isEmpty else {
            throw NFCPassportReaderError.PACEError("tokenVerification", "Key agreement failed")
        }

        Logger.pace.debug( "Deriving ksEnc and ksMac keys from shared secret")
        let gen = SecureMessagingSessionKeyGenerator()
        let encKey = try gen.deriveKey(keySeed: sharedSecret, cipherAlgName: cipherAlg, keyLength: keyLength, mode: .ENC_MODE)
        let macKey = try gen.deriveKey(keySeed: sharedSecret, cipherAlgName: cipherAlg, keyLength: keyLength, mode: .MAC_MODE)

        // Step 4 - generate authentication token
        Logger.pace.debug( "Generating authentication token")
        guard let pcdAuthToken = try? generateAuthenticationToken( publicKey: passportPublicKey, macKey: macKey) else {
            throw NFCPassportReaderError.PACEError( "Step3 KeyAgreement", "Unable to generate authentication token using passports public key" )
        }

        Logger.pace.debug( "Sending auth token to passport")
        let step4Data = wrapDO(b:0x85, arr:pcdAuthToken)
        let response = try await tagReader.sendGeneralAuthenticate(data:step4Data, isLast:true)
            
        // GM returns exactly one eight-byte authentication token. Reject extra or truncated
        // records before comparing its value; malformed framing cannot establish a channel.
        guard let records = TKBERTLVRecord.sequenceOfRecords(from: Data(response.data)),
              records.count == 1, let token = records.first, token.tag == 0x86,
              token.data.count == response.data.count,
              token.value.count == 8 else {
            throw NFCPassportReaderError.PACEError("tokenVerification", "Malformed authentication token")
        }
        // Calculate expected authentication token
        let expectedPICCToken = try self.generateAuthenticationToken( publicKey: pcdKeyPair, macKey: macKey)
        

        let piccToken = [UInt8](token.value)

        guard piccToken == expectedPICCToken else {
            throw NFCPassportReaderError.PACEError( "Step3 KeyAgreement", "Authentication token mismatch" )
        }
        
        Logger.pace.debug( "Auth token from passport matches expected token!" )
        
        return (encKey, macKey)
    }
    
    /// Installs the authenticated channel with a zero initial send sequence counter.
    /// - Parameters:
    ///   - ksEnc: the computed encryption key derived from the key agreement
    ///   - ksMac: the computed mac key derived from the key agreement
    func paceCompleted( ksEnc: [UInt8], ksMac: [UInt8] ) throws {
        // Restart secure messaging
        let ssc = withUnsafeBytes(of: 0.bigEndian, Array.init)
        if (cipherAlg.hasPrefix("DESede")) {
            Logger.pace.info( "Restarting secure messaging using DESede encryption")
            let sm = SecureMessaging(encryptionAlgorithm: .DES, ksenc: ksEnc, ksmac: ksMac, ssc: ssc)
            tagReader.secureMessaging = sm
        } else if (cipherAlg.hasPrefix("AES")) {
            Logger.pace.info( "Restarting secure messaging using AES encryption")
            let sm = SecureMessaging(encryptionAlgorithm: .AES, ksenc: ksEnc, ksmac: ksMac, ssc: ssc)
            tagReader.secureMessaging = sm
        } else {
            throw NFCPassportReaderError.PACEError( "PACECompleted", "Not restarting secure messaging as unsupported cipher algorithm requested - \(cipherAlg)" )
        }
    }
}

// MARK: - Key agreement and encoding
@available(iOS 15, *)
extension PACEHandler {
    
    /// Finite-field Generic Mapping helper; the current initializer does not select DH.
    /// - Parameter mappingKey - Pointer to an EVP_PKEY structure containing the mapping key
    /// - Parameter passportPublicKeyData - byte array containing the public key read from the passport
    /// - Parameter nonce - Pointer to a BIGNUM structure containing the unencrypted nonce
    /// - Returns the EVP_PKEY containing the mapped ephemeral parameters
    func doDHMappingAgreement( mappingKey : OpaquePointer, passportPublicKeyData: [UInt8], nonce: OpaquePointer ) throws -> OpaquePointer {
        guard let dh_mapping_key = EVP_PKEY_get1_DH(mappingKey) else {

            throw PACEHandlerError.DHKeyAgreementError( "Unable to get DH mapping key" )
        }
        
        // Compute the shared secret using the mapping key and the passports public mapping key
        let bn = BN_bin2bn(passportPublicKeyData, Int32(passportPublicKeyData.count), nil)
        defer { BN_free( bn ) }
        
        var secret = [UInt8](repeating: 0, count: Int(DH_size(dh_mapping_key)))
        DH_compute_key( &secret, bn, dh_mapping_key)
        
        // Convert the secret to a bignum
        let bn_h = BN_bin2bn(secret, Int32(secret.count), nil)
        defer { BN_clear_free(bn_h) }
        
        // Initialize ephemeral parameters with parameters from the mapping key
        guard let ephemeral_key = DHparams_dup(dh_mapping_key) else {

            throw PACEHandlerError.DHKeyAgreementError("Unable to get initialise ephemeral parameters from DH mapping key")
        }
        defer{ DH_free(ephemeral_key) }
        
        var p : OpaquePointer? = nil
        var q : OpaquePointer? = nil
        var g : OpaquePointer? = nil
        DH_get0_pqg(dh_mapping_key, &p, &q, &g)
        
        // map to new generator
        guard let bn_g = BN_new() else {
            throw PACEHandlerError.DHKeyAgreementError( "Unable to create bn_g" )
        }
        defer{ BN_free(bn_g) }
        guard let new_g = BN_new() else {
            throw PACEHandlerError.DHKeyAgreementError( "Unable to create new_g" )
        }
        defer{ BN_free(new_g) }
        
        // bn_g = g^nonce mod p
        // ephemeral_key->g = bn_g mod p * h  => (g^nonce mod p) * h mod p
        let bn_ctx = BN_CTX_new()
        guard BN_mod_exp(bn_g, g, nonce, p, bn_ctx) == 1,
              BN_mod_mul(new_g, bn_g, bn_h, p, bn_ctx) == 1 else {

            throw PACEHandlerError.DHKeyAgreementError( "Failed to generate new parameters" )
        }
        
        guard DH_set0_pqg(ephemeral_key, BN_dup(p), BN_dup(q), BN_dup(new_g)) == 1 else {

            throw PACEHandlerError.DHKeyAgreementError( "Unable to set DH pqg paramerters" )
        }
        
        // Set the ephemeral params
        guard let ephemeralParams = EVP_PKEY_new() else {
            throw PACEHandlerError.ECDHKeyAgreementError( "Unable to create ephemeral params" )
        }

        guard EVP_PKEY_set1_DH(ephemeralParams, ephemeral_key) == 1 else {

            EVP_PKEY_free( ephemeralParams )
            throw PACEHandlerError.DHKeyAgreementError( "Unable to set ephemeral parameters" )
        }
        return ephemeralParams
    }
    
    /// Maps the chip nonce and shared EC point into the ephemeral group generator.
    /// - Parameter mappingKey - Pointer to an EVP_PKEY structure containing the mapping key
    /// - Parameter passportPublicKeyData - byte array containing the public key read from the passport
    /// - Parameter nonce - Pointer to a BIGNUM structure containing the unencrypted nonce
    /// - Returns the EVP_PKEY containing the mapped ephemeral parameters
    func doECDHMappingAgreement( mappingKey : OpaquePointer, passportPublicKeyData: [UInt8], nonce: OpaquePointer ) throws -> OpaquePointer {

        let ec_mapping_key = EVP_PKEY_get1_EC_KEY(mappingKey)
        defer { EC_KEY_free(ec_mapping_key) }
        
        guard let group = EC_GROUP_dup(EC_KEY_get0_group(ec_mapping_key)) else {

            throw PACEHandlerError.ECDHKeyAgreementError( "Unable to get EC group" )
        }
        defer { EC_GROUP_free(group) }
        
        guard let order = BN_new() else {

            throw PACEHandlerError.ECDHKeyAgreementError( "Unable to create order bignum" )
        }
        defer { BN_free( order ) }
        
        guard let cofactor = BN_new() else {

            throw PACEHandlerError.ECDHKeyAgreementError( "Unable to create cofactor bignum" )
        }
        defer { BN_free( cofactor ) }
        
        guard EC_GROUP_get_order(group, order, nil) == 1 &&
                EC_GROUP_get_cofactor(group, cofactor, nil) == 1 else {

            throw PACEHandlerError.ECDHKeyAgreementError( "Unable to get order or cofactor from group" )
        }
        
        // Create the shared secret in the form of a ECPoint

        // Generic Mapping needs the full shared EC point, not the x-coordinate byte string
        // returned by ordinary ECDH key derivation.
        guard let sharedSecretMappingPoint = self.computeECDHMappingKeyPoint(privateKey: mappingKey, inputKey: passportPublicKeyData) else {

            throw PACEHandlerError.ECDHKeyAgreementError( "Failed to compute new shared secret mapping point from mapping key and passport public mapping key" )
        }
        defer { EC_POINT_free( sharedSecretMappingPoint ) }

        // Map the nonce using Generic mapping to get the new parameters (inc a new generator)
        guard let newGenerater = EC_POINT_new(group) else {
            throw PACEHandlerError.ECDHKeyAgreementError( "Unable to create new mapping generator point" )
        }
        defer{ EC_POINT_free(newGenerater) }
        
        // g = (generator * nonce) + (sharedSecretMappingPoint * 1)
        guard EC_POINT_mul(group, newGenerater, nonce, sharedSecretMappingPoint, BN_value_one(), nil) == 1 else {
            throw PACEHandlerError.ECDHKeyAgreementError( "Failed to map nonce to get new generator params" )
        }
        
        // Initialize ephemeral parameters with parameters from the mapping key
        guard let ephemeralParams = EVP_PKEY_new() else {
            throw PACEHandlerError.ECDHKeyAgreementError( "Unable to create ephemeral params" )
        }

        let ephemeral_key = EC_KEY_dup(ec_mapping_key)
        defer{ EC_KEY_free(ephemeral_key) }
        
        // configure the new EC_KEY
        guard EVP_PKEY_set1_EC_KEY(ephemeralParams, ephemeral_key) == 1,
              EC_GROUP_set_generator(group, newGenerater, order, cofactor) == 1,
              EC_GROUP_check(group, nil) == 1,
              EC_KEY_set_group(ephemeral_key, group) == 1 else {


            EVP_PKEY_free( ephemeralParams )
            throw PACEHandlerError.ECDHKeyAgreementError( "Unable to configure new ephemeral params" )
        }
        return ephemeralParams
    }
    
    /// Generate Authentication token from a publicKey and and a mac key
    /// - Parameters:
    ///   - publicKey: An EVP_PKEY structure containing a public key data which will be used to generate the auth code
    ///   - macKey: The mac key derived from the key agreement
    /// - Throws: An error if we are unable to encode the public key data
    /// - Returns: The authentication token (8 bytes)
    func generateAuthenticationToken( publicKey: OpaquePointer, macKey: [UInt8] ) throws -> [UInt8] {
        var encodedPublicKeyData = try encodePublicKey(oid:self.paceOID, key:publicKey)
        
        if cipherAlg == "DESede" {
            // If DESede (3DES), we need to pad the data
            encodedPublicKeyData = pad(encodedPublicKeyData, blockSize: 8)
        }
        
        Logger.pace.debug( "Generating Authentication Token" )

        let maccedPublicKeyDataObject = mac(algoName: cipherAlg == "DESede" ? .DES : .AES, key: macKey, msg: encodedPublicKeyData)

        // Take 8 bytes for auth token
        let authToken = [UInt8](maccedPublicKeyDataObject[0..<8])
        return authToken
    }
    
    /// Encodes the public key and protocol OID as TLV for TR-SAC 1.01 4.5.1 and 4.5.2.
    /// - Parameters:
    ///   - oid: The object identifier specifying the key type
    ///   - key: The EVP_PKEY public key to encode
    /// - Throws: Error if unable to encode
    /// - Returns: the encoded public key in tlv format
    func encodePublicKey( oid : String, key : OpaquePointer ) throws -> [UInt8] {
        let encodedOid = oidToBytes(oid:oid, replaceTag: false)
        guard let pubKeyData = OpenSSLUtils.getPublicKeyData(from: key) else {
            Logger.pace.error( "PACEHandler: encodePublicKey() - Unable to get public key data" )
            throw NFCPassportReaderError.InvalidDataPassed("Unable to get public key data")
        }

        let keyType = EVP_PKEY_get_base_id( key )
        let tag : TKTLVTag
        if keyType == EVP_PKEY_DH || keyType == EVP_PKEY_DHX {
            tag = 0x84
        } else {
            tag = 0x86
        }

        guard let encOid = TKBERTLVRecord(from: Data(encodedOid)) else {
            throw NFCPassportReaderError.InvalidASN1Value
        }
        let encPub = TKBERTLVRecord(tag:tag, value: Data(pubKeyData))
        let record = TKBERTLVRecord(tag: 0x7F49, records:[encOid, encPub])
        let data = record.data

        return [UInt8](data)
    }

    /// Derives the password key from the MRZ hash using the negotiated cipher and key length.
    func createPaceKey( from mrzKey: String ) throws -> [UInt8] {
        let buf: [UInt8] = Array(mrzKey.utf8)
        let hash = calcSHA1Hash(buf)
        
        let smskg = SecureMessagingSessionKeyGenerator()
        let key = try smskg.deriveKey(keySeed: hash, cipherAlgName: cipherAlg, keyLength: keyLength, nonce: nil, mode: .PACE_MODE, paceKeyReference: paceKeyType)
        return key
    }
    
    /// Performs the ECDH PACE GM key agreement protocol by multiplying a private key with a public key
    /// - Parameters:
    ///   - privateKey: An EVP_PKEY containing an ECDH private key.
    ///   - inputKey: a public key
    /// - Returns: A new EC_POINT owned by the caller, or nil for an invalid peer point.
    func computeECDHMappingKeyPoint( privateKey : OpaquePointer, inputKey : [UInt8] ) -> OpaquePointer? {
        
        let ecdh = EVP_PKEY_get1_EC_KEY(privateKey)
        defer { EC_KEY_free(ecdh) }

        let privateECKey = EC_KEY_get0_private_key(ecdh) // BIGNUM

        // decode public key
        guard let group = EC_KEY_get0_group(ecdh) else{ return nil }
        guard let ecp = EC_POINT_new(group) else { return nil }
        defer { EC_POINT_free(ecp) }
        // A valid peer point must be on the negotiated curve and cannot be its identity element.
        guard EC_POINT_oct2point(group, ecp, inputKey, inputKey.count,nil) == 1,
              EC_POINT_is_at_infinity(group, ecp) == 0,
              EC_POINT_is_on_curve(group, ecp, nil) == 1 else { return nil }
                
        // create our output point
        let output = EC_POINT_new(group)

        // Multiply our private key with the passports public key to get a new point
        guard EC_POINT_mul(group, output, nil, ecp, privateECKey, nil) == 1,
              EC_POINT_is_at_infinity(group, output) == 0 else {
            EC_POINT_free(output)
            return nil
        }
        
        return output
    }
}

#endif
