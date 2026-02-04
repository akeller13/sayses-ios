import Foundation
import CommonCrypto

class SemparaAPIClient {
    private let centralBaseURL = "https://api.sayses.com"
    private let tenantURLTemplate = "https://%@.sayseswork.com"

    private let session: URLSession
    private let sseSession: URLSession  // Separate session for SSE with longer timeouts

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)

        // SSE session with much longer timeouts for streaming connections
        let sseConfig = URLSessionConfiguration.default
        sseConfig.timeoutIntervalForRequest = 300  // 5 minutes between data
        sseConfig.timeoutIntervalForResource = 86400  // 24 hours max
        self.sseSession = URLSession(configuration: sseConfig)
    }

    // MARK: - Workspace Lookup

    func lookupWorkspace(email: String) async throws -> WorkspaceLookupResponse {
        guard let encodedEmail = email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(centralBaseURL)/api/lookup?email=\(encodedEmail)") else {
            throw APIError.invalidURL
        }

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        return try decoder.decode(WorkspaceLookupResponse.self, from: data)
    }

    // MARK: - Tenant API

    func getTenantBaseURL(subdomain: String) -> String {
        return String(format: tenantURLTemplate, subdomain)
    }

    func fetchMumbleCredentials(subdomain: String, accessToken: String) async throws -> MumbleCredentials {
        let baseURL = getTenantBaseURL(subdomain: subdomain)
        guard let url = URL(string: "\(baseURL)/api/mumble/credentials") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        if let jsonString = String(data: data, encoding: .utf8) {
            // Print truncated response for debugging
            let preview = String(jsonString.prefix(200))
            print("[API] Response preview: \(preview)...")

            // Try to print keys
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                print("[API] Response keys: \(json.keys.sorted())")
            }
        }

        let decoder = JSONDecoder()
        do {
            return try decoder.decode(MumbleCredentials.self, from: data)
        } catch let decodingError as DecodingError {
            print("[API] Decoding error: \(decodingError)")
            switch decodingError {
            case .keyNotFound(let key, let context):
                print("[API] Missing key: '\(key.stringValue)' in \(context.codingPath.map { $0.stringValue })")
            case .typeMismatch(let type, let context):
                print("[API] Type mismatch: expected \(type) at \(context.codingPath.map { $0.stringValue })")
            case .valueNotFound(let type, let context):
                print("[API] Value not found: \(type) at \(context.codingPath.map { $0.stringValue })")
            default:
                print("[API] Other decoding error: \(decodingError)")
            }
            throw APIError.decodingError
        } catch {
            print("[API] Unknown error: \(error)")
            throw APIError.decodingError
        }
    }

    // MARK: - Settings API (Certificate Auth)

    func getSettings(subdomain: String, certificateHash: String) async throws -> AlarmSettings {
        let baseURL = getTenantBaseURL(subdomain: subdomain)
        guard let url = URL(string: "\(baseURL)/api/user/settings") else {
            throw APIError.invalidURL
        }

        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let signature = signNoBody(certificateHash: certificateHash, timestamp: timestamp)

        var request = URLRequest(url: url)
        request.setValue(certificateHash, forHTTPHeaderField: "X-Certificate-Hash")
        request.setValue(String(timestamp), forHTTPHeaderField: "X-Timestamp")
        request.setValue(signature, forHTTPHeaderField: "X-Signature")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        return try decoder.decode(AlarmSettings.self, from: data)
    }

    // MARK: - User Permissions API (Certificate Auth)

    func getUserAlarmPermissions(subdomain: String, certificateHash: String) async throws -> UserAlarmPermissionsResponse {
        let baseURL = getTenantBaseURL(subdomain: subdomain)
        guard let url = URL(string: "\(baseURL)/api/user/alarm-permissions") else {
            throw APIError.invalidURL
        }

        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let signature = signNoBody(certificateHash: certificateHash, timestamp: timestamp)

        var request = URLRequest(url: url)
        request.setValue(certificateHash, forHTTPHeaderField: "X-Certificate-Hash")
        request.setValue(String(timestamp), forHTTPHeaderField: "X-Timestamp")
        request.setValue(signature, forHTTPHeaderField: "X-Signature")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        return try decoder.decode(UserAlarmPermissionsResponse.self, from: data)
    }

    // MARK: - Alarm API (Certificate Auth)

    /// Trigger an alarm - POST /api/alarm
    func triggerAlarm(subdomain: String, certificateHash: String, request: AlarmRequest) async throws -> AlarmResponse {
        let baseURL = getTenantBaseURL(subdomain: subdomain)
        guard let url = URL(string: "\(baseURL)/api/alarm") else {
            throw APIError.invalidURL
        }

        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let bodyData = try encoder.encode(request)
        let bodyJson = String(data: bodyData, encoding: .utf8) ?? ""
        let signature = signWithBody(certificateHash: certificateHash, timestamp: timestamp, body: bodyJson)

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(certificateHash, forHTTPHeaderField: "X-Certificate-Hash")
        urlRequest.setValue(String(timestamp), forHTTPHeaderField: "X-Timestamp")
        urlRequest.setValue(signature, forHTTPHeaderField: "X-Signature")
        urlRequest.httpBody = bodyData

        print("[API] POST /api/alarm - triggering alarm")
        print("[API]   URL: \(url)")
        print("[API]   Request body: \(bodyJson)")
        print("[API]   X-Certificate-Hash: \(String(certificateHash.prefix(16)))...")
        print("[API]   X-Timestamp: \(timestamp)")

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        print("[API]   Response status: \(httpResponse.statusCode)")
        if let responseBody = String(data: data, encoding: .utf8) {
            print("[API]   Response body: \(responseBody)")
        }

        guard httpResponse.statusCode == 200 || httpResponse.statusCode == 201 else {
            print("[API] triggerAlarm failed: HTTP \(httpResponse.statusCode)")
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(AlarmResponse.self, from: data)
    }

    /// End an alarm - POST /api/alarm/end
    func endAlarm(subdomain: String, certificateHash: String, request: AlarmEndRequest) async throws -> AlarmResponse {
        let baseURL = getTenantBaseURL(subdomain: subdomain)
        guard let url = URL(string: "\(baseURL)/api/alarm/end") else {
            throw APIError.invalidURL
        }

        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let bodyData = try encoder.encode(request)
        let bodyJson = String(data: bodyData, encoding: .utf8) ?? ""
        let signature = signWithBody(certificateHash: certificateHash, timestamp: timestamp, body: bodyJson)

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(certificateHash, forHTTPHeaderField: "X-Certificate-Hash")
        urlRequest.setValue(String(timestamp), forHTTPHeaderField: "X-Timestamp")
        urlRequest.setValue(signature, forHTTPHeaderField: "X-Signature")
        urlRequest.httpBody = bodyData

        print("[API] POST /api/alarm/end - ending alarm")

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            print("[API] endAlarm failed: HTTP \(httpResponse.statusCode)")
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(AlarmResponse.self, from: data)
    }

    /// Upload voice message - POST /api/alarm/{id}/voice (multipart)
    func uploadVoiceMessage(subdomain: String, certificateHash: String, alarmId: String, filePath: URL) async throws {
        let baseURL = getTenantBaseURL(subdomain: subdomain)
        guard let url = URL(string: "\(baseURL)/api/alarm/\(alarmId)/voice") else {
            throw APIError.invalidURL
        }

        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        // For multipart, signature is: timestamp + certHash + alarmId
        let message = "\(timestamp)\(certificateHash)\(alarmId)"
        let signature = signRaw(certificateHash: certificateHash, message: message)

        // Read file data
        let fileData = try Data(contentsOf: filePath)

        // Build multipart body
        let boundary = UUID().uuidString
        var body = Data()

        // Add file part (field name must be "file" to match Android/backend expectation)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"voice.m4a\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/mp4\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(certificateHash, forHTTPHeaderField: "X-Certificate-Hash")
        urlRequest.setValue(String(timestamp), forHTTPHeaderField: "X-Timestamp")
        urlRequest.setValue(signature, forHTTPHeaderField: "X-Signature")
        urlRequest.httpBody = body

        print("[API] POST /api/alarm/\(alarmId)/voice - uploading voice message (\(fileData.count) bytes)")
        print("[API]   URL: \(url)")
        print("[API]   X-Certificate-Hash: \(String(certificateHash.prefix(16)))...")
        print("[API]   X-Timestamp: \(timestamp)")
        print("[API]   Message to sign: \(message)")

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        print("[API]   Response status: \(httpResponse.statusCode)")
        if let responseBody = String(data: data, encoding: .utf8) {
            print("[API]   Response body: \(responseBody)")
        }

        guard httpResponse.statusCode == 200 || httpResponse.statusCode == 201 else {
            print("[API] uploadVoiceMessage failed: HTTP \(httpResponse.statusCode)")
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        print("[API] Voice message uploaded successfully")
    }

    /// Download voice message - GET /api/alarm/{id}/voice
    func downloadVoiceMessage(subdomain: String, certificateHash: String, alarmId: String) async throws -> URL {
        let baseURL = getTenantBaseURL(subdomain: subdomain)
        guard let url = URL(string: "\(baseURL)/api/alarm/\(alarmId)/voice") else {
            throw APIError.invalidURL
        }

        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        // Signature format: timestamp + certHash + alarmId (same as upload)
        let message = "\(timestamp)\(certificateHash)\(alarmId)"
        let signature = signRaw(certificateHash: certificateHash, message: message)

        print("[API] GET /api/alarm/\(alarmId)/voice - downloading voice message")
        print("[API]   URL: \(url)")
        print("[API]   X-Certificate-Hash: \(certificateHash)")
        print("[API]   X-Timestamp: \(timestamp)")
        print("[API]   Message to sign: \(message)")
        print("[API]   X-Signature: \(signature)")

        var request = URLRequest(url: url)
        request.setValue(certificateHash, forHTTPHeaderField: "X-Certificate-Hash")
        request.setValue(String(timestamp), forHTTPHeaderField: "X-Timestamp")
        request.setValue(signature, forHTTPHeaderField: "X-Signature")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            print("[API] downloadVoiceMessage failed: HTTP \(httpResponse.statusCode)")
            if let errorBody = String(data: data, encoding: .utf8) {
                print("[API]   Error body: \(errorBody)")
            }
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        // Voice messages are always AAC in M4A container (recorded by Android/iOS)
        // Always use .m4a extension regardless of Content-Type header
        let ext = ".m4a"

        if let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") {
            print("[API] Voice Content-Type: \(contentType) (ignoring, using .m4a)")
        }

        // Save to cache directory
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let filePath = cacheDir.appendingPathComponent("voice_\(alarmId)\(ext)")

        try data.write(to: filePath)
        print("[API] Voice message downloaded to: \(filePath.lastPathComponent) (\(data.count) bytes)")

        return filePath
    }

    /// Upload position batch - POST /api/alarm/{id}/positions
    func uploadPositions(subdomain: String, certificateHash: String, alarmId: String, positions: [PositionData]) async throws -> PositionUploadResponse {
        let baseURL = getTenantBaseURL(subdomain: subdomain)
        guard let url = URL(string: "\(baseURL)/api/alarm/\(alarmId)/positions") else {
            throw APIError.invalidURL
        }

        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let request = PositionBatchRequest(positions: positions)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let bodyData = try encoder.encode(request)
        let bodyJson = String(data: bodyData, encoding: .utf8) ?? ""
        let signature = signWithBody(certificateHash: certificateHash, timestamp: timestamp, body: bodyJson)

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(certificateHash, forHTTPHeaderField: "X-Certificate-Hash")
        urlRequest.setValue(String(timestamp), forHTTPHeaderField: "X-Timestamp")
        urlRequest.setValue(signature, forHTTPHeaderField: "X-Signature")
        urlRequest.httpBody = bodyData

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(PositionUploadResponse.self, from: data)
    }

    // MARK: - Unified GPS Tracking API

    /// Upload GPS positions to unified endpoint - POST /api/gps/{session_id}/positions
    /// Backend routes based on session_id prefix:
    /// - `alarm_{id}` → AlarmPositionLog
    /// - `dispatcher_{id}` → DispatcherRequestPositionLog
    /// - `tracking_{hash}` → GPSPositionLog (general tracking)
    func uploadGPSPositions(subdomain: String, certificateHash: String, sessionId: String, positions: [PositionData]) async throws {
        let baseURL = getTenantBaseURL(subdomain: subdomain)
        guard let url = URL(string: "\(baseURL)/api/gps/\(sessionId)/positions") else {
            throw APIError.invalidURL
        }

        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let request = PositionBatchRequest(positions: positions)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let bodyData = try encoder.encode(request)
        let bodyJson = String(data: bodyData, encoding: .utf8) ?? ""
        let signature = signWithBody(certificateHash: certificateHash, timestamp: timestamp, body: bodyJson)

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(certificateHash, forHTTPHeaderField: "X-Certificate-Hash")
        urlRequest.setValue(String(timestamp), forHTTPHeaderField: "X-Timestamp")
        urlRequest.setValue(signature, forHTTPHeaderField: "X-Signature")
        urlRequest.httpBody = bodyData

        NSLog("[API] POST %@ - %d positions", url.absoluteString, positions.count)
        print("[API] POST \(url.absoluteString) - \(positions.count) positions")

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        if httpResponse.statusCode != 200 && httpResponse.statusCode != 201 {
            let responseStr = String(data: data, encoding: .utf8) ?? "no body"
            NSLog("[API] GPS upload failed: HTTP %d - %@", httpResponse.statusCode, responseStr)
            print("[API] GPS upload failed: HTTP \(httpResponse.statusCode) - \(responseStr)")
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        NSLog("[API] GPS positions uploaded successfully for session %@", sessionId)
        print("[API] GPS positions uploaded successfully")
    }

    /// Get open alarms - GET /api/user/open-alarms
    /// NOTE: This endpoint uses a DIFFERENT signature format than other GET endpoints!
    /// Format: timestamp + certificateHash (no colon separator)
    func getOpenAlarms(subdomain: String, certificateHash: String) async throws -> OpenAlarmsResponse {
        let baseURL = getTenantBaseURL(subdomain: subdomain)
        guard let url = URL(string: "\(baseURL)/api/user/open-alarms") else {
            throw APIError.invalidURL
        }

        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        // Special signature format for open-alarms: timestamp + certificateHash (NO colon!)
        let signatureData = "\(timestamp)\(certificateHash)"
        let signature = signRaw(certificateHash: certificateHash, message: signatureData)

        print("[API] GET \(url.absoluteString)")
        print("[API] X-Certificate-Hash: \(String(certificateHash.prefix(8)))...")
        print("[API] X-Timestamp: \(timestamp)")

        var request = URLRequest(url: url)
        request.setValue(certificateHash, forHTTPHeaderField: "X-Certificate-Hash")
        request.setValue(String(timestamp), forHTTPHeaderField: "X-Timestamp")
        request.setValue(signature, forHTTPHeaderField: "X-Signature")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        print("[API] Response status: \(httpResponse.statusCode)")

        // Log raw response for debugging
        if let responseString = String(data: data, encoding: .utf8) {
            print("[API] Response body: \(responseString)")
        }

        guard httpResponse.statusCode == 200 else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        // Debug: Try to extract voice_message and voice_message_text fields from raw JSON
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let alarmsArray = json["alarms"] as? [[String: Any]] {
            print("[API] DEBUG: Raw JSON has \(alarmsArray.count) alarms")
            for (idx, alarmJson) in alarmsArray.enumerated() {
                if let voiceMsg = alarmJson["voice_message"] {
                    print("[API] DEBUG: Alarm[\(idx)] voice_message RAW: \(voiceMsg)")
                } else {
                    print("[API] DEBUG: Alarm[\(idx)] voice_message is NIL in raw JSON")
                }
                if let voiceText = alarmJson["voice_message_text"] as? String {
                    print("[API] DEBUG: Alarm[\(idx)] voice_message_text RAW: \(voiceText)")
                } else {
                    print("[API] DEBUG: Alarm[\(idx)] voice_message_text is NIL in raw JSON")
                }
            }
        }

        do {
            let result = try decoder.decode(OpenAlarmsResponse.self, from: data)
            print("[API] Decoded \(result.alarms.count) open alarms")
            for alarm in result.alarms {
                print("[API]   Alarm \(alarm.id): lat=\(alarm.latitude ?? -999), lon=\(alarm.longitude ?? -999), locationType=\(alarm.locationType ?? "nil")")
                print("[API]   Alarm \(alarm.id): voiceMessage=\(alarm.voiceMessage != nil ? "EXISTS url=\(alarm.voiceMessage!.url)" : "NIL"), voiceMessageText=\(alarm.voiceMessageText ?? "NIL")")
            }
            return result
        } catch {
            print("[API] Decoding error: \(error)")
            // Log more details about the decoding error
            if let decodingError = error as? DecodingError {
                switch decodingError {
                case .keyNotFound(let key, let context):
                    print("[API]   Key not found: \(key.stringValue) at \(context.codingPath)")
                case .typeMismatch(let type, let context):
                    print("[API]   Type mismatch: expected \(type) at \(context.codingPath)")
                case .valueNotFound(let type, let context):
                    print("[API]   Value not found: \(type) at \(context.codingPath)")
                case .dataCorrupted(let context):
                    print("[API]   Data corrupted: \(context.debugDescription)")
                @unknown default:
                    print("[API]   Unknown decoding error")
                }
            }
            throw APIError.decodingError
        }
    }

    // MARK: - Dispatcher Request API (User)

    /// Create a new dispatcher request - POST /api/user/dispatcher-request
    /// Signature format: {certificate_hash}:{timestamp}:{request_body_json}
    func createDispatcherRequest(subdomain: String, certificateHash: String, request: DispatcherRequestCreateRequest) async throws -> DispatcherRequestCreateResponse {
        let baseURL = getTenantBaseURL(subdomain: subdomain)
        guard let url = URL(string: "\(baseURL)/api/user/dispatcher-request") else {
            throw APIError.invalidURL
        }

        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let bodyData = try encoder.encode(request)
        let bodyJson = String(data: bodyData, encoding: .utf8) ?? ""
        let signature = signWithBody(certificateHash: certificateHash, timestamp: timestamp, body: bodyJson)

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(certificateHash, forHTTPHeaderField: "X-Certificate-Hash")
        urlRequest.setValue(String(timestamp), forHTTPHeaderField: "X-Timestamp")
        urlRequest.setValue(signature, forHTTPHeaderField: "X-Signature")
        urlRequest.httpBody = bodyData

        print("[API] POST /api/user/dispatcher-request - creating dispatcher request")
        print("[API]   URL: \(url)")
        print("[API]   Request body: \(bodyJson)")

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        print("[API]   Response status: \(httpResponse.statusCode)")
        if let responseBody = String(data: data, encoding: .utf8) {
            print("[API]   Response body: \(responseBody)")
        }

        guard httpResponse.statusCode == 200 || httpResponse.statusCode == 201 else {
            print("[API] createDispatcherRequest failed: HTTP \(httpResponse.statusCode)")
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(DispatcherRequestCreateResponse.self, from: data)
    }

    /// Upload voice message for dispatcher request - POST /api/user/dispatcher-request/{id}/voice
    /// Signature format: {certificate_hash}:{timestamp}:{request_id}
    func uploadDispatcherRequestVoice(subdomain: String, certificateHash: String, requestId: String, filePath: URL) async throws {
        let baseURL = getTenantBaseURL(subdomain: subdomain)
        guard let url = URL(string: "\(baseURL)/api/user/dispatcher-request/\(requestId)/voice") else {
            throw APIError.invalidURL
        }

        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let message = "\(certificateHash):\(timestamp):\(requestId)"
        let signature = signRaw(certificateHash: certificateHash, message: message)

        // Read file data
        let fileData = try Data(contentsOf: filePath)

        // Build multipart body
        let boundary = UUID().uuidString
        var body = Data()

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"voice.m4a\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/mp4\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(certificateHash, forHTTPHeaderField: "X-Certificate-Hash")
        urlRequest.setValue(String(timestamp), forHTTPHeaderField: "X-Timestamp")
        urlRequest.setValue(signature, forHTTPHeaderField: "X-Signature")
        urlRequest.httpBody = body

        print("[API] POST /api/user/dispatcher-request/\(requestId)/voice - uploading voice message (\(fileData.count) bytes)")

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        print("[API]   Response status: \(httpResponse.statusCode)")
        if let responseBody = String(data: data, encoding: .utf8) {
            print("[API]   Response body: \(responseBody)")
        }

        guard httpResponse.statusCode == 200 || httpResponse.statusCode == 201 else {
            print("[API] uploadDispatcherRequestVoice failed: HTTP \(httpResponse.statusCode)")
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        print("[API] Dispatcher request voice message uploaded successfully")
    }

    /// Cancel a dispatcher request - POST /api/user/dispatcher-request/{id}/cancel
    /// Signature format: {certificate_hash}:{timestamp}:{request_id}
    func cancelDispatcherRequest(subdomain: String, certificateHash: String, requestId: String) async throws {
        let baseURL = getTenantBaseURL(subdomain: subdomain)
        guard let url = URL(string: "\(baseURL)/api/user/dispatcher-request/\(requestId)/cancel") else {
            throw APIError.invalidURL
        }

        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let message = "\(certificateHash):\(timestamp):\(requestId)"
        let signature = signRaw(certificateHash: certificateHash, message: message)

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(certificateHash, forHTTPHeaderField: "X-Certificate-Hash")
        urlRequest.setValue(String(timestamp), forHTTPHeaderField: "X-Timestamp")
        urlRequest.setValue(signature, forHTTPHeaderField: "X-Signature")

        print("[API] POST /api/user/dispatcher-request/\(requestId)/cancel - cancelling dispatcher request")

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        print("[API]   Response status: \(httpResponse.statusCode)")
        if let responseBody = String(data: data, encoding: .utf8) {
            print("[API]   Response body: \(responseBody)")
        }

        guard httpResponse.statusCode == 200 else {
            print("[API] cancelDispatcherRequest failed: HTTP \(httpResponse.statusCode)")
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        print("[API] Dispatcher request cancelled successfully")
    }

    /// Update position for dispatcher request - POST /api/user/dispatcher-request/{id}/position
    /// Signature format: {certificate_hash}:{timestamp}:{request_body_json}
    func updateDispatcherRequestPosition(subdomain: String, certificateHash: String, requestId: String, position: DispatcherPositionUpdate) async throws {
        let baseURL = getTenantBaseURL(subdomain: subdomain)
        guard let url = URL(string: "\(baseURL)/api/user/dispatcher-request/\(requestId)/position") else {
            throw APIError.invalidURL
        }

        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let bodyData = try encoder.encode(position)
        let bodyJson = String(data: bodyData, encoding: .utf8) ?? ""
        let signature = signWithBody(certificateHash: certificateHash, timestamp: timestamp, body: bodyJson)

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(certificateHash, forHTTPHeaderField: "X-Certificate-Hash")
        urlRequest.setValue(String(timestamp), forHTTPHeaderField: "X-Timestamp")
        urlRequest.setValue(signature, forHTTPHeaderField: "X-Signature")
        urlRequest.httpBody = bodyData

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            print("[API] updateDispatcherRequestPosition failed: HTTP \(httpResponse.statusCode)")
            if let responseBody = String(data: data, encoding: .utf8) {
                print("[API]   Response body: \(responseBody)")
            }
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        print("[API] Dispatcher request position updated successfully")
    }

    /// Get dispatcher request history for the current user - GET /api/user/dispatcher-request-history
    /// Signature format: {timestamp}{certificate_hash} (no colon, timestamp first)
    func getDispatcherRequestHistory(subdomain: String, certificateHash: String, limit: Int = 5) async throws -> DispatcherRequestHistoryResponse {
        let baseURL = getTenantBaseURL(subdomain: subdomain)
        guard let url = URL(string: "\(baseURL)/api/user/dispatcher-request-history?limit=\(limit)") else {
            throw APIError.invalidURL
        }

        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        // Signature format: {timestamp}{certificate_hash} (no colon)
        let signatureData = "\(timestamp)\(certificateHash)"
        let signature = signRaw(certificateHash: certificateHash, message: signatureData)

        print("[API] GET \(url.absoluteString)")

        var request = URLRequest(url: url)
        request.setValue(certificateHash, forHTTPHeaderField: "X-Certificate-Hash")
        request.setValue(String(timestamp), forHTTPHeaderField: "X-Timestamp")
        request.setValue(signature, forHTTPHeaderField: "X-Signature")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        print("[API] Dispatcher request history response status: \(httpResponse.statusCode)")

        guard httpResponse.statusCode == 200 else {
            if let responseBody = String(data: data, encoding: .utf8) {
                print("[API]   Response body: \(responseBody)")
            }
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(DispatcherRequestHistoryResponse.self, from: data)
    }

    /// Stream dispatcher request history updates via SSE
    /// GET /api/user/dispatcher-request-history/stream
    /// Returns an AsyncThrowingStream that yields DispatcherRequestHistoryResponse on each update
    func streamDispatcherRequestHistory(
        subdomain: String,
        certificateHash: String,
        limit: Int = 10
    ) -> AsyncThrowingStream<DispatcherRequestHistoryResponse, Error> {
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let baseURL = getTenantBaseURL(subdomain: subdomain)
                    guard let url = URL(string: "\(baseURL)/api/user/dispatcher-request-history/stream?limit=\(limit)") else {
                        continuation.finish(throwing: APIError.invalidURL)
                        return
                    }

                    let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
                    // Signature format: {timestamp}{certificate_hash} (no colon)
                    let signatureData = "\(timestamp)\(certificateHash)"
                    let signature = signRaw(certificateHash: certificateHash, message: signatureData)

                    var request = URLRequest(url: url)
                    request.setValue(certificateHash, forHTTPHeaderField: "X-Certificate-Hash")
                    request.setValue(String(timestamp), forHTTPHeaderField: "X-Timestamp")
                    request.setValue(signature, forHTTPHeaderField: "X-Signature")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

                    let (bytes, response) = try await sseSession.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.finish(throwing: APIError.invalidResponse)
                        return
                    }

                    guard httpResponse.statusCode == 200 else {
                        continuation.finish(throwing: APIError.httpError(statusCode: httpResponse.statusCode))
                        return
                    }

                    let decoder = JSONDecoder()
                    decoder.keyDecodingStrategy = .convertFromSnakeCase

                    for try await line in bytes.lines {
                        if Task.isCancelled { break }

                        if line.hasPrefix("data: ") {
                            let jsonString = String(line.dropFirst(6))
                            if let jsonData = jsonString.data(using: .utf8) {
                                if let historyResponse = try? decoder.decode(DispatcherRequestHistoryResponse.self, from: jsonData) {
                                    continuation.yield(historyResponse)
                                }
                            }
                        }
                    }

                    continuation.finish()

                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    // MARK: - AudioCast API

    /// Get AudioCast list for a channel - GET /api/mobile/audiocast/list
    /// Signature format: {certificateHash}:{timestamp}:{channelId}
    func getAudioCastList(subdomain: String, certificateHash: String, channelId: Int) async throws -> AudioCastListResponse {
        let baseURL = getTenantBaseURL(subdomain: subdomain)
        guard let url = URL(string: "\(baseURL)/api/mobile/audiocast/list?channel_id=\(channelId)") else {
            throw APIError.invalidURL
        }

        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let signatureData = "\(certificateHash):\(timestamp):\(channelId)"
        let signature = signRaw(certificateHash: certificateHash, message: signatureData)

        print("[API] GET \(url.absoluteString)")

        var request = URLRequest(url: url)
        request.setValue(certificateHash, forHTTPHeaderField: "X-Certificate-Hash")
        request.setValue(String(timestamp), forHTTPHeaderField: "X-Timestamp")
        request.setValue(signature, forHTTPHeaderField: "X-Signature")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        print("[API] AudioCast list response status: \(httpResponse.statusCode)")

        guard httpResponse.statusCode == 200 else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        return try decoder.decode(AudioCastListResponse.self, from: data)
    }

    /// Start AudioCast playback - POST /api/mobile/audiocast/play
    /// Signature format: {certificateHash}:{timestamp}:{channelId}:{audiocastId1,audiocastId2,...}
    func playAudioCast(subdomain: String, certificateHash: String, request: AudioCastPlayRequest) async throws -> AudioCastPlayResponse {
        let baseURL = getTenantBaseURL(subdomain: subdomain)
        guard let url = URL(string: "\(baseURL)/api/mobile/audiocast/play") else {
            throw APIError.invalidURL
        }

        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let audiocastIdsStr = request.audiocastIds.joined(separator: ",")
        let signatureData = "\(certificateHash):\(timestamp):\(request.channelId):\(audiocastIdsStr)"
        let signature = signRaw(certificateHash: certificateHash, message: signatureData)

        print("[API] POST \(url.absoluteString)")
        print("[API] Playing \(request.audiocastIds.count) AudioCasts in channel \(request.channelId)")

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(certificateHash, forHTTPHeaderField: "X-Certificate-Hash")
        urlRequest.setValue(String(timestamp), forHTTPHeaderField: "X-Timestamp")
        urlRequest.setValue(signature, forHTTPHeaderField: "X-Signature")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoder = JSONEncoder()
        urlRequest.httpBody = try encoder.encode(request)

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        print("[API] AudioCast play response status: \(httpResponse.statusCode)")

        // Parse response even for non-200 status (may contain error details)
        let decoder = JSONDecoder()
        let playResponse = try decoder.decode(AudioCastPlayResponse.self, from: data)

        if httpResponse.statusCode != 200 && !playResponse.success {
            // Return the response with error info
            return playResponse
        }

        return playResponse
    }

    /// Pause/Resume AudioCast playback - POST /api/mobile/audiocast/pause
    /// Signature format: {certificateHash}:{timestamp}:{channelId}:{playbackId}
    func pauseAudioCast(subdomain: String, certificateHash: String, request: AudioCastPauseRequest) async throws -> AudioCastPauseResponse {
        let baseURL = getTenantBaseURL(subdomain: subdomain)
        guard let url = URL(string: "\(baseURL)/api/mobile/audiocast/pause") else {
            throw APIError.invalidURL
        }

        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let signatureData = "\(certificateHash):\(timestamp):\(request.channelId):\(request.playbackId)"
        let signature = signRaw(certificateHash: certificateHash, message: signatureData)

        print("[API] POST \(url.absoluteString)")

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(certificateHash, forHTTPHeaderField: "X-Certificate-Hash")
        urlRequest.setValue(String(timestamp), forHTTPHeaderField: "X-Timestamp")
        urlRequest.setValue(signature, forHTTPHeaderField: "X-Signature")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoder = JSONEncoder()
        urlRequest.httpBody = try encoder.encode(request)

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        print("[API] AudioCast pause response status: \(httpResponse.statusCode)")

        // Handle 404 (no active playback) gracefully
        if httpResponse.statusCode == 404 {
            return AudioCastPauseResponse(
                success: false,
                message: "no_active_playback",
                playbackStatus: nil,
                error: "no_active_playback"
            )
        }

        let decoder = JSONDecoder()
        return try decoder.decode(AudioCastPauseResponse.self, from: data)
    }

    /// Stop AudioCast playback - POST /api/mobile/audiocast/stop
    /// Signature format: {certificateHash}:{timestamp}:{channelId}:{playbackId}
    func stopAudioCast(subdomain: String, certificateHash: String, request: AudioCastStopRequest) async throws -> AudioCastStopResponse {
        let baseURL = getTenantBaseURL(subdomain: subdomain)
        guard let url = URL(string: "\(baseURL)/api/mobile/audiocast/stop") else {
            throw APIError.invalidURL
        }

        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let signatureData = "\(certificateHash):\(timestamp):\(request.channelId):\(request.playbackId)"
        let signature = signRaw(certificateHash: certificateHash, message: signatureData)

        print("[API] POST \(url.absoluteString)")

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(certificateHash, forHTTPHeaderField: "X-Certificate-Hash")
        urlRequest.setValue(String(timestamp), forHTTPHeaderField: "X-Timestamp")
        urlRequest.setValue(signature, forHTTPHeaderField: "X-Signature")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoder = JSONEncoder()
        urlRequest.httpBody = try encoder.encode(request)

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        print("[API] AudioCast stop response status: \(httpResponse.statusCode)")

        // Handle 404 (no active playback) gracefully
        if httpResponse.statusCode == 404 {
            return AudioCastStopResponse(
                success: false,
                message: "no_active_playback",
                playbackStatus: nil,
                error: "no_active_playback"
            )
        }

        let decoder = JSONDecoder()
        return try decoder.decode(AudioCastStopResponse.self, from: data)
    }

    // MARK: - HMAC Signing

    private func signNoBody(certificateHash: String, timestamp: Int64) -> String {
        let data = "\(certificateHash):\(timestamp)"
        return hmacSHA256(key: certificateHash, data: data)
    }

    /// Sign a POST request with body
    /// Format: HMAC-SHA256(key, "certificateHash:timestamp:bodyJson")
    private func signWithBody(certificateHash: String, timestamp: Int64, body: String) -> String {
        let data = "\(certificateHash):\(timestamp):\(body)"
        return hmacSHA256(key: certificateHash, data: data)
    }

    /// Sign a raw message (for multipart uploads)
    /// Format: HMAC-SHA256(key, message)
    private func signRaw(certificateHash: String, message: String) -> String {
        return hmacSHA256(key: certificateHash, data: message)
    }

    private func hmacSHA256(key: String, data: String) -> String {
        let keyData = key.data(using: .utf8)!
        let dataData = data.data(using: .utf8)!

        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))

        keyData.withUnsafeBytes { keyBytes in
            dataData.withUnsafeBytes { dataBytes in
                CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256),
                       keyBytes.baseAddress, keyData.count,
                       dataBytes.baseAddress, dataData.count,
                       &hash)
            }
        }

        return hash.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Profile Image

    /// Upload profile image - POST /api/mobile/profile-image (multipart)
    /// Signature format: {certificate_hash}:{timestamp}:profile-image
    func uploadProfileImage(subdomain: String, certificateHash: String, imageData: Data) async throws {
        let baseURL = getTenantBaseURL(subdomain: subdomain)
        guard let url = URL(string: "\(baseURL)/api/mobile/profile-image") else {
            throw APIError.invalidURL
        }

        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let message = "\(certificateHash):\(timestamp):profile-image"
        let signature = signRaw(certificateHash: certificateHash, message: message)

        // Build multipart body
        let boundary = UUID().uuidString
        var body = Data()

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"profile.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(certificateHash, forHTTPHeaderField: "X-Certificate-Hash")
        urlRequest.setValue(String(timestamp), forHTTPHeaderField: "X-Timestamp")
        urlRequest.setValue(signature, forHTTPHeaderField: "X-Signature")
        urlRequest.httpBody = body

        print("[API] POST /api/mobile/profile-image - uploading profile image (\(imageData.count) bytes)")

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        print("[API]   Response status: \(httpResponse.statusCode)")
        if let responseBody = String(data: data, encoding: .utf8) {
            print("[API]   Response body: \(responseBody)")
        }

        guard httpResponse.statusCode == 200 || httpResponse.statusCode == 201 else {
            print("[API] uploadProfileImage failed: HTTP \(httpResponse.statusCode)")
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        print("[API] Profile image uploaded successfully")
    }

    /// Download profile image - GET /api/mobile/user/{username}/profile-image
    /// Signature format: {certificate_hash}:{timestamp}:{username}
    /// Returns image Data or nil if no image exists
    func downloadProfileImage(subdomain: String, certificateHash: String, username: String) async throws -> Data? {
        let baseURL = getTenantBaseURL(subdomain: subdomain)
        guard let encodedUsername = username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(baseURL)/api/mobile/user/\(encodedUsername)/profile-image") else {
            throw APIError.invalidURL
        }

        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let message = "\(certificateHash):\(timestamp):\(username)"
        let signature = signRaw(certificateHash: certificateHash, message: message)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(certificateHash, forHTTPHeaderField: "X-Certificate-Hash")
        request.setValue(String(timestamp), forHTTPHeaderField: "X-Timestamp")
        request.setValue(signature, forHTTPHeaderField: "X-Signature")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        // 404 means no image - return nil
        if httpResponse.statusCode == 404 {
            return nil
        }

        guard httpResponse.statusCode == 200 else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        return data
    }

    // MARK: - Channel Members

    /// Get list of allowed members for a channel - GET /api/mobile/channel/{mumble_channel_id}/members
    /// Signature format: {certificate_hash}:{timestamp}:{mumble_channel_id}
    func fetchChannelMembers(subdomain: String, certificateHash: String, mumbleChannelId: UInt32) async throws -> [ChannelMember] {
        let baseURL = getTenantBaseURL(subdomain: subdomain)
        guard let url = URL(string: "\(baseURL)/api/mobile/channel/\(mumbleChannelId)/members") else {
            throw APIError.invalidURL
        }

        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let message = "\(certificateHash):\(timestamp):\(mumbleChannelId)"
        let signature = signRaw(certificateHash: certificateHash, message: message)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(certificateHash, forHTTPHeaderField: "X-Certificate-Hash")
        request.setValue(String(timestamp), forHTTPHeaderField: "X-Timestamp")
        request.setValue(signature, forHTTPHeaderField: "X-Signature")

        print("[API] GET /api/mobile/channel/\(mumbleChannelId)/members")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            print("[API] fetchChannelMembers failed: HTTP \(httpResponse.statusCode)")
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        return try decoder.decode([ChannelMember].self, from: data)
    }

    // MARK: - Channel Image

    /// Get channel image by Mumble channel ID - GET /api/mobile/channel/{mumble_channel_id}/image
    /// Signature format: {certificate_hash}:{timestamp}:{mumble_channel_id}
    /// Returns image Data or nil if no image exists
    func getChannelImage(subdomain: String, certificateHash: String, mumbleChannelId: UInt32) async throws -> Data? {
        let baseURL = getTenantBaseURL(subdomain: subdomain)
        guard let url = URL(string: "\(baseURL)/api/mobile/channel/\(mumbleChannelId)/image") else {
            throw APIError.invalidURL
        }

        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let message = "\(certificateHash):\(timestamp):\(mumbleChannelId)"
        let signature = signRaw(certificateHash: certificateHash, message: message)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(certificateHash, forHTTPHeaderField: "X-Certificate-Hash")
        request.setValue(String(timestamp), forHTTPHeaderField: "X-Timestamp")
        request.setValue(signature, forHTTPHeaderField: "X-Signature")
        // Bypass HTTP cache to always fetch fresh images from server
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        // 404 means no image - return nil
        if httpResponse.statusCode == 404 {
            return nil
        }

        guard httpResponse.statusCode == 200 else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        return data
    }
}

// MARK: - Alarm Request/Response Models

struct AlarmRequest: Codable {
    let channelId: UInt32?
    let channelName: String?
    let alarmStartUserName: String?
    let alarmStartUserDisplayname: String?
    let triggeredAt: Int64
    let latitude: Double?
    let longitude: Double?
    let locationType: String?
}

struct AlarmEndRequest: Codable {
    let alarmId: String
    let alarmEndUserName: String?
    let alarmEndUserDisplayname: String?
    let endedAt: Int64
}

struct AlarmResponse: Codable {
    let alarmId: String?
    let message: String?
    let success: Bool?
}

struct PositionUploadResponse: Codable {
    let message: String?
    let success: Bool?
    let alarmId: String?
    let positionUpdatedAt: String?  // ISO8601 format from backend
}

// MARK: - Dispatcher Request Models

struct DispatcherRequestCreateRequest: Codable {
    let latitude: Double?
    let longitude: Double?
    let locationType: String?
}

struct DispatcherRequestCreateResponse: Codable {
    let id: String
    let queuePosition: Int
    let status: String
    let createdAt: Int64
}

struct DispatcherPositionUpdate: Codable {
    let latitude: Double
    let longitude: Double
    let accuracy: Float?
    let altitude: Double?
    let speed: Float?
    let bearing: Float?
    let batteryLevel: Float?
    let batteryCharging: Bool?
    let locationType: String?
    let recordedAt: Int64
}

// MARK: - Dispatcher Request History

struct DispatcherRequestHistoryResponse: Codable {
    let requests: [DispatcherRequestHistoryItem]
}

struct DispatcherRequestHistoryItem: Codable, Identifiable {
    let id: String
    let serviceGroupName: String?
    let status: String
    let createdAt: Int64?
    let startedAt: Int64?
    let completedAt: Int64?
    let handledByUserDisplayname: String?
    let requestUserDisplayname: String?
    let waitTimeSeconds: Int?
}

struct OpenAlarmsResponse: Codable {
    let alarms: [OpenAlarmData]
}

/// Voice message info from backend
/// Note: No explicit CodingKeys needed - decoder uses .convertFromSnakeCase
/// which automatically converts "recorded_at" -> "recordedAt"
struct VoiceMessageInfo: Codable {
    let url: String              // Download URL path, e.g. "/api/alarm/{id}/voice"
    let size: Int?               // File size in bytes
    let recordedAt: Int64?       // Timestamp when recorded (from recorded_at)
}

struct OpenAlarmData: Codable {
    let id: String                          // Backend alarm ID
    let alarmStartUserName: String?         // alarm_start_user_name
    let alarmStartUserDisplayname: String?  // alarm_start_user_displayname
    let channelId: Int?                     // channel_id
    let channelName: String?                // channel_name
    let triggeredAt: Int64?                 // triggered_at
    let latitude: Double?
    let longitude: Double?
    let locationType: String?               // location_type
    let voiceMessage: VoiceMessageInfo?     // voice_message object with URL
    let positionUpdatedAt: Int64?           // position_updated_at - timestamp of last position update
    let voiceMessageText: String?           // voice_message_text - transcription of voice message

    /// Convenience property to check if voice message exists
    var hasVoiceMessage: Bool {
        voiceMessage != nil
    }

}

// MARK: - Alarm Settings

struct AlarmSettings: Codable {
    let alarmHoldDuration: Float
    let alarmCountdownDuration: Int
    let gpsWaitDuration: Int
    let alarmVoiceNoteDuration: Int
    let dispatcherAlias: String
    let dispatcherButtonHoldTime: Float
    let dispatcherGpsWaitTime: Int
    let dispatcherVoiceMaxDuration: Int

    enum CodingKeys: String, CodingKey {
        case alarmHoldDuration = "alarm_hold_duration"
        case alarmCountdownDuration = "alarm_countdown_duration"
        case gpsWaitDuration = "gps_wait_duration"
        case alarmVoiceNoteDuration = "alarm_voice_note_duration"
        case dispatcherAlias = "dispatcher_alias"
        case dispatcherButtonHoldTime = "dispatcher_button_hold_time"
        case dispatcherGpsWaitTime = "dispatcher_gps_wait_time"
        case dispatcherVoiceMaxDuration = "dispatcher_voice_max_duration"
    }

    static let defaults = AlarmSettings(
        alarmHoldDuration: 3.0,
        alarmCountdownDuration: 5,
        gpsWaitDuration: 30,
        alarmVoiceNoteDuration: 20,
        dispatcherAlias: "Zentrale",
        dispatcherButtonHoldTime: 0.5,
        dispatcherGpsWaitTime: 30,
        dispatcherVoiceMaxDuration: 20
    )
}

// MARK: - Models

struct MumbleCredentials: Codable {
    let username: String
    let firstName: String?
    let lastName: String?
    let certificateP12Base64: String
    let certificatePassword: String
    let serverHost: String
    let serverPort: Int
    let expiresAt: String
    let certificateHash: String
    let canReceiveAlarm: Bool?
    let canTriggerAlarm: Bool?
    let canEndAlarm: Bool?
    let canManageAudiocast: Bool?
    let canPlayAudiocast: Bool?
    let canCallDispatcher: Bool?
    let canActAsDispatcher: Bool?
    let tenantChannelId: Int?

    var displayName: String {
        if let first = firstName, let last = lastName, !first.isEmpty, !last.isEmpty {
            return "\(first) \(last)"
        }
        return username
    }

    // Convenience properties for compatibility
    var host: String { serverHost }
    var port: Int { serverPort }

    enum CodingKeys: String, CodingKey {
        case username
        case firstName = "first_name"
        case lastName = "last_name"
        case certificateP12Base64 = "certificate_p12_base64"
        case certificatePassword = "certificate_password"
        case serverHost = "server_host"
        case serverPort = "server_port"
        case expiresAt = "expires_at"
        case certificateHash = "certificate_hash"
        case canReceiveAlarm = "can_receive_alarm"
        case canTriggerAlarm = "can_trigger_alarm"
        case canEndAlarm = "can_end_alarm"
        case canManageAudiocast = "can_manage_audiocast"
        case canPlayAudiocast = "can_play_audiocast"
        case canCallDispatcher = "can_call_dispatcher"
        case canActAsDispatcher = "can_act_as_dispatcher"
        case tenantChannelId = "tenant_channel_id"
    }
}

// MARK: - User Alarm Permissions Response

struct UserAlarmPermissionsResponse: Codable {
    let canReceiveAlarm: Bool
    let canTriggerAlarm: Bool
    let canEndAlarm: Bool
    let canManageAudiocast: Bool
    let canPlayAudiocast: Bool
    let canCallDispatcher: Bool
    let canActAsDispatcher: Bool

    enum CodingKeys: String, CodingKey {
        case canReceiveAlarm = "can_receive_alarm"
        case canTriggerAlarm = "can_trigger_alarm"
        case canEndAlarm = "can_end_alarm"
        case canManageAudiocast = "can_manage_audiocast"
        case canPlayAudiocast = "can_play_audiocast"
        case canCallDispatcher = "can_call_dispatcher"
        case canActAsDispatcher = "can_act_as_dispatcher"
    }
}

// MARK: - Errors

enum APIError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int)
    case decodingError

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Ungültige URL"
        case .invalidResponse:
            return "Ungültige Antwort vom Server"
        case .httpError(let code):
            return "HTTP Fehler: \(code)"
        case .decodingError:
            return "Fehler beim Verarbeiten der Daten"
        }
    }
}
