import Foundation
import KeychainAccess

/// Persistent storage for Mumble credentials using iOS Keychain
/// Similar to Android's CertificateStore - enables offline/auto-login without Keycloak
class CredentialsStore {
    static let shared = CredentialsStore()

    private let keychain = Keychain(service: "com.sayses.app.credentials")
        .accessibility(.afterFirstUnlock)  // Available after first unlock
    private let credentialsKey = "mumble_credentials_json"

    /// Renewal threshold: credentials are considered "needing renewal" if less than 30 days validity
    private let renewalThresholdDays: TimeInterval = 30

    private init() {}

    // MARK: - Public API

    /// Check if valid stored credentials exist (not expired)
    /// Note: Returns true if credentials exist and are not yet expired
    /// Renewal check (< 30 days) is separate via needsRenewal()
    func hasValidCredentials() -> Bool {
        // Also check if subdomain is stored (required for connection)
        let subdomain = UserDefaults.standard.string(forKey: "subdomain")
        print("[CredentialsStore] hasValidCredentials: checking... (subdomain: \(subdomain ?? "NONE"))")

        guard let credentials = getStoredCredentials() else {
            print("[CredentialsStore] hasValidCredentials: No stored credentials")
            return false
        }

        // Check if credentials are expired (not the 30-day renewal threshold!)
        let isNotExpired = isCredentialsNotExpired(credentials)
        print("[CredentialsStore] hasValidCredentials: \(isNotExpired) (user: \(credentials.username))")
        return isNotExpired
    }

    /// Get stored credentials if they exist
    func getStoredCredentials() -> MumbleCredentials? {
        do {
            guard let jsonString = try keychain.get(credentialsKey) else {
                print("[CredentialsStore] No credentials found in Keychain")
                return nil
            }

            guard let jsonData = jsonString.data(using: .utf8) else {
                print("[CredentialsStore] Failed to convert JSON string to data")
                return nil
            }

            let credentials = try JSONDecoder().decode(MumbleCredentials.self, from: jsonData)
            print("[CredentialsStore] Loaded credentials for user: \(credentials.username), expires: \(credentials.expiresAt)")
            return credentials
        } catch {
            print("[CredentialsStore] Failed to get/decode credentials: \(error)")
            return nil
        }
    }

    /// Save credentials for offline/auto-login
    func saveCredentials(_ credentials: MumbleCredentials) {
        do {
            let jsonData = try JSONEncoder().encode(credentials)
            guard let jsonString = String(data: jsonData, encoding: .utf8) else {
                print("[CredentialsStore] Failed to encode credentials to string")
                return
            }

            try keychain.set(jsonString, key: credentialsKey)
            print("[CredentialsStore] Credentials saved to Keychain successfully")
        } catch {
            print("[CredentialsStore] Failed to save credentials: \(error)")
        }
    }

    /// Clear stored credentials (on logout)
    func clearCredentials() {
        do {
            try keychain.remove(credentialsKey)
            print("[CredentialsStore] Credentials cleared from Keychain")
        } catch {
            print("[CredentialsStore] Failed to clear credentials: \(error)")
        }
    }

    /// Check if credentials need renewal (< 30 days validity remaining)
    func needsRenewal() -> Bool {
        guard let credentials = getStoredCredentials() else {
            return true
        }
        return isCredentialsNeedingRenewal(credentials)
    }

    // MARK: - Private

    /// Parse expiry date from credentials
    /// Handles various ISO8601 formats including microseconds (6 decimal places)
    private func parseExpiryDate(_ expiresAt: String) -> Date? {
        // Try ISO8601DateFormatter first (handles standard formats)
        let isoFormatter = ISO8601DateFormatter()

        // Try with fractional seconds (3 decimal places)
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: expiresAt) {
            return date
        }

        // Try without fractional seconds
        isoFormatter.formatOptions = [.withInternetDateTime]
        if let date = isoFormatter.date(from: expiresAt) {
            return date
        }

        // Handle microseconds format (6 decimal places) using DateFormatter
        // Format: 2027-01-23T15:35:04.666088
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)

        // Try with 6 decimal places (microseconds)
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
        if let date = dateFormatter.date(from: expiresAt) {
            return date
        }

        // Try with timezone suffix
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSZ"
        if let date = dateFormatter.date(from: expiresAt) {
            return date
        }

        print("[CredentialsStore] Could not parse date with any format: \(expiresAt)")
        return nil
    }

    /// Check if credentials are not expired (for auto-login)
    private func isCredentialsNotExpired(_ credentials: MumbleCredentials) -> Bool {
        guard let expiry = parseExpiryDate(credentials.expiresAt) else {
            print("[CredentialsStore] Failed to parse expiry date: \(credentials.expiresAt)")
            return false
        }

        let now = Date()
        let isNotExpired = now < expiry

        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy HH:mm"
        print("[CredentialsStore] Expiry: \(formatter.string(from: expiry)), now: \(formatter.string(from: now)), not expired: \(isNotExpired)")

        return isNotExpired
    }

    /// Check if credentials need renewal (< 30 days until expiry)
    private func isCredentialsNeedingRenewal(_ credentials: MumbleCredentials) -> Bool {
        guard let expiry = parseExpiryDate(credentials.expiresAt) else {
            return true
        }

        let renewalThreshold = expiry.addingTimeInterval(-renewalThresholdDays * 24 * 60 * 60)
        let now = Date()

        return now >= renewalThreshold
    }
}
