import Foundation
import CryptoKit

/// Delegate protocol for SSE tracking position events
protocol TrackingSSEDelegate: AnyObject {
    /// Called when new position data arrives
    func positionsUpdated(_ positions: [TrackingPosition])
}

/// SSE client for receiving real-time GPS position updates from the backend
class TrackingSSE {

    // MARK: - Properties

    weak var delegate: TrackingSSEDelegate?

    private let subdomain: String
    private let certificateHash: String
    private let channelId: UInt32
    private let sseSession: URLSession
    private var streamTask: Task<Void, Never>?
    private var isRunning = false
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private let reconnectDelay: TimeInterval = 3.0

    // MARK: - Initialization

    init(subdomain: String, certificateHash: String, channelId: UInt32) {
        self.subdomain = subdomain
        self.certificateHash = certificateHash
        self.channelId = channelId

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 86400
        self.sseSession = URLSession(configuration: config)
    }

    // MARK: - Public Methods

    func start() {
        guard !isRunning else {
            print("[TrackingSSE] Already running")
            return
        }

        isRunning = true
        reconnectAttempts = 0
        connect()
    }

    func stop() {
        print("[TrackingSSE] Stopping...")
        isRunning = false
        streamTask?.cancel()
        streamTask = nil
    }

    // MARK: - Private Methods

    private func connect() {
        guard isRunning else { return }

        print("[TrackingSSE] Connecting to \(subdomain) for channel \(channelId)...")

        // Generate HMAC authentication as query parameters
        let timestamp = String(Int(Date().timeIntervalSince1970 * 1000))
        let signature = generateHmacSignature(timestamp: timestamp)

        guard let url = URL(string: "https://\(subdomain).sayseswork.com/api/gps/tracking/stream?channel_id=\(channelId)&latest_only=true&cert=\(certificateHash)&ts=\(timestamp)&sig=\(signature)") else {
            print("[TrackingSSE] Invalid URL")
            return
        }

        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        streamTask = Task { [weak self] in
            guard let self = self else { return }

            do {
                let (bytes, response) = try await self.sseSession.bytes(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    print("[TrackingSSE] Invalid response")
                    self.handleReconnect()
                    return
                }

                guard httpResponse.statusCode == 200 else {
                    print("[TrackingSSE] Authentication failed: \(httpResponse.statusCode)")
                    self.handleReconnect()
                    return
                }

                print("[TrackingSSE] Connected successfully")
                self.reconnectAttempts = 0

                for try await line in bytes.lines {
                    if Task.isCancelled { break }
                    self.processLine(line)
                }

                print("[TrackingSSE] Stream ended")
                if self.isRunning {
                    self.handleReconnect()
                }

            } catch {
                if Task.isCancelled {
                    print("[TrackingSSE] Connection cancelled")
                } else {
                    print("[TrackingSSE] Connection error: \(error.localizedDescription)")
                    self.handleReconnect()
                }
            }
        }
    }

    private func generateHmacSignature(timestamp: String) -> String {
        let message = "\(timestamp)\(certificateHash)"
        let key = SymmetricKey(data: Data(certificateHash.utf8))
        let signature = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return signature.map { String(format: "%02x", $0) }.joined()
    }

    private func handleReconnect() {
        guard isRunning else { return }

        reconnectAttempts += 1

        if reconnectAttempts <= maxReconnectAttempts {
            print("[TrackingSSE] Reconnecting in \(reconnectDelay)s (attempt \(reconnectAttempts)/\(maxReconnectAttempts))...")

            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(self?.reconnectDelay ?? 3.0) * 1_000_000_000)
                self?.connect()
            }
        } else {
            print("[TrackingSSE] Max reconnect attempts reached, giving up")
            isRunning = false
        }
    }

    private func processLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.isEmpty || trimmed.hasPrefix(":") { return }

        if trimmed.hasPrefix("data: ") {
            let jsonString = String(trimmed.dropFirst(6))
            handleTrackingEvent(jsonString)
        }
    }

    private func handleTrackingEvent(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8) else { return }

        do {
            let event = try JSONDecoder().decode(TrackingEvent.self, from: data)

            guard event.type == "positions" else { return }

            Task { @MainActor [weak self] in
                self?.delegate?.positionsUpdated(event.positions)
            }
        } catch {
            print("[TrackingSSE] Failed to decode tracking event: \(error)")
        }
    }
}

// MARK: - Data Models

struct TrackingEvent: Codable {
    let type: String
    let positions: [TrackingPosition]
}

struct TrackingPosition: Codable {
    let username: String
    let displayName: String?
    let latitude: Double
    let longitude: Double
    let recordedAt: String?

    enum CodingKeys: String, CodingKey {
        case username, latitude, longitude
        case displayName = "display_name"
        case recordedAt = "recorded_at"
    }
}
