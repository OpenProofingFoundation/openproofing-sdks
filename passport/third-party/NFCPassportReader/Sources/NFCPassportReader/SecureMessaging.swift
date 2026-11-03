//
//  SecureMessaging.swift
//  NFCTest
//
//  Created by Andy Qua on 09/06/2019.
//  Copyright © 2019 Andy Qua. All rights reserved.
//

import Foundation
import OSLog

public enum SecureMessagingSupportedAlgorithms {
    case DES
    case AES
}

#if !os(macOS)
import CoreNFC


/// This class implements the secure messaging protocol.
/// The class is a new layer that comes between the reader and the iso7816.
/// It gives a new transmit method that takes an APDU object formed by the iso7816 layer,
/// ciphers it following the doc9303 specification, sends the ciphered APDU to the reader
/// layer and returns the unciphered APDU.
@available(iOS 13, *)
public class SecureMessaging {
    private var ksenc : [UInt8]
    private var ksmac : [UInt8]
    private var ssc : [UInt8]
    private let algoName : SecureMessagingSupportedAlgorithms
    private let padLength : Int
        
    public init( encryptionAlgorithm : SecureMessagingSupportedAlgorithms = .DES, ksenc : [UInt8], ksmac : [UInt8], ssc : [UInt8]) {
        self.ksenc = ksenc
        self.ksmac = ksmac
        self.ssc = ssc
        self.algoName = encryptionAlgorithm
        self.padLength = algoName == .DES ? 8 : 16
    }

    /// Protect the apdu following the doc9303 specification
    func protect(apdu : NFCISO7816APDU, useExtendedMode: Bool = false ) throws -> NFCISO7816APDU {
    
        self.ssc = self.incSSC()
        let paddedSSC = algoName == .DES ? self.ssc : [UInt8](repeating: 0, count: 8) + ssc
        Logger.secureMessaging.debug("\tIncrement SSC with 1")


        let cmdHeader = self.maskClassAndPad(apdu: apdu)
        var do87 : [UInt8] = []
        var do97 : [UInt8] = []
        
        var tmp = "Concatenate CmdHeader"
        if apdu.data != nil {
            tmp += " and DO87"
            do87 = try self.buildD087(apdu: apdu)
        }
        
        let isMSE = apdu.instructionCode == 0x22
        if apdu.expectedResponseLength > 0 && (isMSE ? apdu.expectedResponseLength < 256 : true) {
            tmp += " and DO97"
            do97 = try self.buildD097(apdu: apdu)
        }
        
        let M = cmdHeader + do87 + do97
        
        Logger.secureMessaging.debug("Compute MAC of M")
        
        let N = pad(paddedSSC + M, blockSize:padLength)
        Logger.secureMessaging.debug("\tConcatenate SSC and M and add padding")

        var CC = mac(algoName: algoName, key: self.ksmac, msg: N)
        if CC.count > 8 {
            CC = [UInt8](CC[0..<8])
        }
        Logger.secureMessaging.debug("\tCompute MAC over N with KSmac")
        
        let do8e = self.buildD08E(mac: CC)
        
        // If dataSize > 255 then it will be encoded in 3 bytes with the first byte being 0x00
        // otherwise its a single byte of size
        let size = do87.count + do97.count + do8e.count
        var dataSize: [UInt8]
        if size > 255 || (useExtendedMode && apdu.expectedResponseLength > 231) {
            dataSize = [0x00] + intToBin(size, pad: 4)
        } else {
            dataSize = intToBin(size)
        }
        var protectedAPDU = [UInt8](cmdHeader[0..<4]) + dataSize
        protectedAPDU += do87 + do97 + do8e
            
        // If the data is more that 255, specify the we are using extended length (0x00, 0x00)
        // Thanks to @filom for the fix!
        if size > 255 || (useExtendedMode && apdu.expectedResponseLength > 231) {
            protectedAPDU += [0x00,0x00]
        } else {
            protectedAPDU += [0x00]
        }
        Logger.secureMessaging.debug("Construct and send protected APDU")
        
        let newAPDU = NFCISO7816APDU(data:Data(protectedAPDU))!
        return newAPDU
    }

    /// Unprotect the APDU following the iso7816 specification
    func unprotect(rapdu : ResponseAPDU ) throws -> ResponseAPDU {
        // KENSHIKI OSS PATCH: bounded response framing and verification of the computed MAC.
        // A transport error is returned as an error status, never treated as protected success.
        self.ssc = self.incSSC()
        guard rapdu.sw1 == 0x90, rapdu.sw2 == 0x00 else { return rapdu }
        let paddedSSC = algoName == .DES ? self.ssc : [UInt8](repeating: 0, count: 8) + ssc
        let bytes = rapdu.data
        var offset = 0
        var do87: [UInt8] = []
        var do87Data: [UInt8] = []
        if bytes.first == 0x87 {
            let (length, lengthBytes) = try asn1Length(Array(bytes.dropFirst()))
            let headerLength = 1 + lengthBytes
            guard length > 1, headerLength <= bytes.count,
                  length <= bytes.count - headerLength,
                  bytes[headerLength] == 0x01 else {
                throw NFCPassportReaderError.D087Malformed
            }
            offset = headerLength + length
            do87 = Array(bytes[..<offset])
            do87Data = Array(bytes[(headerLength + 1)..<offset])
            let blockSize = algoName == .DES ? 8 : 16
            guard do87Data.count % blockSize == 0 else {
                throw NFCPassportReaderError.D087Malformed
            }
        }
        guard offset <= bytes.count, bytes.count - offset >= 4,
              bytes[offset] == 0x99, bytes[offset + 1] == 0x02 else {
            throw NFCPassportReaderError.MissingMandatoryFields
        }
        let do99 = Array(bytes[offset..<(offset + 4)])
        let sw1 = bytes[offset + 2]
        let sw2 = bytes[offset + 3]
        offset += 4
        // Both supported secure-messaging profiles use exactly eight wire MAC bytes.
        guard bytes.count - offset == 10,
              bytes[offset] == 0x8E, bytes[offset + 1] == 8 else {
            throw NFCPassportReaderError.MissingMandatoryFields
        }
        let suppliedMAC = Array(bytes[(offset + 2)...])
        let authenticated = pad(paddedSSC + do87 + do99, blockSize: padLength)
        let computedMAC = mac(algoName: algoName, key: ksmac, msg: authenticated)
        guard computedMAC.count >= 8 else {
            throw NFCPassportReaderError.InvalidResponseChecksum
        }
        // Truncate the locally computed MAC, never the untrusted supplied MAC.
        guard zip(suppliedMAC, computedMAC.prefix(8))
            .reduce(UInt8(0), { $0 | ($1.0 ^ $1.1) }) == 0 else {
            throw NFCPassportReaderError.InvalidResponseChecksum
        }

        var data : [UInt8] = []
        if do87Data.count > 0 {
            
            let dec : [UInt8]
            if algoName == .DES {
                dec = tripleDESDecrypt(key: self.ksenc, message: do87Data, iv: [0,0,0,0,0,0,0,0])
            } else {
                // for AES the IV is the ssc with AES/EBC/NOPADDING
                let paddedssc = [UInt8](repeating: 0, count: 8) + ssc
                let iv = AESECBEncrypt(key: ksenc, message: paddedssc)
                dec = AESDecrypt(key: self.ksenc, message: do87Data, iv: iv)
            }

            // ISO 7816-4 padding has one 0x80 byte followed by zero or more 0x00 bytes.
            // Reject malformed authenticated plaintext before the legacy unpad helper slices it.
            guard let marker = dec.lastIndex(where: { $0 != 0 }), dec[marker] == 0x80 else {
                throw NFCPassportReaderError.D087Malformed
            }
            data = Array(dec[..<marker])
            Logger.secureMessaging.debug("Decrypt data of DO'87 with KSenc")
        }
        
        return ResponseAPDU(data: data, sw1: sw1, sw2: sw2)
    }

    func maskClassAndPad(apdu : NFCISO7816APDU ) -> [UInt8] {
        Logger.secureMessaging.debug("Mask class byte and pad command header")
        // BSI TR-03110-3 B.11: the authenticated CLA also retains command chaining.
        // Preserve the established masking of all other class/channel bits.
        let cla: UInt8 = 0x0C | (apdu.instructionClass & 0x10)
        let res = pad([cla, apdu.instructionCode, apdu.p1Parameter, apdu.p2Parameter], blockSize: padLength)
        return res
    }
    
    func buildD087(apdu : NFCISO7816APDU) throws -> [UInt8] {
        let cipher = [0x01] + self.padAndEncryptData(apdu)
        let res = try [0x87] + toAsn1Length(cipher.count) + cipher
        Logger.secureMessaging.debug("Build DO'87")
        return res
    }
    
    func padAndEncryptData(_ apdu : NFCISO7816APDU) -> [UInt8] {
        // Pad the data, encrypt data with KSenc and build DO'87
        let data = [UInt8](apdu.data!)
        let paddedData = pad( data, blockSize: padLength )
        
        let enc : [UInt8]
        if algoName == .DES {
            enc = tripleDESEncrypt(key: self.ksenc, message: paddedData, iv: [0,0,0,0,0,0,0,0])
        } else {
            // for AES the IV is the ssc with AES/EBC/NOPADDING
            let paddedssc = [UInt8](repeating: 0, count: 8) + ssc
            let iv = AESECBEncrypt(key: ksenc, message: paddedssc)
            enc = AESEncrypt(key: self.ksenc, message: paddedData, iv: iv)
        }
        
        Logger.secureMessaging.debug("Pad data")
        Logger.secureMessaging.debug("Encrypt data with KSenc")
        return enc
    }
    
    func incSSC() -> [UInt8] {
        let val = binToHex(self.ssc) + 1
        
        // This needs to be fully zero padded - to 8 bytes = i.e. if SSC is 1 it should return [0x0,0x0,0x0,0x0,0x0,0x0,0x0,0x1]
        // NOT [0x1]
        return withUnsafeBytes(of: val.bigEndian, Array.init)
    }
    
    func buildD08E(mac : [UInt8]) -> [UInt8] {
        let res : [UInt8] = [0x8E, UInt8(mac.count)] + mac
        Logger.secureMessaging.debug("Build DO'8E")
        return res
    }

    func buildD097(apdu : NFCISO7816APDU) throws -> [UInt8] {
        let le = apdu.expectedResponseLength
        var binLe = intToBin(le)
        if (le == 256 || le == 65536) {
            binLe = [0x00] + (le > 256 ? [0x00] : [])
        }
        
        let res : [UInt8] = try [0x97] + toAsn1Length(binLe.count) + binLe
        Logger.secureMessaging.debug("Build DO'97")
        return res
    }
    
}
#endif
