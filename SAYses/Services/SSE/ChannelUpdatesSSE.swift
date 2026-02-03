import Foundation
import CryptoKit

/// Delegate protocol for SSE channel update events
protocol ChannelUpdatesSSEDelegate: AnyObject {
    /// Called when channel permissions have changed
    /// - Parameters:
    ///   - action: "granted" or "revoked"
    ///   - channelIds: Backend channel UUIDs that were affected
    func channelPermissionsChanged(action: String, channelIds: [String])

    /// Called when the SSE connection state changes
    func sseConnectionStateChanged(isConnected: Bool)
}

/// SSE client for receiving real-time channel permission updates from the backend
class ChannelUpdatesSSE: NSObject {

    // MARK: - Properties

    weak var delegate: ChannelUpdatesSSEDelegate?

    private let subdomain: String
    private let certificateHash: String
    private var session: URLSession?
    private var dataTask: URLSessionDataTask?
    private var isRunning = false
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 3
    private let reconnectDelay: TimeInterval = 5.0

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
            print("[ChannelUpdatesSSE] Already running")
            return
        }

        isRunning = true
        reconnectAttempts = 0
        connect()
    }

    /// Stop the SSE connection
    func stop() {
        print("[ChannelUpdatesSSE] Stopping...")
        isRunning = false
        dataTask?.cancel()
        dataTask = nil
        session?.invalidateAndCancel()
        session = nil
        dataBuffer.removeAll()
        delegate?.sseConnectionStateChanged(isConnected: false)
    }

    // MARK: - Private Methods

    private func connect() {
        guard isRunning else { return }

        print("[ChannelUpdatesSSE] Connecting to \(subdomain)...")

        // Generate HMAC authentication
        let timestamp = String(Int(Date().timeIntervalSince1970 * 1000))
        let signature = generateHmacSignature(timestamp: timestamp)

        // Build URL
        guard let url = URL(string: "https://\(subdomain).sayseswork.com/api/mobile/channel-updates/stream") else {
            print("[ChannelUpdatesSSE] Invalid URL")
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
            print("[ChannelUpdatesSSE] Reconnecting in \(reconnectDelay)s (attempt \(reconnectAttempts)/\(maxReconnectAttempts))...")

            DispatchQueue.global().asyncAfter(deadline: .now() + reconnectDelay) { [weak self] in
                self?.connect()
            }
        } else {
            print("[ChannelUpdatesSSE] Max reconnect attempts reached, giving up")
            isRunning = false
            delegate?.sseConnectionStateChanged(isConnected: false)
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
                print("[ChannelUpdatesSSE] Connected successfully")
                reconnectAttempts = 0
                delegate?.sseConnectionStateChanged(isConnected: true)
            } else if trimmed.hasPrefix(": heartbeat") {
                // Heartbeat received, connection is alive
            }
            return
        }

        // Parse SSE data lines
        if trimmed.hasPrefix("data: ") {
            let jsonString = String(trimmed.dropFirst(6))
            handleChannelUpdate(jsonString)
        }
    }

    private func handleChannelUpdate(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8) else {
            print("[ChannelUpdatesSSE] Failed to convert JSON string to data")
            return
        }

        do {
            let update = try JSONDecoder().decode(ChannelUpdateEvent.self, from: data)

            if update.event == "channel_permissions_changed" {
                print("[ChannelUpdatesSSE] Received channel update: action=\(update.action), channels=\(update.channelIds)")

                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.channelPermissionsChanged(action: update.action, channelIds: update.channelIds)
                }
            }
        } catch {
            print("[ChannelUpdatesSSE] Failed to decode channel update: \(error)")
        }
    }
}

// MARK: - URLSessionDataDelegate

extension ChannelUpdatesSSE: URLSessionDataDelegate {

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let httpResponse = response as? HTTPURLResponse {
            print("[ChannelUpdatesSSE] Received response: \(httpResponse.statusCode)")

            if httpResponse.statusCode == 200 {
                completionHandler(.allow)
            } else {
                print("[ChannelUpdatesSSE] Authentication failed: \(httpResponse.statusCode)")
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
                print("[ChannelUpdatesSSE] Connection cancelled")
            } else {
                print("[ChannelUpdatesSSE] Connection error: \(error.localizedDescription)")
                handleReconnect()
            }
        } else {
            print("[ChannelUpdatesSSE] Connection completed")
            if isRunning {
                handleReconnect()
            }
        }

        delegate?.sseConnectionStateChanged(isConnected: false)
    }
}

// MARK: - Data Models

private struct ChannelUpdateEvent: Codable {
    let event: String
    let action: String
    let channelIds: [String]
    let timestamp: Int64

    enum CodingKeys: String, CodingKey {
        case event, action, timestamp
        case channelIds = "channel_ids"
    }
}
