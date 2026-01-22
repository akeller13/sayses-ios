import Foundation

class SemparaAPIClient {
    private let centralBaseURL = "https://api.sayses.com"
    private let tenantURLTemplate = "https://%@.sayseswork.com"

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
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
        case tenantChannelId = "tenant_channel_id"
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
