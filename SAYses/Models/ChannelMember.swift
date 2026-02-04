import Foundation

struct ChannelMember: Codable, Identifiable {
    let username: String
    let firstName: String?
    let lastName: String?
    let jobFunction: String?
    let hasProfileImage: Bool

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

    enum CodingKeys: String, CodingKey {
        case username
        case firstName = "first_name"
        case lastName = "last_name"
        case jobFunction = "job_function"
        case hasProfileImage = "has_profile_image"
    }
}
