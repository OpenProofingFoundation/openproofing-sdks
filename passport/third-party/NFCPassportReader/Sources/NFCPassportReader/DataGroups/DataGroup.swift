//
//  DataGroup.swift
//
//  Created by Andy Qua on 01/02/2021.
//

import Foundation

@available(iOS 13, macOS 10.15, *)
public class DataGroup {
    public var datagroupType : DataGroupId { .Unknown }
    
    /// Body contains the actual data
    public private(set) var body : [UInt8] = []
    
    /// Data contains the whole DataGroup data (as that is what the hash is calculated from
    public private(set) var data : [UInt8] = []
    
    var pos = 0
    private var limits: [Int] = []
    private var constructedTag = false
    
    required init( _ data : [UInt8] ) throws {
        guard data.count >= 2 else { throw NFCPassportReaderError.InvalidASN1Value }
        self.data = data
        
        // Skip the first byte which is the header byte
        pos = 1
        constructedTag = data[0] & 0x20 != 0
        let length = try getNextLength()
        guard length == data.count - pos else { throw NFCPassportReaderError.InvalidASN1Value }
        self.body = Array(data[pos..<(pos + length)])
        
        try parse(data)
    }
    
    func parse( _ data:[UInt8] ) throws {
    }
    
    func getNextTag() throws -> Int {
        while limits.count > 1, pos == limits.last { limits.removeLast() }
        let limit = limits.last ?? data.count
        guard pos >= 0, pos < limit else {
            throw NFCPassportReaderError.TagNotValid
        }
        let first = data[pos]
        constructedTag = first & 0x20 != 0
        var tag = Int(first)
        pos += 1
        if first & 0x1F == 0x1F {
            var next: UInt8
            repeat {
                guard pos < limit, tag <= Int.max >> 8 else {
                    throw NFCPassportReaderError.InvalidASN1Value
                }
                next = data[pos]
                tag = tag << 8 | Int(next)
                pos += 1
            } while next & 0x80 != 0
        }
        return tag
    }
    
    func getNextLength() throws -> Int  {
        try readLength(descending: true)
    }

    private func readLength(descending: Bool) throws -> Int {
        let limit = limits.last ?? data.count
        guard pos >= 0, pos < limit else { throw NFCPassportReaderError.CannotDecodeASN1Length }
        let (length, header) = try asn1Length(Array(data[pos..<min(limit, pos + 3)]))
        guard header <= limit - pos, length <= limit - pos - header else {
            throw NFCPassportReaderError.InvalidASN1Value
        }
        pos += header
        if descending, constructedTag { limits.append(pos + length) }
        constructedTag = false
        return length
    }
    
    func getNextValue() throws -> [UInt8] {
        let length = try readLength(descending: false)
        let value = [UInt8](data[pos ..< pos+length])
        pos += length
        return value
    }
    
    public func hash( _ hashAlgorythm: String ) -> [UInt8]  {
        var ret : [UInt8] = []
        if hashAlgorythm == "SHA1" {
            ret = calcSHA1Hash(self.data)
        } else if hashAlgorythm == "SHA224" {
            ret = calcSHA224Hash(self.data)
        } else if hashAlgorythm == "SHA256" {
            ret = calcSHA256Hash(self.data)
        } else if hashAlgorythm == "SHA384" {
            ret = calcSHA384Hash(self.data)
        } else if hashAlgorythm == "SHA512" {
            ret = calcSHA512Hash(self.data)
        }
        
        return ret
    }

    public func verifyTag(_ tag: Int, equals expectedTag: Int) throws {
        if tag != expectedTag  {
            throw NFCPassportReaderError.InvalidResponse(
                dataGroupId: datagroupType,
                expectedTag: expectedTag,
                actualTag: tag
            )
        }
    }

    public func verifyTag(_ tag: Int, oneOf expectedTags: [Int]) throws {
        if !expectedTags.contains(tag) {
            throw NFCPassportReaderError.InvalidResponse(
                dataGroupId: datagroupType,
                expectedTag: expectedTags.first!,
                actualTag: tag
            )
        }
    }
}
