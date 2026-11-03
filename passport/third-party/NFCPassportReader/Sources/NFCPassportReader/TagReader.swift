//
//  TagHandler.swift
//  NFCTest
//
//  Created by Andy Qua on 09/06/2019.
//  Copyright © 2019 Andy Qua. All rights reserved.
//

import Foundation
import OSLog

#if !os(macOS)
import CoreNFC

@available(iOS 15, *)
public class TagReader {
    private let exchange: (NFCISO7816APDU) async throws -> (Data, UInt8, UInt8)
    var secureMessaging : SecureMessaging?
    var maxDataLengthToRead : Int = 0xA0  // Conservative block size for chips that reject 256-byte reads.

    var progress : ((Int)->())?

    init( tag: NFCISO7816Tag ) {
        self.exchange = { try await tag.sendCommand(apdu: $0) }
    }

    // The same APDU path serves CoreNFC and the synthetic peer; no protocol work is mocked.
    init(exchange: @escaping (NFCISO7816APDU) async throws -> (Data, UInt8, UInt8)) {
        self.exchange = exchange
    }

    /// Raw transport only. Normal commands use send; terminal-controlled chip authentication
    /// uses this path because its protected command and response belong to the remote terminal.
    func transmit(_ command: NFCISO7816APDU) async throws -> (Data, UInt8, UInt8) {
        try Task.checkCancellation()
        let response = try await exchange(command)
        try Task.checkCancellation()
        return response
    }
    
    func overrideDataAmountToRead( newAmount : Int ) {
        maxDataLengthToRead = newAmount
    }
    
    func reduceDataReadingAmount() {
        if maxDataLengthToRead > 0xA0 {
            maxDataLengthToRead = 0xA0
        }
    }


    func readDataGroup( dataGroup: DataGroupId ) async throws -> [UInt8]  {
        guard let tag = dataGroup.getFileIDTag() else {
            throw NFCPassportReaderError.UnsupportedDataGroup
        }
        
        return try await selectFileAndRead(tag: tag )
    }
    
    func getChallenge() async throws -> ResponseAPDU{
        let cmd : NFCISO7816APDU = NFCISO7816APDU(instructionClass: 00, instructionCode: 0x84, p1Parameter: 0, p2Parameter: 0, data: Data(), expectedResponseLength: 8)
        
        return try await send( cmd: cmd )
    }
    
    func doInternalAuthentication( challenge: [UInt8], useExtendedMode: Bool ) async throws -> ResponseAPDU {
        let randNonce = Data(challenge)
        
        var responseLength = 256
        if useExtendedMode {
            responseLength = 65535
        }
        
        let cmd = NFCISO7816APDU(instructionClass: 00, instructionCode: 0x88, p1Parameter: 0, p2Parameter: 0, data: randNonce, expectedResponseLength: responseLength)

        return try await send( cmd: cmd, useExtendedMode: useExtendedMode )
    }

    func doMutualAuthentication( cmdData : Data ) async throws -> ResponseAPDU{
        let cmd : NFCISO7816APDU = NFCISO7816APDU(instructionClass: 00, instructionCode: 0x82, p1Parameter: 0, p2Parameter: 0, data: cmdData, expectedResponseLength: 256)

        return try await send( cmd: cmd )
    }
    
    /// The MSE KAT APDU, see EAC 1.11 spec, Section B.1.
    /// This command is sent in the "DESede" case.
    /// - Parameter keyData: Encoded key data object (tag 0x91).
    /// - Parameter idData: Optional encoded key identifier (tag 0x84).
    func sendMSEKAT( keyData : Data, idData: Data? ) async throws -> ResponseAPDU {
        
        var data = keyData
        if let idData = idData {
            data += idData
        }
        
        let cmd : NFCISO7816APDU = NFCISO7816APDU(instructionClass: 00, instructionCode: 0x22, p1Parameter: 0x41, p2Parameter: 0xA6, data: data, expectedResponseLength: 256)
        
        return try await send( cmd: cmd )
    }
    
    /// Selects the chip-authentication protocol: tag 0x80 holds its OID, and optional tag
    /// 0x84 selects the key. This is the initial MSE:Set AT command for AES chip authentication.
    func sendMSESetATIntAuth( oid: String, keyId: Int? ) async throws -> ResponseAPDU {
        
        let cmd : NFCISO7816APDU
        let oidBytes = oidToBytes(oid: oid, replaceTag: true)
        
        if let keyId = keyId, keyId != 0 {
            let keyIdBytes = wrapDO(b:0x84, arr:intToBytes(val:keyId, removePadding: true))
            let data = oidBytes + keyIdBytes
            
            cmd = NFCISO7816APDU(instructionClass: 00, instructionCode: 0x22, p1Parameter: 0x41, p2Parameter: 0xA4, data: Data(data), expectedResponseLength: 256)
            
        } else {
            cmd = NFCISO7816APDU(instructionClass: 00, instructionCode: 0x22, p1Parameter: 0x41, p2Parameter: 0xA4, data: Data(oidBytes), expectedResponseLength: 256)
        }
        
        return try await send( cmd: cmd )
    }
    
    func sendMSESetATMutualAuth( oid: String, keyType: UInt8 ) async throws -> ResponseAPDU {
        
        let oidBytes = oidToBytes(oid: oid, replaceTag: true)
        let keyTypeBytes = wrapDO( b: 0x83, arr:[keyType])
        
        let data = oidBytes + keyTypeBytes
            
        let cmd = NFCISO7816APDU(instructionClass: 00, instructionCode: 0x22, p1Parameter: 0xC1, p2Parameter: 0xA4, data: Data(data), expectedResponseLength: -1)
        
        return try await send( cmd: cmd )
    }
    

    /// Sends one PACE or chip-authentication exchange and removes its response's 0x7C wrapper.
    /// - Parameter data: Inner authentication data; this method adds the 0x7C wrapper.
    /// - Parameter lengthExpected: Requested response length, defaulting to 256 bytes.
    /// - Parameter isLast: Whether to clear command chaining for the final exchange.
    func sendGeneralAuthenticate( data : [UInt8], lengthExpected : Int = 256, isLast: Bool) async throws -> ResponseAPDU {

        let wrappedData = wrapDO(b:0x7C, arr:data)
        let commandData = Data(wrappedData)
            
        // 0x10 is class command chaining
        let instructionClass : UInt8 = isLast ? 0x00 : 0x10
        let INS_BSI_GENERAL_AUTHENTICATE : UInt8 = 0x86
        
        let cmd : NFCISO7816APDU = NFCISO7816APDU(instructionClass: instructionClass, instructionCode: INS_BSI_GENERAL_AUTHENTICATE, p1Parameter: 0x00, p2Parameter: 0x00, data: commandData, expectedResponseLength: lengthExpected)
        var response : ResponseAPDU
        do {
            response = try await send( cmd: cmd )
            response.data = try unwrapDO( tag:0x7c, wrappedData:response.data)
        } catch {
            // Retry only the explicit wrong-length status, once with short APDU maximum Le.
            if case NFCPassportReaderError.ResponseError(_, let sw1, let sw2) = error,
               sw1 == 0x67, sw2 == 0x00 {
                
                let cmd : NFCISO7816APDU = NFCISO7816APDU(instructionClass: instructionClass, instructionCode: INS_BSI_GENERAL_AUTHENTICATE, p1Parameter: 0x00, p2Parameter: 0x00, data: commandData, expectedResponseLength: 256)
                response = try await send( cmd: cmd )
                response.data = try unwrapDO( tag:0x7c, wrappedData:response.data)
            } else {
                throw error
            }
        }
        return response
    }
    

    func selectFileAndRead( tag: [UInt8], onSelected: () -> Void = { /* Selection observation is optional; omitted callers only need the file bytes. */ }) async throws -> [UInt8] {
        var resp = try await selectFile(tag: tag )
        onSelected()
            
        // Read first 4 bytes of header to see how big the data structure is
        guard let readHeaderCmd = NFCISO7816APDU(data:Data([0x00, 0xB0, 0x00, 0x00, 0x00, 0x00,0x04])) else {
            throw NFCPassportReaderError.UnexpectedError
        }
        resp = try await self.send( cmd: readHeaderCmd )

        // Parse the BER length, retain only the tag/length header, then read the full value
        // from its actual offset. Header reads can include value bytes or long-form lengths.
        guard resp.data.count >= 4 else { throw NFCPassportReaderError.InvalidASN1Value }
        let (len, o) = try asn1Length([UInt8](resp.data[1..<4]))
        var remaining = Int(len)
        var amountRead = o + 1
        guard amountRead <= resp.data.count else { throw NFCPassportReaderError.InvalidASN1Value }
        
        var data = [UInt8](resp.data[..<amountRead])
        
        
        var readAmount : Int = maxDataLengthToRead
        while remaining > 0 {
            if maxDataLengthToRead != 256 && remaining < maxDataLengthToRead {
                readAmount = remaining
            }

            self.progress?( Int(Float(amountRead) / Float(remaining+amountRead ) * 100))
            let offset = intToBin(amountRead, pad:4)

            let cmd = NFCISO7816APDU(
                instructionClass: 00,
                instructionCode: 0xB0,
                p1Parameter: offset[0],
                p2Parameter: offset[1],
                data: Data(),
                expectedResponseLength: readAmount
            )
            resp = try await self.send( cmd: cmd )
            guard !resp.data.isEmpty else { throw NFCPassportReaderError.UnexpectedError }

            data += resp.data
            
            remaining -= resp.data.count
            amountRead += resp.data.count
        }
        
        return data
    }


    func readCardAccess(onStage: (String) -> Void = { _ in /* Stage observation is optional; omitted callers only need CardAccess bytes. */ }) async throws -> [UInt8]{
        // CoreNFC initially selects an entitled applet, but EF.CardAccess belongs to the master
        // file. Select explicit FID 3F00 (ISO/IEC 7816-4 SELECT FILE) before reading its parameters.
        // Separate selection/read stages keep a missing file distinct from a failed read.
        onStage("masterFile")
        let cmd : NFCISO7816APDU = NFCISO7816APDU(instructionClass: 0x00, instructionCode: 0xA4, p1Parameter: 0x00, p2Parameter: 0x0C, data: Data([0x3f,0x00]), expectedResponseLength: -1)
        
        _ = try await send( cmd: cmd)
            
        // Select EF.CardAccess; success advances diagnostics to the subsequent file read.
        onStage("cardAccess")
        let data = try await self.selectFileAndRead(tag: [0x01,0x1C]) { onStage("cardAccessRead") }
        return data
    }
    
    func selectPassportApplication() async throws -> ResponseAPDU {
        // Return from master-file access to the eMRTD application before BAC or data-group reads.
        Logger.tagReader.debug( "Re-selecting eMRTD Application" )
        let cmd : NFCISO7816APDU = NFCISO7816APDU(instructionClass: 0x00, instructionCode: 0xA4, p1Parameter: 0x04, p2Parameter: 0x0C, data: Data([0xA0, 0x00, 0x00, 0x02, 0x47, 0x10, 0x01]), expectedResponseLength: -1)
        
        let response = try await self.send( cmd: cmd)
        return response
    }
    
    func selectFile( tag: [UInt8] ) async throws -> ResponseAPDU {
        
        let data : [UInt8] = [0x00, 0xA4, 0x02, 0x0C, 0x02] + tag
        let cmd = NFCISO7816APDU(data:Data(data))!
        
        return try await send( cmd: cmd )
    }

    func send( cmd: NFCISO7816APDU, useExtendedMode : Bool = false ) async throws -> ResponseAPDU {
        var toSend = cmd
        if let sm = secureMessaging {
            toSend = try sm.protect(apdu:cmd, useExtendedMode: useExtendedMode)
        }
        
        try Task.checkCancellation()
        var (data, sw1, sw2) = try await transmit(toSend)
        var continuations = 0

        // SW1=61 chains response fragments through GET RESPONSE. SW2=00 represents 256 bytes,
        // not an absent Le. Preserve the final status and bound work even if a peer never finishes.
        while (sw1 == 0x61) {
            try Task.checkCancellation()
            continuations += 1
            // Reader limits bound allocation and repeated exchanges; cancellation is checked each time.
            guard continuations <= 256, data.count <= 65536 else {
                throw NFCPassportReaderError.UnexpectedError
            }
            let getResponseCmd = NFCISO7816APDU(instructionClass: 0x0, instructionCode: 0xC0, p1Parameter: 0x0, p2Parameter: 0x0, data: Data(), expectedResponseLength: sw2 == 0 ? 256 : Int(sw2))
            let nextSegment: Data
            (nextSegment, sw1, sw2) = try await transmit(getResponseCmd)
            data += nextSegment
        }

        try Task.checkCancellation()
        guard data.count <= 65536 else { throw NFCPassportReaderError.UnexpectedError }
        var rep = ResponseAPDU(data: [UInt8](data), sw1: sw1, sw2: sw2)
        
        if let sm = self.secureMessaging {
            rep = try sm.unprotect(rapdu:rep)
        }
        
        // Only the complete status word 9000 succeeds, including after secure-message verification.
        if rep.sw1 != 0x90 || rep.sw2 != 0x00 {
            let tagError: NFCPassportReaderError
            if (rep.sw1 == 0x63 && rep.sw2 == 0x00) {
                tagError = NFCPassportReaderError.InvalidMRZKey
            } else {
                let errorMsg = self.decodeError(sw1: rep.sw1, sw2: rep.sw2)
                tagError = NFCPassportReaderError.ResponseError( errorMsg, rep.sw1, rep.sw2 )
            }
            throw tagError
        }

        return rep
    }

    private func decodeError( sw1: UInt8, sw2:UInt8 ) -> String {

        let errors : [UInt8 : [UInt8:String]] = [
            0x62: [0x00:"No information given",
                   0x81:"Part of returned data may be corrupted",
                   0x82:"End of file/record reached before reading Le bytes",
                   0x83:"Selected file invalidated",
                   0x84:"FCI not formatted according to ISO7816-4 section 5.1.5"],
            
            0x63: [0x81:"File filled up by the last write",
                   0x82:"Card Key not supported",
                   0x83:"Reader Key not supported",
                   0x84:"Plain transmission not supported",
                   0x85:"Secured Transmission not supported",
                   0x86:"Volatile memory not available",
                   0x87:"Non Volatile memory not available",
                   0x88:"Key number not valid",
                   0x89:"Key length is not correct",
                   0xC:"Counter provided by X (valued from 0 to 15) (exact meaning depending on the command)"],
            0x65: [0x00:"No information given",
                   0x81:"Memory failure"],
            0x67: [0x00:"Wrong length"],
            0x68: [0x00:"No information given",
                   0x81:"Logical channel not supported",
                   0x82:"Secure messaging not supported",
                   0x83:"Last command of the chain expected",
                   0x84:"Command chaining not supported"],
            0x69: [0x00:"No information given",
                   0x81:"Command incompatible with file structure",
                   0x82:"Security status not satisfied",
                   0x83:"Authentication method blocked",
                   0x84:"Referenced data invalidated",
                   0x85:"Conditions of use not satisfied",
                   0x86:"Command not allowed (no current EF)",
                   0x87:"Expected SM data objects missing",
                   0x88:"SM data objects incorrect"],
            0x6A: [0x00:"No information given",
                   0x80:"Incorrect parameters in the data field",
                   0x81:"Function not supported",
                   0x82:"File not found",
                   0x83:"Record not found",
                   0x84:"Not enough memory space in the file",
                   0x85:"Lc inconsistent with TLV structure",
                   0x86:"Incorrect parameters P1-P2",
                   0x87:"Lc inconsistent with P1-P2",
                   0x88:"Referenced data not found"],
            0x6B: [0x00:"Wrong parameter(s) P1-P2]"],
            0x6D: [0x00:"Instruction code not supported or invalid"],
            0x6E: [0x00:"Class not supported"],
            0x6F: [0x00:"No precise diagnosis"],
            0x90: [0x00:"Success"] //No further qualification
        ]
        
        // Special cases - where sw2 isn't an error but contains a value
        if sw1 == 0x61 {
            return "SW2 indicates the number of response bytes still available - (\(sw2) bytes still available)"
        } else if sw1 == 0x64 {
            return "State of non-volatile memory unchanged (SW2=00, other values are RFU)"
        } else if sw1 == 0x6C {
            return "Wrong length Le: SW2 indicates the exact length - (exact length :\(sw2))"
        }

        if let dict = errors[sw1], let errorMsg = dict[sw2] {
            return errorMsg
        }
        
        return "Unknown error - sw1: 0x\(binToHexRep(sw1)), sw2 - 0x\(binToHexRep(sw2)) "
    }
}

#endif
