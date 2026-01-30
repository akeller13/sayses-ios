import Foundation
import Observation
import AuthenticationServices

@Observable
@MainActor
class AuthViewModel {
    var isAuthenticated = false
    var isCheckingAuth = true
    var isLoading = false
    var errorMessage: String?
    var lastEmail: String?

    private var isLoginInProgress = false  // Prevent checkAuthentication during login

    private let keycloakService = KeycloakAuthService()
    private let apiClient = SemparaAPIClient()

    func checkAuthentication() async {
        // Don't check if already authenticated
        if isAuthenticated {
            print("[AuthViewModel] checkAuthentication: already authenticated, skipping")
            isCheckingAuth = false
            return
        }

        // Don't check if login is in progress
        if isLoginInProgress {
            print("[AuthViewModel] checkAuthentication: login in progress, skipping")
            isCheckingAuth = false
            return
        }

        print("[AuthViewModel] checkAuthentication: starting...")
        isCheckingAuth = true

        // Load last email from storage
        lastEmail = UserDefaults.standard.string(forKey: "lastEmail")

        // STEP 1: Check for valid stored Mumble credentials (like Android's CertificateStore)
        // If valid credentials exist, we can skip Keycloak login entirely!
        let hasSubdomain = UserDefaults.standard.string(forKey: "subdomain") != nil
        let hasCredentials = CredentialsStore.shared.hasValidCredentials()

        print("[AuthViewModel] checkAuthentication: hasSubdomain=\(hasSubdomain), hasCredentials=\(hasCredentials)")

        if hasCredentials && hasSubdomain {
            print("[AuthViewModel] checkAuthentication: valid stored credentials found - authenticated!")
            isAuthenticated = true
            isCheckingAuth = false
            return
        } else if hasCredentials && !hasSubdomain {
            print("[AuthViewModel] checkAuthentication: credentials exist but NO subdomain stored!")
        }

        // STEP 2: No valid credentials - try auto-login with stored Keycloak tokens
        do {
            if try await keycloakService.tryAutoLogin() {
                print("[AuthViewModel] checkAuthentication: Keycloak auto-login successful")
                isAuthenticated = true
            } else {
                print("[AuthViewModel] checkAuthentication: no stored tokens or auto-login returned false")
            }
        } catch {
            print("[AuthViewModel] checkAuthentication: auto-login failed: \(error)")
        }

        isCheckingAuth = false
        print("[AuthViewModel] checkAuthentication: finished, isAuthenticated=\(isAuthenticated)")
    }

    func lookupAndLogin(emailOrUsername: String) async {
        print("[AuthViewModel] lookupAndLogin started")
        isLoading = true
        isLoginInProgress = true
        errorMessage = nil

        do {
            // IMMER API-Lookup machen - Server unterscheidet Email/Username
            // (wie Android: "Die Unterscheidung erfolgt serverseitig")
            print("[AuthViewModel] Looking up workspace for: \(emailOrUsername)")
            let result = try await apiClient.lookupWorkspace(email: emailOrUsername)
            guard result.found, let subdomain = result.subdomain else {
                throw AuthError.workspaceNotFound
            }

            print("[AuthViewModel] Subdomain: \(subdomain)")

            // Save for next time
            UserDefaults.standard.set(emailOrUsername, forKey: "lastEmail")
            UserDefaults.standard.set(subdomain, forKey: "subdomain")
            lastEmail = emailOrUsername

            // Start KeyCloak login
            print("[AuthViewModel] Starting Keycloak login...")
            try await keycloakService.login(loginHint: emailOrUsername)

            print("[AuthViewModel] Keycloak login successful, setting isAuthenticated = true")
            isAuthenticated = true
            print("[AuthViewModel] isAuthenticated is now: \(isAuthenticated)")

        } catch AuthError.workspaceNotFound {
            print("[AuthViewModel] Error: workspace not found")
            errorMessage = "Keinen Workspace gefunden"
        } catch AuthError.invalidFormat {
            print("[AuthViewModel] Error: invalid format")
            errorMessage = "Ungültiges Format"
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            print("[AuthViewModel] User cancelled login")
            // User cancelled - don't show error
        } catch {
            print("[AuthViewModel] Error: \(error)")
            errorMessage = "Fehler: \(error.localizedDescription)"
        }

        isLoading = false
        isLoginInProgress = false
        print("[AuthViewModel] lookupAndLogin finished, isAuthenticated=\(isAuthenticated), isLoading=\(isLoading)")
    }

    func logout() {
        keycloakService.logout()
        CredentialsStore.shared.clearCredentials()  // Clear stored Mumble credentials
        isAuthenticated = false
        isLoading = false
        errorMessage = nil
        UserDefaults.standard.removeObject(forKey: "subdomain")
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
