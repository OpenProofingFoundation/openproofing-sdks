//
//  NFCViewDisplayMessage.swift
//  NFCPassportReader
//
//  Created by Andy Qua on 09/02/2021.
//

import Foundation

@available(iOS 13, macOS 10.15, *)
public enum NFCViewDisplayMessage {
    case requestPresentPassport
    case authenticatingWithPassport(Int)
    case readingDataGroupProgress(DataGroupId, Int)
    case error(NFCPassportReaderError)
    case activeAuthentication
    case successfulRead
}

@available(iOS 13, macOS 10.15, *)
extension NFCViewDisplayMessage {
    public var description: String {
        switch self {
            case .requestPresentPassport:
                return "Hold your iPhone near an NFC enabled passport."
            case .authenticatingWithPassport(let progress):
                return "Authenticating passport — \(progress)%"
            case .readingDataGroupProgress(let dataGroup, let progress):
                return "Reading \(dataGroup) — \(progress)%"
            case .error(let tagError):
                switch tagError {
                    case NFCPassportReaderError.TagNotValid:
                        return "Tag not valid."
                    case NFCPassportReaderError.MoreThanOneTagFound:
                        return "More than one NFC tag detected. Move other tags away."
                    case NFCPassportReaderError.ConnectionError:
                        return "Connection error. Please try again."
                    case NFCPassportReaderError.InvalidMRZKey:
                        return "MRZ Key not valid for this document."
                    case NFCPassportReaderError.ResponseError:
                        return "Passport read failed. Try again."
                    default:
                        return "Passport read failed. Try again."
                }
            case .activeAuthentication:
                return "Authenticating....."
            case .successfulRead:
                return "Passport read successfully"
        }
    }
    
}
