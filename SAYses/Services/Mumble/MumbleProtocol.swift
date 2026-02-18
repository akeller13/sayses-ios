import Foundation
import UIKit

// MARK: - Message Types

enum MumbleMessageType: UInt16 {
    case version = 0
    case udpTunnel = 1
    case authenticate = 2
    case ping = 3
    case reject = 4
    case serverSync = 5
    case channelRemove = 6
    case channelState = 7
    case userRemove = 8
    case userState = 9
    case banList = 10
    case textMessage = 11
    case permissionDenied = 12
    case acl = 13
    case queryUsers = 14
    case cryptSetup = 15
    case contextActionModify = 16
    case contextAction = 17
    case userList = 18
    case voiceTarget = 19
    case permissionQuery = 20
    case codecVersion = 21
    case userStats = 22
    case requestBlob = 23
    case serverConfig = 24
    case suggestConfig = 25
}

// MARK: - Reject Reason

enum MumbleRejectReason: Int {
    case none = 0
    case wrongVersion = 1
    case invalidUsername = 2
    case wrongUserPassword = 3
    case wrongServerPassword = 4
    case usernameInUse = 5
    case serverFull = 6
    case noCertificate = 7
    case authenticatorFail = 8

    var localizedDescription: String {
        switch self {
        case .none: return "Unbekannter Fehler"
        case .wrongVersion: return "Inkompatible Version"
        case .invalidUsername: return "Ungültiger Benutzername"
        case .wrongUserPassword: return "Falsches Benutzerpasswort"
        case .wrongServerPassword: return "Falsches Serverpasswort"
        case .usernameInUse: return "Benutzername bereits vergeben"
        case .serverFull: return "Server ist voll"
        case .noCertificate: return "Zertifikat erforderlich"
        case .authenticatorFail: return "Authentifizierung fehlgeschlagen"
        }
    }
}

// MARK: - Protobuf Encoder

class ProtobufEncoder {
    private var data = Data()

    func encode() -> Data {
        return data
    }

    func writeVarint(_ value: UInt64) {
        var v = value
        while v > 0x7F {
            data.append(UInt8((v & 0x7F) | 0x80))
            v >>= 7
        }
        data.append(UInt8(v))
    }

    func writeTag(fieldNumber: Int, wireType: Int) {
        writeVarint(UInt64((fieldNumber << 3) | wireType))
    }

    func writeUInt32(fieldNumber: Int, value: UInt32) {
        writeTag(fieldNumber: fieldNumber, wireType: 0)
        writeVarint(UInt64(value))
    }

    func writeInt32(fieldNumber: Int, value: Int32) {
        writeTag(fieldNumber: fieldNumber, wireType: 0)
        writeVarint(UInt64(bitPattern: Int64(value)))
    }

    func writeBool(fieldNumber: Int, value: Bool) {
        writeTag(fieldNumber: fieldNumber, wireType: 0)
        writeVarint(value ? 1 : 0)
    }

    func writeString(fieldNumber: Int, value: String) {
        let bytes = value.data(using: .utf8) ?? Data()
        writeTag(fieldNumber: fieldNumber, wireType: 2)
        writeVarint(UInt64(bytes.count))
        data.append(bytes)
    }

    func writeBytes(fieldNumber: Int, value: Data) {
        writeTag(fieldNumber: fieldNumber, wireType: 2)
        writeVarint(UInt64(value.count))
        data.append(value)
    }
}

// MARK: - Protobuf Decoder

class ProtobufDecoder {
    private let data: Data
    private var offset: Int = 0

    init(data: Data) {
        self.data = data
    }

    var isAtEnd: Bool {
        return offset >= data.count
    }

    func readVarint() -> UInt64? {
        var result: UInt64 = 0
        var shift = 0

        while offset < data.count {
            let byte = data[offset]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                return result
            }
            shift += 7
            if shift >= 64 {
                return nil
            }
        }
        return nil
    }

    func readTag() -> (fieldNumber: Int, wireType: Int)? {
        guard let tag = readVarint() else { return nil }
        return (Int(tag >> 3), Int(tag & 0x7))
    }

    func readUInt32() -> UInt32? {
        guard let v = readVarint() else { return nil }
        return UInt32(truncatingIfNeeded: v)
    }

    func readInt32() -> Int32? {
        guard let v = readVarint() else { return nil }
        return Int32(truncatingIfNeeded: v)
    }

    func readBool() -> Bool? {
        guard let v = readVarint() else { return nil }
        return v != 0
    }

    func readString() -> String? {
        guard let length = readVarint() else { return nil }
        let len = Int(length)
        guard offset + len <= data.count else { return nil }
        let bytes = data[offset..<(offset + len)]
        offset += len
        return String(data: bytes, encoding: .utf8)
    }

    func readBytes() -> Data? {
        guard let length = readVarint() else { return nil }
        let len = Int(length)
        guard offset + len <= data.count else { return nil }
        let bytes = data[offset..<(offset + len)]
        offset += len
        return Data(bytes)
    }

    func skip(wireType: Int) {
        switch wireType {
        case 0: _ = readVarint()
        case 1: offset += 8
        case 2:
            if let len = readVarint() {
                offset += Int(len)
            }
        case 5: offset += 4
        default: break
        }
    }
}

// MARK: - Message Builders

struct MumbleMessages {

    static func buildVersion() -> Data {
        let encoder = ProtobufEncoder()
        // version = (1 << 16) | (3 << 8) | 0 = 66304 (Mumble 1.3.0)
        encoder.writeUInt32(fieldNumber: 1, value: 66304)
        encoder.writeString(fieldNumber: 2, value: "SAYses iOS 1.0")
        encoder.writeString(fieldNumber: 3, value: "iOS")
        encoder.writeString(fieldNumber: 4, value: UIDevice.current.systemVersion)
        return encoder.encode()
    }

    static func buildAuthenticate(username: String, password: String? = nil) -> Data {
        let encoder = ProtobufEncoder()
        encoder.writeString(fieldNumber: 1, value: username)
        if let pwd = password, !pwd.isEmpty {
            encoder.writeString(fieldNumber: 2, value: pwd)
        }
        // CELT version (legacy support)
        encoder.writeInt32(fieldNumber: 4, value: -2147483637)
        // Opus support
        encoder.writeBool(fieldNumber: 5, value: true)
        return encoder.encode()
    }

    static func buildPing(timestamp: UInt64) -> Data {
        let encoder = ProtobufEncoder()
        encoder.writeTag(fieldNumber: 1, wireType: 0)
        encoder.writeVarint(timestamp)
        return encoder.encode()
    }

    static func buildUserState(channelId: UInt32) -> Data {
        let encoder = ProtobufEncoder()
        encoder.writeUInt32(fieldNumber: 5, value: channelId)
        return encoder.encode()
    }

    static func buildUserStateMute(selfMute: Bool, selfDeaf: Bool) -> Data {
        let encoder = ProtobufEncoder()
        encoder.writeBool(fieldNumber: 9, value: selfMute)
        encoder.writeBool(fieldNumber: 10, value: selfDeaf)
        return encoder.encode()
    }

    /// Request permissions for a specific channel
    static func buildPermissionQuery(channelId: UInt32) -> Data {
        let encoder = ProtobufEncoder()
        encoder.writeUInt32(fieldNumber: 1, value: channelId)
        return encoder.encode()
    }

    /// Build a TextMessage for sending to a channel
    /// If isTree is true, the message is sent to all users in the channel and subchannels
    static func buildTextMessage(channelId: UInt32, message: String, isTree: Bool = false) -> Data {
        let encoder = ProtobufEncoder()
        // Field 4: tree_id (for tree message) or Field 3: channel_id (for channel message)
        if isTree {
            encoder.writeUInt32(fieldNumber: 4, value: channelId)
        } else {
            encoder.writeUInt32(fieldNumber: 3, value: channelId)
        }
        // Field 5: message
        encoder.writeString(fieldNumber: 5, value: message)
        return encoder.encode()
    }

    /// Build audio packet for UDPTunnel
    /// Format: [header byte][varint sequence][varint frame header][opus data]
    /// Header: 3 bits type + 5 bits target
    static func buildAudioPacket(opusData: Data, sequenceNumber: Int64, isTerminator: Bool = false) -> Data {
        var packet = Data()

        // Header byte: type=4 (Opus) in upper 3 bits, target=0 in lower 5 bits
        let headerByte: UInt8 = (4 << 5) | 0  // Opus = 4, target = 0
        packet.append(headerByte)

        // Sequence number as Mumble varint
        writeMumbleVarint(value: UInt64(bitPattern: sequenceNumber), to: &packet)

        // Frame header: length (13 bits) + terminator flag (bit 13)
        var frameHeader = opusData.count
        if isTerminator {
            frameHeader |= 0x2000  // Set terminator bit (bit 13)
        }
        writeMumbleVarint(value: UInt64(frameHeader), to: &packet)

        // Append opus payload
        packet.append(opusData)

        return packet
    }

    /// Write Mumble-specific varint encoding (different from protobuf!)
    private static func writeMumbleVarint(value: UInt64, to data: inout Data) {
        if value < 0x80 {
            // Single byte: 0xxxxxxx
            data.append(UInt8(value))
        } else if value < 0x4000 {
            // Two bytes: 10xxxxxx xxxxxxxx
            data.append(UInt8((value >> 8) | 0x80))
            data.append(UInt8(value & 0xFF))
        } else if value < 0x200000 {
            // Three bytes: 110xxxxx xxxxxxxx xxxxxxxx
            data.append(UInt8((value >> 16) | 0xC0))
            data.append(UInt8((value >> 8) & 0xFF))
            data.append(UInt8(value & 0xFF))
        } else if value < 0x10000000 {
            // Four bytes: 1110xxxx xxxxxxxx xxxxxxxx xxxxxxxx
            data.append(UInt8((value >> 24) | 0xE0))
            data.append(UInt8((value >> 16) & 0xFF))
            data.append(UInt8((value >> 8) & 0xFF))
            data.append(UInt8(value & 0xFF))
        } else {
            // Five bytes: 11110000 xxxxxxxx xxxxxxxx xxxxxxxx xxxxxxxx
            data.append(0xF0)
            data.append(UInt8((value >> 24) & 0xFF))
            data.append(UInt8((value >> 16) & 0xFF))
            data.append(UInt8((value >> 8) & 0xFF))
            data.append(UInt8(value & 0xFF))
        }
    }
}

// MARK: - Parsed Messages

/// Parsed audio packet from UDPTunnel
struct ParsedAudioPacket {
    var codecType: Int = 0       // 0=CELT Alpha, 1=Ping, 2=Speex, 3=CELT Beta, 4=Opus
    var target: Int = 0          // 0=normal, 1-30=whisper targets, 31=server loopback
    var senderSession: UInt32 = 0
    var sequenceNumber: Int64 = 0
    var opusData: Data = Data()
    var isTerminator: Bool = false
    var isValid: Bool = false
}

struct ParsedVersion {
    var version: UInt32 = 0
    var release: String = ""
    var os: String = ""
    var osVersion: String = ""
}

struct ParsedServerSync {
    var session: UInt32 = 0
    var maxBandwidth: UInt32 = 0
    var welcomeText: String = ""
    var permissions: UInt64 = 0
}

struct ParsedChannelState {
    var channelId: UInt32 = 0
    var parent: UInt32 = 0
    var name: String = ""
    var description: String = ""
    var position: Int32 = 0
    var temporary: Bool = false
    var maxUsers: UInt32 = 0
}

struct ParsedUserState {
    var session: UInt32 = 0
    var actor: UInt32 = 0
    var name: String = ""
    var userId: UInt32 = 0
    var channelId: UInt32 = 0
    var hasChannelId: Bool = false  // Track if channelId was explicitly set in the message
    var mute: Bool = false
    var deaf: Bool = false
    var suppress: Bool = false
    var selfMute: Bool = false
    var selfDeaf: Bool = false
    var prioritySpeaker: Bool = false
    var recording: Bool = false
    var hasMute: Bool = false
    var hasDeaf: Bool = false
    var hasSuppress: Bool = false
    var hasSelfMute: Bool = false
    var hasSelfDeaf: Bool = false
}

struct ParsedUserRemove {
    var session: UInt32 = 0
    var actor: UInt32 = 0
    var reason: String = ""
    var ban: Bool = false
}

struct ParsedReject {
    var type: MumbleRejectReason = .none
    var reason: String = ""
}

struct ParsedCodecVersion {
    var alpha: Int32 = 0
    var beta: Int32 = 0
    var preferAlpha: Bool = true
    var opus: Bool = false
}

struct ParsedPermissionQuery {
    var channelId: UInt32 = 0
    var permissions: UInt32 = 0
    var flush: Bool = false
}

/// Parsed text message from TextMessage
struct ParsedTextMessage {
    var actor: UInt32 = 0          // Sender session ID
    var sessions: [UInt32] = []    // Target sessions (for direct messages)
    var channelIds: [UInt32] = []  // Target channels (for channel messages)
    var treeIds: [UInt32] = []     // Target tree channels (for tree messages)
    var message: String = ""       // Message content (may be JSON for alarms)
}

// MARK: - Message Parsers

struct MumbleParsers {

    static func parseVersion(data: Data) -> ParsedVersion {
        var result = ParsedVersion()
        let decoder = ProtobufDecoder(data: data)

        while !decoder.isAtEnd {
            guard let (fieldNumber, wireType) = decoder.readTag() else { break }
            switch fieldNumber {
            case 1: result.version = decoder.readUInt32() ?? 0
            case 2: result.release = decoder.readString() ?? ""
            case 3: result.os = decoder.readString() ?? ""
            case 4: result.osVersion = decoder.readString() ?? ""
            default: decoder.skip(wireType: wireType)
            }
        }
        return result
    }

    static func parseServerSync(data: Data) -> ParsedServerSync {
        var result = ParsedServerSync()
        let decoder = ProtobufDecoder(data: data)

        while !decoder.isAtEnd {
            guard let (fieldNumber, wireType) = decoder.readTag() else { break }
            switch fieldNumber {
            case 1: result.session = decoder.readUInt32() ?? 0
            case 2: result.maxBandwidth = decoder.readUInt32() ?? 0
            case 3: result.welcomeText = decoder.readString() ?? ""
            case 4:
                if let v = decoder.readVarint() {
                    result.permissions = v
                }
            default: decoder.skip(wireType: wireType)
            }
        }
        return result
    }

    static func parseChannelState(data: Data) -> ParsedChannelState {
        var result = ParsedChannelState()
        let decoder = ProtobufDecoder(data: data)

        while !decoder.isAtEnd {
            guard let (fieldNumber, wireType) = decoder.readTag() else { break }
            switch fieldNumber {
            case 1: result.channelId = decoder.readUInt32() ?? 0
            case 2: result.parent = decoder.readUInt32() ?? 0
            case 3: result.name = decoder.readString() ?? ""
            case 5: result.description = decoder.readString() ?? ""
            case 8: result.temporary = decoder.readBool() ?? false
            case 9: result.position = decoder.readInt32() ?? 0
            case 11: result.maxUsers = decoder.readUInt32() ?? 0
            default: decoder.skip(wireType: wireType)
            }
        }
        return result
    }

    static func parseUserState(data: Data) -> ParsedUserState {
        var result = ParsedUserState()
        let decoder = ProtobufDecoder(data: data)

        while !decoder.isAtEnd {
            guard let (fieldNumber, wireType) = decoder.readTag() else { break }
            switch fieldNumber {
            case 1: result.session = decoder.readUInt32() ?? 0
            case 2: result.actor = decoder.readUInt32() ?? 0
            case 3: result.name = decoder.readString() ?? ""
            case 4: result.userId = decoder.readUInt32() ?? 0
            case 5:
                if let channelId = decoder.readUInt32() {
                    result.channelId = channelId
                    result.hasChannelId = true
                }
            case 6: result.mute = decoder.readBool() ?? false; result.hasMute = true
            case 7: result.deaf = decoder.readBool() ?? false; result.hasDeaf = true
            case 8: result.suppress = decoder.readBool() ?? false; result.hasSuppress = true
            case 9: result.selfMute = decoder.readBool() ?? false; result.hasSelfMute = true
            case 10: result.selfDeaf = decoder.readBool() ?? false; result.hasSelfDeaf = true
            case 18: result.prioritySpeaker = decoder.readBool() ?? false
            case 19: result.recording = decoder.readBool() ?? false
            default: decoder.skip(wireType: wireType)
            }
        }
        return result
    }

    static func parseUserRemove(data: Data) -> ParsedUserRemove {
        var result = ParsedUserRemove()
        let decoder = ProtobufDecoder(data: data)

        while !decoder.isAtEnd {
            guard let (fieldNumber, wireType) = decoder.readTag() else { break }
            switch fieldNumber {
            case 1: result.session = decoder.readUInt32() ?? 0
            case 2: result.actor = decoder.readUInt32() ?? 0
            case 3: result.reason = decoder.readString() ?? ""
            case 4: result.ban = decoder.readBool() ?? false
            default: decoder.skip(wireType: wireType)
            }
        }
        return result
    }

    static func parseReject(data: Data) -> ParsedReject {
        var result = ParsedReject()
        let decoder = ProtobufDecoder(data: data)

        while !decoder.isAtEnd {
            guard let (fieldNumber, wireType) = decoder.readTag() else { break }
            switch fieldNumber {
            case 1:
                if let v = decoder.readUInt32() {
                    result.type = MumbleRejectReason(rawValue: Int(v)) ?? .none
                }
            case 2: result.reason = decoder.readString() ?? ""
            default: decoder.skip(wireType: wireType)
            }
        }
        return result
    }

    static func parseCodecVersion(data: Data) -> ParsedCodecVersion {
        var result = ParsedCodecVersion()
        let decoder = ProtobufDecoder(data: data)

        while !decoder.isAtEnd {
            guard let (fieldNumber, wireType) = decoder.readTag() else { break }
            switch fieldNumber {
            case 1: result.alpha = decoder.readInt32() ?? 0
            case 2: result.beta = decoder.readInt32() ?? 0
            case 3: result.preferAlpha = decoder.readBool() ?? true
            case 4: result.opus = decoder.readBool() ?? false
            default: decoder.skip(wireType: wireType)
            }
        }
        return result
    }

    static func parsePermissionQuery(data: Data) -> ParsedPermissionQuery {
        var result = ParsedPermissionQuery()
        let decoder = ProtobufDecoder(data: data)

        while !decoder.isAtEnd {
            guard let (fieldNumber, wireType) = decoder.readTag() else { break }
            switch fieldNumber {
            case 1: result.channelId = decoder.readUInt32() ?? 0
            case 2: result.permissions = decoder.readUInt32() ?? 0
            case 3: result.flush = decoder.readBool() ?? false
            default: decoder.skip(wireType: wireType)
            }
        }
        return result
    }

    /// Parse TextMessage from server
    /// Protobuf fields:
    /// - 1: actor (uint32) - sender session
    /// - 2: session (repeated uint32) - target sessions
    /// - 3: channel_id (repeated uint32) - target channels
    /// - 4: tree_id (repeated uint32) - target tree channels
    /// - 5: message (string) - the message content
    static func parseTextMessage(data: Data) -> ParsedTextMessage {
        var result = ParsedTextMessage()
        let decoder = ProtobufDecoder(data: data)

        while !decoder.isAtEnd {
            guard let (fieldNumber, wireType) = decoder.readTag() else { break }
            switch fieldNumber {
            case 1: result.actor = decoder.readUInt32() ?? 0
            case 2:
                if let session = decoder.readUInt32() {
                    result.sessions.append(session)
                }
            case 3:
                if let channelId = decoder.readUInt32() {
                    result.channelIds.append(channelId)
                }
            case 4:
                if let treeId = decoder.readUInt32() {
                    result.treeIds.append(treeId)
                }
            case 5: result.message = decoder.readString() ?? ""
            default: decoder.skip(wireType: wireType)
            }
        }
        return result
    }

    /// Parse incoming audio packet from UDPTunnel
    /// Format: [header byte][varint session][varint sequence][varint length + opus data...]
    static func parseAudioPacket(data: Data) -> ParsedAudioPacket {
        var result = ParsedAudioPacket()

        guard data.count >= 1 else { return result }

        var offset = 0

        // Header byte: TTT TTTTT (3 bits type, 5 bits target)
        let header = data[offset]
        offset += 1

        // Type in upper 3 bits, target in lower 5 bits
        result.codecType = Int((header >> 5) & 0x07)
        result.target = Int(header & 0x1F)

        // Check for valid Opus type (4)
        guard result.codecType == 4 else {
            // Not Opus, might be ping or other codec
            return result
        }

        // Read sender session (Mumble varint)
        let (session, sessionBytes) = readMumbleVarint(data: data, offset: offset)
        offset += sessionBytes
        result.senderSession = UInt32(truncatingIfNeeded: session)

        // Read sequence number (Mumble varint)
        let (sequence, seqBytes) = readMumbleVarint(data: data, offset: offset)
        offset += seqBytes
        result.sequenceNumber = Int64(sequence)

        // Read opus frame(s)
        while offset < data.count {
            // Read frame header (Mumble varint)
            let (frameHeader, headerBytes) = readMumbleVarint(data: data, offset: offset)
            offset += headerBytes

            // Frame length is lower 13 bits, bit 13 is terminator flag
            let frameLength = Int(frameHeader & 0x1FFF)
            let isTerminator = (frameHeader & 0x2000) != 0

            if isTerminator {
                result.isTerminator = true
            }

            // Extract opus data
            if frameLength > 0 && offset + frameLength <= data.count {
                result.opusData = data.subdata(in: offset..<(offset + frameLength))
                offset += frameLength
            }

            if isTerminator { break }
            // For now, only process first frame
            break
        }

        result.isValid = true
        return result
    }

    /// Read Mumble-specific varint encoding (different from protobuf!)
    /// Returns (value, bytesConsumed)
    private static func readMumbleVarint(data: Data, offset: Int) -> (UInt64, Int) {
        guard offset < data.count else { return (0, 0) }

        let b0 = Int(data[offset]) & 0xFF

        if (b0 & 0x80) == 0 {
            // Single byte: 0xxxxxxx (7 bits)
            return (UInt64(b0), 1)
        } else if (b0 & 0xC0) == 0x80 {
            // Two bytes: 10xxxxxx xxxxxxxx (14 bits)
            guard offset + 1 < data.count else { return (0, 0) }
            let b1 = Int(data[offset + 1]) & 0xFF
            let value = ((b0 & 0x3F) << 8) | b1
            return (UInt64(value), 2)
        } else if (b0 & 0xE0) == 0xC0 {
            // Three bytes: 110xxxxx xxxxxxxx xxxxxxxx (21 bits)
            guard offset + 2 < data.count else { return (0, 0) }
            let b1 = Int(data[offset + 1]) & 0xFF
            let b2 = Int(data[offset + 2]) & 0xFF
            let value = ((b0 & 0x1F) << 16) | (b1 << 8) | b2
            return (UInt64(value), 3)
        } else if (b0 & 0xF0) == 0xE0 {
            // Four bytes: 1110xxxx xxxxxxxx xxxxxxxx xxxxxxxx (28 bits)
            guard offset + 3 < data.count else { return (0, 0) }
            let b1 = Int(data[offset + 1]) & 0xFF
            let b2 = Int(data[offset + 2]) & 0xFF
            let b3 = Int(data[offset + 3]) & 0xFF
            let value = ((b0 & 0x0F) << 24) | (b1 << 16) | (b2 << 8) | b3
            return (UInt64(value), 4)
        } else if b0 == 0xF0 {
            // Five bytes: 11110000 xxxxxxxx xxxxxxxx xxxxxxxx xxxxxxxx (32 bits)
            guard offset + 4 < data.count else { return (0, 0) }
            let b1 = Int(data[offset + 1]) & 0xFF
            let b2 = Int(data[offset + 2]) & 0xFF
            let b3 = Int(data[offset + 3]) & 0xFF
            let b4 = Int(data[offset + 4]) & 0xFF
            let value = (b1 << 24) | (b2 << 16) | (b3 << 8) | b4
            return (UInt64(value), 5)
        } else {
            // Negative or special values - not used for audio
            return (0, 1)
        }
    }
}
