import Foundation

struct ChannelMember: Codable, Identifiable {
    let username: String
    let firstName: String?
    let lastName: String?
    let jobFunction: String?
    let hasProfileImage: Bool
    let latitude: Double?
    let longitude: Double?
    let positionTimestamp: String?

    var id: String { username }

    /// Username without @tenant suffix for display
    var shortUsername: String {
        username.components(separatedBy: "@").first ?? username
    }

    var displayName: String {
        let parts = [firstName, lastName].compactMap { $0?.isEmpty == false ? $0 : nil }
        return parts.isEmpty ? shortUsername : parts.joined(separator: " ")
    }

    var initials: String {
        if let first = firstName?.first, let last = lastName?.first {
            return "\(first)\(last)".uppercased()
        }
        return String(shortUsername.prefix(1)).uppercased()
    }

    /// User has a recent GPS position
    var hasRecentPosition: Bool {
        latitude != nil && longitude != nil && positionTimestamp != nil
    }

    /// Relative age of the last position (e.g. "2h 35min", "3T 5h 12min")
    var positionAge: String? {
        guard let timestamp = positionTimestamp else { return nil }

        // Backend sends Python isoformat without timezone (e.g. "2026-02-07T19:09:57.123456")
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
        var date = df.date(from: timestamp)
        if date == nil {
            df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            date = df.date(from: timestamp)
        }
        guard let posDate = date else { return nil }

        let seconds = Int(Date().timeIntervalSince(posDate))
        guard seconds >= 0 else { return nil }

        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60

        if days > 0 {
            return "\(days)T \(hours)h \(minutes)min"
        } else if hours > 0 {
            return "\(hours)h \(minutes)min"
        } else {
            return "\(minutes)min"
        }
    }

    enum CodingKeys: String, CodingKey {
        case username
        case firstName = "first_name"
        case lastName = "last_name"
        case jobFunction = "job_function"
        case hasProfileImage = "has_profile_image"
        case latitude
        case longitude
        case positionTimestamp = "position_timestamp"
    }
}
