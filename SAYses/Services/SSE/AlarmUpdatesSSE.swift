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
class AlarmUpdatesSSE: NSObject {

    // MARK: - Properties

    weak var delegate: AlarmUpdatesSSEDelegate?

    private let subdomain: String
    private let certificateHash: String
    private var session: URLSession?
    private var dataTask: URLSessionDataTask?
    private var isRunning = false
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5  // More attempts for critical alarms
    private let reconnectDelay: TimeInterval = 3.0

    private var dataBuffer = Data()

    // MARK: - Initialization

    init(subdomain: String, certificateHash: String) {
        self.subdomain = subdomain
        self.certificateHash = certificateHash
        super.init()
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
        dataTask?.cancel()
        dataTask = nil
        session?.invalidateAndCancel()
        session = nil
        dataBuffer.removeAll()
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
        request.timeoutInterval = 300 // 5 minutes

        // Create session with delegate
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        dataTask = session?.dataTask(with: request)
        dataTask?.resume()
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

            DispatchQueue.global().asyncAfter(deadline: .now() + reconnectDelay) { [weak self] in
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

    private func processSSEData(_ data: Data) {
        dataBuffer.append(data)

        // Process complete lines from buffer
        guard let text = String(data: dataBuffer, encoding: .utf8) else { return }

        let lines = text.components(separatedBy: "\n")

        // Keep incomplete last line in buffer
        var processedBytes = 0
        for (index, line) in lines.enumerated() {
            if index == lines.count - 1 && !text.hasSuffix("\n") {
                // Last line is incomplete, keep it in buffer
                break
            }

            processedBytes += line.utf8.count + 1 // +1 for newline
            processLine(line)
        }

        // Remove processed data from buffer
        if processedBytes > 0 && processedBytes <= dataBuffer.count {
            dataBuffer.removeFirst(processedBytes)
        }
    }

    private func processLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Skip empty lines and comments
        if trimmed.isEmpty || trimmed.hasPrefix(":") {
            if trimmed.hasPrefix(": connected") {
                print("[AlarmUpdatesSSE] Connected successfully")
                reconnectAttempts = 0
                Task { @MainActor [weak self] in
                    self?.delegate?.alarmSSEConnectionStateChanged(isConnected: true)
                }
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

// MARK: - URLSessionDataDelegate

extension AlarmUpdatesSSE: URLSessionDataDelegate {

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let httpResponse = response as? HTTPURLResponse {
            print("[AlarmUpdatesSSE] Received response: \(httpResponse.statusCode)")

            if httpResponse.statusCode == 200 {
                completionHandler(.allow)
            } else {
                print("[AlarmUpdatesSSE] Authentication failed: \(httpResponse.statusCode)")
                completionHandler(.cancel)
                handleReconnect()
            }
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        processSSEData(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            let nsError = error as NSError
            if nsError.code == NSURLErrorCancelled {
                print("[AlarmUpdatesSSE] Connection cancelled")
            } else {
                print("[AlarmUpdatesSSE] Connection error: \(error.localizedDescription)")
                handleReconnect()
            }
        } else {
            print("[AlarmUpdatesSSE] Connection completed")
            if isRunning {
                handleReconnect()
            }
        }

        Task { @MainActor [weak self] in
            self?.delegate?.alarmSSEConnectionStateChanged(isConnected: false)
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
