import Foundation

struct ChannelMembersResponse: Codable {
    let members: [ChannelMember]
    let canMute: Bool
    let canUnmute: Bool

    enum CodingKeys: String, CodingKey {
        case members
        case canMute = "can_mute"
        case canUnmute = "can_unmute"
    }
}

struct ChannelMember: Codable, Identifiable {
    let username: String
    let firstName: String?
    let lastName: String?
    let jobFunction: String?
    let roleName: String?
    let hasProfileImage: Bool
    var isMuted: Bool
    var latitude: Double?
    var longitude: Double?
    var positionTimestamp: String?

    var id: String { username }

    enum CodingKeys: String, CodingKey {
        case username
        case firstName = "first_name"
        case lastName = "last_name"
        case jobFunction = "job_function"
        case roleName = "role_name"
        case hasProfileImage = "has_profile_image"
        case isMuted = "is_muted"
        case latitude
        case longitude
        case positionTimestamp = "position_timestamp"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        username = try container.decode(String.self, forKey: .username)
        firstName = try container.decodeIfPresent(String.self, forKey: .firstName)
        lastName = try container.decodeIfPresent(String.self, forKey: .lastName)
        jobFunction = try container.decodeIfPresent(String.self, forKey: .jobFunction)
        roleName = try container.decodeIfPresent(String.self, forKey: .roleName)
        hasProfileImage = try container.decode(Bool.self, forKey: .hasProfileImage)
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        latitude = try container.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try container.decodeIfPresent(Double.self, forKey: .longitude)
        positionTimestamp = try container.decodeIfPresent(String.self, forKey: .positionTimestamp)
    }

    init(username: String, firstName: String?, lastName: String?, jobFunction: String?, roleName: String?, hasProfileImage: Bool, isMuted: Bool = false, latitude: Double?, longitude: Double?, positionTimestamp: String?) {
        self.username = username
        self.firstName = firstName
        self.lastName = lastName
        self.jobFunction = jobFunction
        self.roleName = roleName
        self.hasProfileImage = hasProfileImage
        self.isMuted = isMuted
        self.latitude = latitude
        self.longitude = longitude
        self.positionTimestamp = positionTimestamp
    }

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
        guard var timestamp = positionTimestamp else { return nil }

        // Strip trailing "Z" — SSE sends it, members endpoint does not. Both are UTC.
        if timestamp.hasSuffix("Z") {
            timestamp = String(timestamp.dropLast())
        }

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
        } else if minutes > 0 {
            return "\(minutes)min"
        } else {
            return "\(seconds)s"
        }
    }
}
