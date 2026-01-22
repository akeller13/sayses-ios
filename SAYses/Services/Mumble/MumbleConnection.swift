import Foundation
import Network

protocol MumbleConnectionDelegate: AnyObject {
    func connectionStateChanged(_ state: ConnectionState)
    func channelsUpdated(_ channels: [Channel])
    func usersUpdated(_ users: [User])
    func serverInfoReceived(_ info: ServerInfo)
    func connectionRejected(reason: MumbleRejectReason, message: String)
    func connectionError(_ message: String)
    func permissionQueryReceived(channelId: UInt32, permissions: Int, flush: Bool)
    func audioReceived(session: UInt32, pcmData: UnsafePointer<Int16>, frames: Int, sequence: Int64)
    func userAudioEnded(session: UInt32)
}

class MumbleConnection: MumbleTcpConnectionDelegate {
    weak var delegate: MumbleConnectionDelegate?

    private let tcpConnection = MumbleTcpConnection()
    private var username: String = ""

    private(set) var connectionState: ConnectionState = .disconnected
    private(set) var localSession: UInt32 = 0
    private(set) var channels: [UInt32: Channel] = [:]
    private(set) var users: [UInt32: User] = [:]

    // Track known channels for permission requests
    private var knownChannelIds: Set<UInt32> = []
    private var serverSyncReceived = false

    // Per-user Opus decoders for audio playback
    private var userDecoders: [UInt32: OpusCodecBridge] = [:]
    private let decoderQueue = DispatchQueue(label: "de.sempara.mumble.decoder", qos: .userInteractive)

    // PCM buffer for decoded audio (max 120ms at 48kHz mono = 5760 samples)
    // Opus packets can contain multiple frames (10ms, 20ms, 40ms, 60ms, or 120ms)
    private var decodedPcmBuffer = [Int16](repeating: 0, count: 5760)

    init() {
        tcpConnection.delegate = self
    }

    // MARK: - Public Methods

    func connect(
        host: String,
        port: Int,
        username: String,
        certificateP12Base64: String,
        certificatePassword: String
    ) {
        self.username = username

        guard let certificateData = Data(base64Encoded: certificateP12Base64) else {
            delegate?.connectionError("Ungültiges Zertifikat-Format")
            return
        }

        // Reset state
        knownChannelIds.removeAll()
        serverSyncReceived = false
        channels.removeAll()
        users.removeAll()

        connectionState = .connecting
        delegate?.connectionStateChanged(.connecting)

        tcpConnection.connect(
            host: host,
            port: port,
            certificateP12Data: certificateData,
            certificatePassword: certificatePassword
        )
    }

    func disconnect() {
        tcpConnection.disconnect()
        connectionState = .disconnected
        channels.removeAll()
        users.removeAll()
        knownChannelIds.removeAll()
        serverSyncReceived = false
        localSession = 0
        userDecoders.removeAll()
        delegate?.connectionStateChanged(.disconnected)
    }

    func joinChannel(_ channelId: UInt32) {
        tcpConnection.sendJoinChannel(channelId: channelId)
    }

    func setSelfMute(_ mute: Bool) {
        tcpConnection.sendSelfMute(mute: mute, deaf: false)
    }

    func setSelfDeaf(_ deaf: Bool) {
        tcpConnection.sendSelfMute(mute: deaf, deaf: deaf)
    }

    func sendAudioPacket(opusData: Data, sequenceNumber: Int64, isTerminator: Bool = false) {
        tcpConnection.sendAudioPacket(opusData: opusData, sequenceNumber: sequenceNumber, isTerminator: isTerminator)
    }

    func getChannelList() -> [Channel] {
        return Array(channels.values).sorted { $0.position < $1.position }
    }

    func getUserList() -> [User] {
        return Array(users.values)
    }

    func getUsersInChannel(_ channelId: UInt32) -> [User] {
        return users.values.filter { $0.channelId == channelId }
    }

    /// Update permissions for a channel
    func updateChannelPermissions(channelId: UInt32, permissions: Int, flush: Bool) {
        if flush {
            // Reset all permissions to unknown
            for (id, var channel) in channels {
                channel.permissions = -1
                channels[id] = channel
            }
        }

        if var channel = channels[channelId] {
            channel.permissions = permissions
            channels[channelId] = channel
            print("[MumbleConnection] Updated permissions for channel \(channelId): 0x\(String(permissions, radix: 16))")
        }
    }

    // MARK: - MumbleTcpConnectionDelegate

    func connectionStateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            connectionState = .connected
            delegate?.connectionStateChanged(.connected)
            // Send authenticate after version is sent
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self = self else { return }
                self.tcpConnection.sendAuthenticate(username: self.username)
            }
        case .failed(let error):
            connectionState = .failed
            delegate?.connectionError("Verbindungsfehler: \(error.localizedDescription)")
            delegate?.connectionStateChanged(.failed)
        case .cancelled:
            connectionState = .disconnected
            delegate?.connectionStateChanged(.disconnected)
        default:
            break
        }
    }

    func connectionReceivedMessage(type: MumbleMessageType, data: Data) {
        // Log ALL incoming messages to debug audio reception
        if type == .udpTunnel {
            NSLog("[MumbleConnection] >>> UDP_TUNNEL received! dataLen=%d", data.count)
        }

        switch type {
        case .serverSync:
            handleServerSync(data: data)
        case .channelState:
            handleChannelState(data: data)
        case .channelRemove:
            handleChannelRemove(data: data)
        case .userState:
            handleUserState(data: data)
        case .userRemove:
            handleUserRemove(data: data)
        case .reject:
            handleReject(data: data)
        case .codecVersion:
            handleCodecVersion(data: data)
        case .permissionQuery:
            handlePermissionQuery(data: data)
        case .ping:
            // Ping response received, could calculate latency
            break
        case .udpTunnel:
            handleAudioPacket(data: data)
        default:
            print("[MumbleConnection] Unhandled message type: \(type)")
        }
    }

    func connectionError(_ error: Error) {
        connectionState = .failed
        delegate?.connectionError("Verbindungsfehler: \(error.localizedDescription)")
        delegate?.connectionStateChanged(.failed)
    }

    // MARK: - Message Handlers

    private func handleServerSync(data: Data) {
        let sync = MumbleParsers.parseServerSync(data: data)
        print("[MumbleConnection] ServerSync: session=\(sync.session), maxBandwidth=\(sync.maxBandwidth)")

        localSession = sync.session
        serverSyncReceived = true
        connectionState = .synchronized

        // Request permissions for all known channels
        print("[MumbleConnection] Requesting permissions for \(knownChannelIds.count) known channels")
        for channelId in knownChannelIds {
            requestChannelPermissions(channelId)
        }

        let info = ServerInfo(
            welcomeMessage: sync.welcomeText,
            maxBandwidth: sync.maxBandwidth,
            maxUsers: 0,
            serverVersion: "1.3.0"
        )
        delegate?.serverInfoReceived(info)
        delegate?.connectionStateChanged(.synchronized)
    }

    private func handleChannelState(data: Data) {
        let state = MumbleParsers.parseChannelState(data: data)
        print("[MumbleConnection] ChannelState: id=\(state.channelId), name=\(state.name), parent=\(state.parent)")

        // Track channel and request permissions if we already received ServerSync
        let isNew = knownChannelIds.insert(state.channelId).inserted
        if isNew && serverSyncReceived {
            print("[MumbleConnection] Requesting permissions for new channel \(state.channelId)")
            requestChannelPermissions(state.channelId)
        }

        // Get existing permissions if available
        let existingPermissions = channels[state.channelId]?.permissions ?? -1

        // parentId: For root channel (id=0), parent is typically 0 or not set
        // For other channels, parent is the actual parent channel ID
        let parentId: UInt32? = state.channelId == 0 ? nil : state.parent

        let channel = Channel(
            id: state.channelId,
            parentId: parentId,
            name: state.name,
            position: state.position,
            userCount: getUsersInChannel(state.channelId).count,
            depth: 0,  // Will be calculated during hierarchy building
            permissions: existingPermissions
        )

        channels[state.channelId] = channel
        updateChannelUserCounts()
        delegate?.channelsUpdated(getChannelList())
    }

    private func handleChannelRemove(data: Data) {
        let decoder = ProtobufDecoder(data: data)
        while !decoder.isAtEnd {
            guard let (fieldNumber, wireType) = decoder.readTag() else { break }
            if fieldNumber == 1, let channelId = decoder.readUInt32() {
                print("[MumbleConnection] ChannelRemove: id=\(channelId)")
                channels.removeValue(forKey: channelId)
                knownChannelIds.remove(channelId)
            } else {
                decoder.skip(wireType: wireType)
            }
        }
        delegate?.channelsUpdated(getChannelList())
    }

    private func handleUserState(data: Data) {
        let state = MumbleParsers.parseUserState(data: data)
        print("[MumbleConnection] UserState: session=\(state.session), name=\(state.name), channel=\(state.channelId)")

        // Update existing user or create new
        var user = users[state.session] ?? User(session: state.session, name: "")

        if !state.name.isEmpty {
            user = User(
                session: state.session,
                channelId: state.channelId != 0 ? state.channelId : user.channelId,
                name: state.name,
                isMuted: state.mute,
                isDeafened: state.deaf,
                isSelfMuted: state.selfMute,
                isSelfDeafened: state.selfDeaf,
                isSuppressed: state.suppress
            )
        } else if state.channelId != 0 {
            // Just a channel change
            user = User(
                session: user.session,
                channelId: state.channelId,
                name: user.name,
                isMuted: state.mute || user.isMuted,
                isDeafened: state.deaf || user.isDeafened,
                isSelfMuted: state.selfMute || user.isSelfMuted,
                isSelfDeafened: state.selfDeaf || user.isSelfDeafened,
                isSuppressed: state.suppress || user.isSuppressed
            )
        }

        users[state.session] = user
        updateChannelUserCounts()
        delegate?.usersUpdated(getUserList())
    }

    private func handleUserRemove(data: Data) {
        let remove = MumbleParsers.parseUserRemove(data: data)
        print("[MumbleConnection] UserRemove: session=\(remove.session)")

        users.removeValue(forKey: remove.session)
        removeDecoder(for: remove.session)
        delegate?.userAudioEnded(session: remove.session)
        updateChannelUserCounts()
        delegate?.usersUpdated(getUserList())
    }

    private func handleReject(data: Data) {
        let reject = MumbleParsers.parseReject(data: data)
        print("[MumbleConnection] Reject: type=\(reject.type), reason=\(reject.reason)")

        connectionState = .failed
        delegate?.connectionRejected(reason: reject.type, message: reject.reason)
        delegate?.connectionStateChanged(.failed)
    }

    private func handleCodecVersion(data: Data) {
        let codec = MumbleParsers.parseCodecVersion(data: data)
        print("[MumbleConnection] CodecVersion: opus=\(codec.opus)")
    }

    private func handlePermissionQuery(data: Data) {
        let query = MumbleParsers.parsePermissionQuery(data: data)
        print("[MumbleConnection] PermissionQuery: channel=\(query.channelId), permissions=0x\(String(query.permissions, radix: 16)), flush=\(query.flush)")

        // Update local channel permissions
        updateChannelPermissions(channelId: query.channelId, permissions: Int(query.permissions), flush: query.flush)

        // Notify delegate
        delegate?.permissionQueryReceived(channelId: query.channelId, permissions: Int(query.permissions), flush: query.flush)

        // Update channels to reflect new permissions
        delegate?.channelsUpdated(getChannelList())
    }

    private func handleAudioPacket(data: Data) {
        let packet = MumbleParsers.parseAudioPacket(data: data)

        // Debug logging for audio reception
        NSLog("[MumbleConnection] Audio packet: valid=%d, session=%u, localSession=%u, codec=%d, dataLen=%d", packet.isValid ? 1 : 0, packet.senderSession, localSession, packet.codecType, packet.opusData.count)

        // Ignore invalid packets or packets from self
        guard packet.isValid else {
            print("[MumbleConnection] Ignoring invalid audio packet")
            return
        }
        guard packet.senderSession != localSession else {
            print("[MumbleConnection] Ignoring own audio packet")
            return
        }
        guard packet.codecType == 4 else {
            print("[MumbleConnection] Ignoring non-Opus audio (codec=\(packet.codecType))")
            return
        }

        // Handle end of transmission (empty opus data means user stopped talking)
        // NOTE: The terminator bit (0x2000) in frame header just means "last frame in this packet"
        // which is always true for single-frame packets. It does NOT mean end of transmission!
        // End of transmission is signaled by an empty opus frame.
        if packet.opusData.isEmpty {
            print("[MumbleConnection] End of transmission from session \(packet.senderSession)")
            delegate?.userAudioEnded(session: packet.senderSession)
            return
        }

        NSLog("[MumbleConnection] Decoding audio: session=%u, seq=%lld, bytes=%d", packet.senderSession, packet.sequenceNumber, packet.opusData.count)

        // Decode on decoder queue to avoid blocking
        decoderQueue.async { [weak self] in
            self?.decodeAndDeliverAudio(packet: packet)
        }
    }

    private func decodeAndDeliverAudio(packet: ParsedAudioPacket) {
        // Get or create decoder for this user
        guard let decoder = getOrCreateDecoder(for: packet.senderSession) else {
            print("[MumbleConnection] ERROR: Could not get decoder for session \(packet.senderSession)")
            return
        }

        // Decode Opus to PCM
        let decodedFrames = decoder.decode(withOpusData: packet.opusData,
                                            outputBuffer: &decodedPcmBuffer,
                                            maxFrames: Int32(decodedPcmBuffer.count))

        guard decodedFrames > 0 else {
            print("[MumbleConnection] Failed to decode audio from session \(packet.senderSession), result=\(decodedFrames)")
            return
        }

        NSLog("[MumbleConnection] Decoded %d frames from session %u", decodedFrames, packet.senderSession)

        // Deliver decoded audio to delegate
        decodedPcmBuffer.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            delegate?.audioReceived(session: packet.senderSession,
                                   pcmData: baseAddress,
                                   frames: Int(decodedFrames),
                                   sequence: packet.sequenceNumber)
        }
    }

    private func getOrCreateDecoder(for session: UInt32) -> OpusCodecBridge? {
        if let existing = userDecoders[session] {
            return existing
        }

        // Create new decoder with same parameters as encoder
        guard let decoder = OpusCodecBridge() else {
            print("[MumbleConnection] ERROR: Failed to create Opus decoder for session \(session)")
            return nil
        }
        userDecoders[session] = decoder
        print("[MumbleConnection] Created Opus decoder for session \(session)")
        return decoder
    }

    /// Remove decoder for a specific user (call when user leaves)
    func removeDecoder(for session: UInt32) {
        if userDecoders.removeValue(forKey: session) != nil {
            print("[MumbleConnection] Removed Opus decoder for session \(session)")
        }
    }

    // MARK: - Permission Requests

    private func requestChannelPermissions(_ channelId: UInt32) {
        let data = MumbleMessages.buildPermissionQuery(channelId: channelId)
        tcpConnection.sendMessage(type: .permissionQuery, data: data)
    }

    // MARK: - Helpers

    private func updateChannelUserCounts() {
        for (channelId, var channel) in channels {
            let count = getUsersInChannel(channelId).count
            channel.userCount = count
            channels[channelId] = channel
        }
    }
}
