//
//  BACHandler.swift
//  NFCTest
//
//  Created by Andy Qua on 07/06/2019.
//  Copyright © 2019 Andy Qua. All rights reserved.
//

import Foundation
import OSLog

#if !os(macOS)
import CoreNFC

@available(iOS 15, *)
public class BACHandler {
    let KENC : [UInt8] = [0,0,0,1]
    let KMAC : [UInt8] = [0,0,0,2]
    
    public var ksenc : [UInt8] = []
    public var ksmac : [UInt8] = []

    var rnd_icc : [UInt8] = []
    var rnd_ifd : [UInt8] = []
    public var kifd : [UInt8] = []
    
    var tagReader : TagReader?
    
    public init() {
        // Supports key-derivation callers without a connected transport.
    }
    
    public init(tagReader: TagReader) {
        self.tagReader = tagReader
    }

    public func performBACAndGetSessionKeys( mrzKey : String ) async throws {
        guard let tagReader = self.tagReader else {
            throw NFCPassportReaderError.NoConnectedTag
        }
        
        Logger.bac.debug( "BACHandler - deriving Document Basic Access Keys" )
        _ = try self.deriveDocumentBasicAccessKeys(mrz: mrzKey)
        
        // Reauthentication starts without the previous channel, including after a failed read.
        tagReader.secureMessaging = nil
        
        Logger.bac.debug( "BACHandler - Getting initial challenge" )
        let response = try await tagReader.getChallenge()
    
        
        Logger.bac.debug( "BACHandler - Doing mutual authentication" )
        guard response.data.count == 8 else { throw NFCPassportReaderError.InvalidResponseChecksum }
        let cmd_data = self.authentication(rnd_icc: [UInt8](response.data))
        let maResponse = try await tagReader.doMutualAuthentication(cmdData: Data(cmd_data))
        guard maResponse.data.count > 0 else {
            throw NFCPassportReaderError.InvalidMRZKey
        }
        
        // Do not install keys until the response MAC and both challenge nonces are verified.
        let (KSenc, KSmac, ssc) = try self.sessionKeys(data: [UInt8](maResponse.data))
        tagReader.secureMessaging = SecureMessaging(ksenc: KSenc, ksmac: KSmac, ssc: ssc)
        Logger.bac.debug( "BACHandler - complete" )
    }


    func deriveDocumentBasicAccessKeys(mrz: String) throws -> ([UInt8], [UInt8]) {
        let kseed = generateInitialKseed(kmrz:mrz)
    
        Logger.bac.debug("Calculate the Basic Access Keys (Kenc and Kmac) using TR-SAC 1.01, 4.2")
        let smskg = SecureMessagingSessionKeyGenerator()
        self.ksenc = try smskg.deriveKey(keySeed: kseed, mode: .ENC_MODE)
        self.ksmac = try smskg.deriveKey(keySeed: kseed, mode: .MAC_MODE)
                
        return (ksenc, ksmac)
    }
    
    /// Takes the first 16 bytes of the MRZ-information SHA-1 hash as the BAC key seed.
    func generateInitialKseed(kmrz : String ) -> [UInt8] {
        
        Logger.bac.debug("Calculate the SHA-1 hash of MRZ_information")
        let hash = calcSHA1Hash( [UInt8](kmrz.data(using:.utf8)!) )
        
        
        let subHash = Array(hash[0..<16])
        Logger.bac.debug("Take the most significant 16 bytes to form the Kseed")
        
        return Array(subHash)
    }
    
    
    /// Encrypts and authenticates RND.IFD || RND.ICC || K.IFD for mutual authentication.
    /// Retains the terminal nonce and key contribution for response binding and session derivation.
    /// - Parameter rnd_icc: The eight-byte chip challenge, validated by the caller.
    func authentication( rnd_icc : [UInt8]) -> [UInt8] {
        self.rnd_icc = rnd_icc
        
        Logger.bac.debug("Request an 8 byte random number from the MRTD's chip")
        
        self.rnd_icc = rnd_icc

        let rnd_ifd = generateRandomUInt8Array(8)
        let kifd = generateRandomUInt8Array(16)
        
        Logger.bac.debug("Generate an 8 byte random and a 16 byte random")
        
        let s = rnd_ifd + rnd_icc + kifd
        
        Logger.bac.debug("Concatenate RND.IFD, RND.ICC and Kifd")
        
        let iv : [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0]
        let eifd = tripleDESEncrypt(key: ksenc,message: s, iv: iv)
        
        Logger.bac.debug("Encrypt S with TDES key Kenc as calculated in Appendix 5.2")
        
        let mifd = mac(algoName: .DES, key: ksmac, msg: pad(eifd, blockSize:8))

        Logger.bac.debug("Compute MAC over eifd with TDES key Kmac as calculated in-Appendix 5.2")
        
        let cmd_data = eifd + mifd
        Logger.bac.debug("Construct command data for MUTUAL AUTHENTICATE")
        
        self.rnd_ifd = rnd_ifd
        self.kifd = kifd

        return cmd_data
    }
    
    /// Authenticates the chip response, binds it to this exchange, and derives the session keys.
    /// Returns expanded 3DES keys and the eight-byte send sequence counter.
    public func sessionKeys(data : [UInt8] ) throws -> ([UInt8], [UInt8], [UInt8]) {
        
        // BAC uses two-key 3DES expanded by the KDF to K1 || K2 || K1. Check both wire
        // lengths and retained state before slicing or combining any key material.
        guard data.count == 40, ksenc.count == 24, ksmac.count == 24,
              kifd.count == 16, rnd_icc.count == 8, rnd_ifd.count == 8 else {
            throw NFCPassportReaderError.InvalidResponseChecksum
        }
        let encrypted = Array(data.prefix(32))
        let expectedMAC = mac(algoName: .DES, key: ksmac, msg: pad(encrypted, blockSize: 8))
        let suppliedMAC = Array(data.suffix(8))
        // Authenticate ciphertext before decryption; compare every MAC byte without early exit.
        guard expectedMAC.count == suppliedMAC.count,
              zip(expectedMAC, suppliedMAC).reduce(UInt8(0), { $0 | ($1.0 ^ $1.1) }) == 0 else {
            throw NFCPassportReaderError.InvalidResponseChecksum
        }
        let response = tripleDESDecrypt(key: self.ksenc, message: encrypted, iv: [0,0,0,0,0,0,0,0])
        // The valid MAC must also bind the response to both nonces from this exact exchange.
        guard response.count == 32, Array(response.prefix(8)) == rnd_icc,
              Array(response[8..<16]) == rnd_ifd else {
            throw NFCPassportReaderError.InvalidResponseChecksum
        }

        let response_kicc = [UInt8](response[16..<32])
        let Kseed = xor(self.kifd, response_kicc)
        Logger.bac.debug("Calculate XOR of Kifd and Kicc")
        
        let smskg = SecureMessagingSessionKeyGenerator()
        let KSenc = try smskg.deriveKey(keySeed: Kseed, mode: .ENC_MODE)
        let KSmac = try smskg.deriveKey(keySeed: Kseed, mode: .MAC_MODE)

        
        Logger.bac.debug("Calculate Session Keys (KSenc and KSmac) using Appendix 5.1")
        
        
        let ssc = [UInt8](self.rnd_icc.suffix(4) + self.rnd_ifd.suffix(4))
        Logger.bac.debug("Calculate Send Sequence Counter")
        return (KSenc, KSmac, ssc)
    }
    
}
#endif
