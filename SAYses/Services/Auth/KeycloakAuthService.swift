import Foundation
import AuthenticationServices
import CommonCrypto

class KeycloakAuthService: NSObject {
    private let keycloakURL = "https://auth.sayses.com"
    private let realm = "sayses"
    private let clientId = "sayses-mobile"
    private let redirectURI = "com.sayses.ios://oauth2callback"

    private var codeVerifier: String?
    private var authSession: ASWebAuthenticationSession?

    var accessToken: String? {
        get { UserDefaults.standard.string(forKey: "accessToken") }
        set { UserDefaults.standard.set(newValue, forKey: "accessToken") }
    }

    var refreshToken: String? {
        get { UserDefaults.standard.string(forKey: "refreshToken") }
        set { UserDefaults.standard.set(newValue, forKey: "refreshToken") }
    }

    var tokenExpiry: Date? {
        get { UserDefaults.standard.object(forKey: "tokenExpiry") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "tokenExpiry") }
    }

    // MARK: - Public Methods

    func tryAutoLogin() async throws -> Bool {
        guard let refresh = refreshToken else {
            return false
        }

        // Check if access token is still valid
        if let expiry = tokenExpiry, expiry > Date() {
            return true
        }

        // Try to refresh
        return try await refreshTokens(refreshToken: refresh)
    }

    func login(loginHint: String? = nil) async throws {
        codeVerifier = generateCodeVerifier()
        let codeChallenge = generateCodeChallenge(from: codeVerifier!)

        let authURL = buildAuthURL(codeChallenge: codeChallenge, loginHint: loginHint)

        let callbackURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            authSession = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: "com.sayses.ios"
            ) { url, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let url = url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: AuthError.invalidCallback)
                }
            }

            // Use ephemeral session to avoid persisting Keycloak cookies (like Android's CookieManager.removeAllCookies)
            authSession?.prefersEphemeralWebBrowserSession = true
            authSession?.presentationContextProvider = self

            DispatchQueue.main.async {
                self.authSession?.start()
            }
        }

        guard let code = extractCode(from: callbackURL) else {
            throw AuthError.invalidCallback
        }

        try await exchangeCodeForTokens(code: code)
    }

    func logout() {
        // Cancel any pending auth session
        authSession?.cancel()
        authSession = nil
        codeVerifier = nil

        // Clear tokens (use removeObject to ensure they're actually deleted)
        UserDefaults.standard.removeObject(forKey: "accessToken")
        UserDefaults.standard.removeObject(forKey: "refreshToken")
        UserDefaults.standard.removeObject(forKey: "tokenExpiry")
    }

    // MARK: - Private Methods

    private func buildAuthURL(codeChallenge: String, loginHint: String?) -> URL {
        var components = URLComponents(string: "\(keycloakURL)/realms/\(realm)/protocol/openid-connect/auth")!

        var queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid profile email"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]

        if let hint = loginHint {
            queryItems.append(URLQueryItem(name: "login_hint", value: hint))
        }

        components.queryItems = queryItems
        return components.url!
    }

    private func extractCode(from url: URL) -> String? {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        return components?.queryItems?.first(where: { $0.name == "code" })?.value
    }

    private func exchangeCodeForTokens(code: String) async throws {
        let tokenURL = URL(string: "\(keycloakURL)/realms/\(realm)/protocol/openid-connect/token")!

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "grant_type": "authorization_code",
            "client_id": clientId,
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": codeVerifier ?? ""
        ]
        .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
        .joined(separator: "&")

        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw AuthError.tokenExchangeFailed
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)

        accessToken = tokenResponse.accessToken
        refreshToken = tokenResponse.refreshToken
        tokenExpiry = Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn - 60))
    }

    private func refreshTokens(refreshToken: String) async throws -> Bool {
        let tokenURL = URL(string: "\(keycloakURL)/realms/\(realm)/protocol/openid-connect/token")!

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "grant_type": "refresh_token",
            "client_id": clientId,
            "refresh_token": refreshToken
        ]
        .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
        .joined(separator: "&")

        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            return false
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)

        accessToken = tokenResponse.accessToken
        self.refreshToken = tokenResponse.refreshToken
        tokenExpiry = Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn - 60))

        return true
    }

    // MARK: - PKCE

    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        let data = Data(verifier.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - ASWebAuthenticationPresentationContextProviding

extension KeycloakAuthService: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first else {
            return ASPresentationAnchor()
        }
        return window
    }
}

// MARK: - Token Response

private struct TokenResponse: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int
    let tokenType: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
    }
}
