import Foundation
import Observation

@Observable
class AuthViewModel {
    var isAuthenticated = false
    var isCheckingAuth = true
    var isLoading = false
    var errorMessage: String?
    var lastEmail: String?

    private let keycloakService = KeycloakAuthService()
    private let apiClient = SemparaAPIClient()

    func checkAuthentication() async {
        isCheckingAuth = true

        // Load last email from storage
        lastEmail = UserDefaults.standard.string(forKey: "lastEmail")

        // Try auto-login with stored tokens
        do {
            if try await keycloakService.tryAutoLogin() {
                isAuthenticated = true
            }
        } catch {
            print("Auto-login failed: \(error)")
        }

        isCheckingAuth = false
    }

    func lookupAndLogin(emailOrUsername: String) async {
        isLoading = true
        errorMessage = nil

        do {
            // Check if it's a username (no dot after @) or email (has dot after @)
            let isUsername = isUsernameFormat(emailOrUsername)

            // Lookup workspace
            let subdomain: String
            if isUsername {
                // Extract subdomain from username (part after @)
                guard let atIndex = emailOrUsername.lastIndex(of: "@") else {
                    throw AuthError.invalidFormat
                }
                subdomain = String(emailOrUsername[emailOrUsername.index(after: atIndex)...])
            } else {
                // Email lookup
                let result = try await apiClient.lookupWorkspace(email: emailOrUsername)
                guard result.found, let foundSubdomain = result.subdomain else {
                    throw AuthError.workspaceNotFound
                }
                subdomain = foundSubdomain
            }

            // Save for next time
            UserDefaults.standard.set(emailOrUsername, forKey: "lastEmail")
            UserDefaults.standard.set(subdomain, forKey: "subdomain")
            lastEmail = emailOrUsername

            // Start KeyCloak login
            try await keycloakService.login(loginHint: emailOrUsername)

            isAuthenticated = true

        } catch AuthError.workspaceNotFound {
            errorMessage = "Kein Workspace gefunden"
        } catch AuthError.invalidFormat {
            errorMessage = "Ungültiges Format"
        } catch {
            errorMessage = "Fehler: \(error.localizedDescription)"
        }

        isLoading = false
    }

    func logout() {
        keycloakService.logout()
        isAuthenticated = false
        isLoading = false
        errorMessage = nil
        UserDefaults.standard.removeObject(forKey: "subdomain")
    }

    // MARK: - Private

    private func isUsernameFormat(_ input: String) -> Bool {
        // Username format: name@subdomain (no dot after @)
        // Email format: name@domain.tld (has dot after @)
        guard let atIndex = input.lastIndex(of: "@") else {
            return false
        }
        let afterAt = String(input[input.index(after: atIndex)...])
        return !afterAt.contains(".")
    }
}

enum AuthError: Error {
    case workspaceNotFound
    case invalidFormat
    case noRefreshToken
    case invalidCallback
    case tokenExchangeFailed
    case tokenExpired
}
