import Foundation
import CryptoKit

/// Delegate protocol for SSE alarm update events
protocol AlarmUpdatesSSEDelegate: AnyObject {
    /// Called when a new alarm starts
    func alarmStarted(_ data: AlarmSSEData)

    /// Called when an alarm is updated (position, voice message)
    func alarmUpdated(_ data: AlarmSSEData)

    /// Called when an alarm is ended
    func alarmEnded(alarmId: String, closedAt: Date, closedBy: String?)

    /// Called when the SSE connection state changes
    func alarmSSEConnectionStateChanged(isConnected: Bool)
}

/// SSE client for receiving real-time alarm updates from the backend
class AlarmUpdatesSSE {

    // MARK: - Properties

    weak var delegate: AlarmUpdatesSSEDelegate?

    private let subdomain: String
    private let certificateHash: String
    private let sseSession: URLSession
    private var streamTask: Task<Void, Never>?
    private var isRunning = false
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private let reconnectDelay: TimeInterval = 3.0

    // MARK: - Initialization

    init(subdomain: String, certificateHash: String) {
        self.subdomain = subdomain
        self.certificateHash = certificateHash

        // SSE session with long timeouts for streaming connections
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300   // 5 minutes between data
        config.timeoutIntervalForResource = 86400  // 24 hours max
        self.sseSession = URLSession(configuration: config)
    }

    // MARK: - Public Methods

    /// Start the SSE connection
    func start() {
        guard !isRunning else {
            print("[AlarmUpdatesSSE] Already running")
            return
        }

        isRunning = true
        reconnectAttempts = 0
        connect()
    }

    /// Stop the SSE connection
    func stop() {
        print("[AlarmUpdatesSSE] Stopping...")
        isRunning = false
        streamTask?.cancel()
        streamTask = nil
        Task { @MainActor [weak self] in
            self?.delegate?.alarmSSEConnectionStateChanged(isConnected: false)
        }
    }

    // MARK: - Private Methods

    private func connect() {
        guard isRunning else { return }

        print("[AlarmUpdatesSSE] Connecting to \(subdomain)...")

        // Generate HMAC authentication
        let timestamp = String(Int(Date().timeIntervalSince1970 * 1000))
        let signature = generateHmacSignature(timestamp: timestamp)

        // Build URL
        guard let url = URL(string: "https://\(subdomain).sayseswork.com/api/mobile/alarm-updates/stream") else {
            print("[AlarmUpdatesSSE] Invalid URL")
            return
        }

        // Create request with authentication headers
        var request = URLRequest(url: url)
        request.setValue(certificateHash, forHTTPHeaderField: "X-Certificate-Hash")
        request.setValue(timestamp, forHTTPHeaderField: "X-Timestamp")
        request.setValue(signature, forHTTPHeaderField: "X-Signature")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        streamTask = Task { [weak self] in
            guard let self = self else { return }

            do {
                let (bytes, response) = try await self.sseSession.bytes(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    print("[AlarmUpdatesSSE] Invalid response")
                    self.handleReconnect()
                    return
                }

                guard httpResponse.statusCode == 200 else {
                    print("[AlarmUpdatesSSE] Authentication failed: \(httpResponse.statusCode)")
                    self.handleReconnect()
                    return
                }

                print("[AlarmUpdatesSSE] Connected successfully")
                self.reconnectAttempts = 0
                await MainActor.run {
                    self.delegate?.alarmSSEConnectionStateChanged(isConnected: true)
                }

                for try await line in bytes.lines {
                    if Task.isCancelled { break }
                    self.processLine(line)
                }

                // Stream ended naturally
                print("[AlarmUpdatesSSE] Stream ended")
                if self.isRunning {
                    await MainActor.run {
                        self.delegate?.alarmSSEConnectionStateChanged(isConnected: false)
                    }
                    self.handleReconnect()
                }

            } catch {
                if Task.isCancelled {
                    print("[AlarmUpdatesSSE] Connection cancelled")
                } else {
                    print("[AlarmUpdatesSSE] Connection error: \(error.localizedDescription)")
                    await MainActor.run {
                        self.delegate?.alarmSSEConnectionStateChanged(isConnected: false)
                    }
                    self.handleReconnect()
                }
            }
        }
    }

    private func generateHmacSignature(timestamp: String) -> String {
        // Signature format: HMAC-SHA256(key=certificate_hash, message=timestamp+certificate_hash)
        let message = "\(timestamp)\(certificateHash)"
        let key = SymmetricKey(data: Data(certificateHash.utf8))
        let signature = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return signature.map { String(format: "%02x", $0) }.joined()
    }

    private func handleReconnect() {
        guard isRunning else { return }

        reconnectAttempts += 1

        if reconnectAttempts <= maxReconnectAttempts {
            print("[AlarmUpdatesSSE] Reconnecting in \(reconnectDelay)s (attempt \(reconnectAttempts)/\(maxReconnectAttempts))...")

            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(self?.reconnectDelay ?? 3.0) * 1_000_000_000)
                self?.connect()
            }
        } else {
            print("[AlarmUpdatesSSE] Max reconnect attempts reached, giving up")
            isRunning = false
            Task { @MainActor [weak self] in
                self?.delegate?.alarmSSEConnectionStateChanged(isConnected: false)
            }
        }
    }

    private func processLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Skip empty lines and comments
        if trimmed.isEmpty || trimmed.hasPrefix(":") {
            if trimmed.hasPrefix(": connected") {
                print("[AlarmUpdatesSSE] Server confirmed connection")
            } else if trimmed.hasPrefix(": heartbeat") {
                // Heartbeat received, connection is alive
            }
            return
        }

        // Parse SSE data lines
        if trimmed.hasPrefix("data: ") {
            let jsonString = String(trimmed.dropFirst(6))
            handleAlarmEvent(jsonString)
        }
    }

    private func handleAlarmEvent(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8) else {
            print("[AlarmUpdatesSSE] Failed to convert JSON string to data")
            return
        }

        do {
            let event = try JSONDecoder().decode(AlarmSSEEvent.self, from: data)

            print("[AlarmUpdatesSSE] Received event: \(event.event)")

            Task { @MainActor [weak self] in
                switch event.event {
                case "alarm_started":
                    if let alarmData = event.alarm {
                        self?.delegate?.alarmStarted(alarmData)
                    }
                case "alarm_updated":
                    if let alarmData = event.alarm {
                        self?.delegate?.alarmUpdated(alarmData)
                    }
                case "alarm_ended":
                    if let alarmData = event.alarm {
                        let closedAt = Date(timeIntervalSince1970: Double(alarmData.closedAt ?? 0) / 1000)
                        self?.delegate?.alarmEnded(alarmId: alarmData.id, closedAt: closedAt, closedBy: alarmData.closedBy)
                    }
                default:
                    print("[AlarmUpdatesSSE] Unknown event type: \(event.event)")
                }
            }
        } catch {
            print("[AlarmUpdatesSSE] Failed to decode alarm event: \(error)")
        }
    }
}

// MARK: - Data Models

struct AlarmSSEEvent: Codable {
    let event: String
    let alarm: AlarmSSEData?
    let timestamp: Int64
}

struct AlarmSSEData: Codable {
    let id: String
    let alarmStartUserName: String?
    let alarmStartUserDisplayname: String?
    let channelId: Int?
    let channelName: String?
    let triggeredAt: Int64?
    let latitude: Double?
    let longitude: Double?
    let locationType: String?
    let positionUpdatedAt: Int64?
    let hasVoiceMessage: Bool?
    let voiceMessageText: String?
    let closedAt: Int64?
    let closedBy: String?

    enum CodingKeys: String, CodingKey {
        case id
        case alarmStartUserName = "alarm_start_user_name"
        case alarmStartUserDisplayname = "alarm_start_user_displayname"
        case channelId = "channel_id"
        case channelName = "channel_name"
        case triggeredAt = "triggered_at"
        case latitude, longitude
        case locationType = "location_type"
        case positionUpdatedAt = "position_updated_at"
        case hasVoiceMessage = "has_voice_message"
        case voiceMessageText = "voice_message_text"
        case closedAt = "closed_at"
        case closedBy = "closed_by"
    }
}
