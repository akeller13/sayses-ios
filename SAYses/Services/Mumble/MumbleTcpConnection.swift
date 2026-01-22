import Foundation
import Network
import Security
import os.log

private let logger = Logger(subsystem: "com.sayses.app", category: "MumbleTcp")

protocol MumbleTcpConnectionDelegate: AnyObject {
    func connectionStateChanged(_ state: NWConnection.State)
    func connectionReceivedMessage(type: MumbleMessageType, data: Data)
    func connectionError(_ error: Error)
}

class MumbleTcpConnection {
    weak var delegate: MumbleTcpConnectionDelegate?

    private var connection: NWConnection?
    private var host: String = ""
    private var port: Int = 64738
    private let queue = DispatchQueue(label: "de.sempara.mumble.tcp", qos: .userInitiated)

    private var isConnected = false
    private var pingTimer: DispatchSourceTimer?
    private var lastPingTime: UInt64 = 0

    // MARK: - Public Methods

    func connect(
        host: String,
        port: Int,
        certificateP12Data: Data,
        certificatePassword: String
    ) {
        self.host = host
        self.port = port

        logger.info("Connecting to \(host):\(port)")

        // Create TLS options with client certificate
        let tlsOptions = NWProtocolTLS.Options()

        do {
            // Load PKCS#12 certificate
            let identity = try loadIdentity(from: certificateP12Data, password: certificatePassword)

            sec_protocol_options_set_local_identity(
                tlsOptions.securityProtocolOptions,
                identity
            )

            // Trust all server certificates (Mumble servers often use self-signed)
            sec_protocol_options_set_verify_block(
                tlsOptions.securityProtocolOptions,
                { _, trust, completionHandler in
                    completionHandler(true)
                },
                queue
            )

        } catch {
            logger.error("Failed to load certificate: \(error.localizedDescription)")
            delegate?.connectionError(error)
            return
        }

        // Create TCP options
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true // Disable Nagle's algorithm for low-latency audio
        tcpOptions.connectionTimeout = 10

        // Create parameters with TLS and TCP
        let parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)

        // Create endpoint
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: UInt16(port))
        )

        // Create connection
        connection = NWConnection(to: endpoint, using: parameters)

        connection?.stateUpdateHandler = { [weak self] state in
            self?.handleStateChange(state)
        }

        connection?.start(queue: queue)
    }

    func disconnect() {
        logger.info("Disconnecting")
        stopPingTimer()
        connection?.cancel()
        connection = nil
        isConnected = false
    }

    func sendMessage(type: MumbleMessageType, data: Data) {
        guard isConnected, let connection = connection else {
            logger.warning("Cannot send - not connected")
            return
        }

        // Mumble message format: 2-byte type + 4-byte length + data
        var packet = Data()

        // Type (2 bytes, big endian)
        var typeValue = type.rawValue.bigEndian
        packet.append(Data(bytes: &typeValue, count: 2))

        // Length (4 bytes, big endian)
        var lengthValue = UInt32(data.count).bigEndian
        packet.append(Data(bytes: &lengthValue, count: 4))

        // Data
        packet.append(data)

        connection.send(content: packet, completion: .contentProcessed { error in
            if let error = error {
                logger.error("Send error: \(error.localizedDescription)")
            }
        })
    }

    // MARK: - Private Methods

    private func handleStateChange(_ state: NWConnection.State) {
        logger.info("State: \(String(describing: state))")

        switch state {
        case .ready:
            isConnected = true
            startReceiving()
            startPingTimer()
            sendVersion()
        case .failed(let error):
            isConnected = false
            delegate?.connectionError(error)
        case .cancelled:
            isConnected = false
        default:
            break
        }

        delegate?.connectionStateChanged(state)
    }

    private func startReceiving() {
        receiveNextMessage()
    }

    private func receiveNextMessage() {
        guard let connection = connection else { return }

        // First, read the 6-byte header (2 type + 4 length)
        connection.receive(minimumIncompleteLength: 6, maximumLength: 6) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                logger.error("Receive header error: \(error.localizedDescription)")
                self.delegate?.connectionError(error)
                return
            }

            guard let headerData = data, headerData.count == 6 else {
                if isComplete {
                    logger.info("Connection closed by server")
                }
                return
            }

            // Parse header
            let typeValue = UInt16(headerData[0]) << 8 | UInt16(headerData[1])
            let lengthValue = UInt32(headerData[2]) << 24 | UInt32(headerData[3]) << 16 |
                              UInt32(headerData[4]) << 8 | UInt32(headerData[5])

            // Skip message body for unknown types but still read it to stay in sync!
            guard let messageType = MumbleMessageType(rawValue: typeValue) else {
                logger.warning("Unknown message type: \(typeValue), length: \(lengthValue)")
                if lengthValue > 0 {
                    // WICHTIG: Body trotzdem lesen um im Takt zu bleiben!
                    self.skipMessageBody(length: Int(lengthValue))
                } else {
                    self.receiveNextMessage()
                }
                return
            }

            if lengthValue == 0 {
                // No body, process immediately
                self.delegate?.connectionReceivedMessage(type: messageType, data: Data())
                self.receiveNextMessage()
                return
            }

            // Read the message body
            self.receiveMessageBody(type: messageType, length: Int(lengthValue))
        }
    }

    private func receiveMessageBody(type: MumbleMessageType, length: Int) {
        guard let connection = connection else { return }

        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, error in
            guard let self = self else { return }

            if let error = error {
                logger.error("Receive body error: \(error.localizedDescription)")
                self.delegate?.connectionError(error)
                return
            }

            guard let bodyData = data else {
                self.receiveNextMessage()
                return
            }

            self.delegate?.connectionReceivedMessage(type: type, data: bodyData)
            self.receiveNextMessage()
        }
    }

    /// Skip message body for unknown message types to stay in sync
    private func skipMessageBody(length: Int) {
        guard let connection = connection else { return }

        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] _, _, _, error in
            guard let self = self else { return }

            if let error = error {
                logger.error("Skip body error: \(error.localizedDescription)")
                self.delegate?.connectionError(error)
                return
            }

            // Body skipped, continue with next message
            self.receiveNextMessage()
        }
    }

    // MARK: - Certificate Loading

    private func loadIdentity(from p12Data: Data, password: String) throws -> sec_identity_t {
        let options: [String: Any] = [kSecImportExportPassphrase as String: password]

        var items: CFArray?
        let status = SecPKCS12Import(p12Data as CFData, options as CFDictionary, &items)

        guard status == errSecSuccess else {
            throw NSError(
                domain: "MumbleTcp",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Zertifikat konnte nicht geladen werden (Status: \(status))"]
            )
        }

        guard let itemsArray = items as? [[String: Any]],
              let firstItem = itemsArray.first,
              let identity = firstItem[kSecImportItemIdentity as String] else {
            throw NSError(
                domain: "MumbleTcp",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Kein gültiges Zertifikat gefunden"]
            )
        }

        // swiftlint:disable:next force_cast
        let secIdentity = identity as! SecIdentity
        return sec_identity_create(secIdentity)!
    }

    // MARK: - Protocol Messages

    private func sendVersion() {
        let versionData = MumbleMessages.buildVersion()
        sendMessage(type: .version, data: versionData)
    }

    func sendAuthenticate(username: String, password: String? = nil) {
        let authData = MumbleMessages.buildAuthenticate(username: username, password: password)
        sendMessage(type: .authenticate, data: authData)
    }

    func sendPing() {
        lastPingTime = UInt64(Date().timeIntervalSince1970 * 1000)
        let pingData = MumbleMessages.buildPing(timestamp: lastPingTime)
        sendMessage(type: .ping, data: pingData)
    }

    func sendJoinChannel(channelId: UInt32) {
        let userData = MumbleMessages.buildUserState(channelId: channelId)
        sendMessage(type: .userState, data: userData)
    }

    func sendSelfMute(mute: Bool, deaf: Bool) {
        let userData = MumbleMessages.buildUserStateMute(selfMute: mute, selfDeaf: deaf)
        sendMessage(type: .userState, data: userData)
    }

    func sendAudioPacket(opusData: Data, sequenceNumber: Int64, isTerminator: Bool = false) {
        let audioPacket = MumbleMessages.buildAudioPacket(
            opusData: opusData,
            sequenceNumber: sequenceNumber,
            isTerminator: isTerminator
        )
        sendMessage(type: .udpTunnel, data: audioPacket)
    }

    // MARK: - Ping Timer

    private func startPingTimer() {
        pingTimer = DispatchSource.makeTimerSource(queue: queue)
        pingTimer?.schedule(deadline: .now() + 5, repeating: 5)
        pingTimer?.setEventHandler { [weak self] in
            self?.sendPing()
        }
        pingTimer?.resume()
    }

    private func stopPingTimer() {
        pingTimer?.cancel()
        pingTimer = nil
    }
}
