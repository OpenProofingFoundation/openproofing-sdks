//
//  ServerChipAuthentication.swift
//  NFCPassportReader
//
//  KENSHIKI PATCH (server-terminal-chip-authentication). Not upstream code; listed in
//  provenance.json.
//

import Foundation

/// What a remote Chip Authentication terminal answers when given the chip's DG14: the protocol and
/// key to agree with, the terminal's ephemeral public key, and one command already protected under
/// the session keys only the chip and the terminal can derive.
///
/// The reader sends the public key to the chip under the access-control channel it already has, then
/// sends `protectedCommand` exactly as given and keeps the chip's raw answer. It never derives the
/// new keys and never interprets the answer: only the terminal, which holds the ephemeral private
/// key, can verify it, and that verification is what proves the chip holds its DG14 private key.
public struct ChipAuthenticationTerminalChallenge: Sendable {
    public let protocolOID: String
    public let keyID: Int?
    public let terminalPublicKey: [UInt8]
    public let protectedCommand: [UInt8]

    public init(protocolOID: String, keyID: Int?, terminalPublicKey: [UInt8], protectedCommand: [UInt8]) {
        self.protocolOID = protocolOID
        self.keyID = keyID
        self.terminalPublicKey = terminalPublicKey
        self.protectedCommand = protectedCommand
    }
}

/// Given the chip's DG14 bytes, exactly as read, returns the remote terminal's challenge.
public typealias ChipAuthenticationTerminal = @Sendable ([UInt8]) async throws -> ChipAuthenticationTerminalChallenge
