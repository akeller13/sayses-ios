import SwiftUI
import MapKit

struct MembersSheet: View {
    let channel: Channel
    let members: [User]
    let channelMembers: [ChannelMember]
    let memberProfileImages: [String: UIImage]
    @Environment(\.dismiss) private var dismiss
    @State private var selectedMemberForMap: ChannelMember?

    /// All channel members sorted: online first, then offline
    private var sortedMembers: [(member: ChannelMember, onlineUser: User?)] {
        let mapped = channelMembers.map { cm in
            (member: cm, onlineUser: findMumbleUser(for: cm))
        }
        return mapped.sorted { a, b in
            if (a.onlineUser != nil) != (b.onlineUser != nil) {
                return a.onlineUser != nil
            }
            return a.member.displayName.localizedCompare(b.member.displayName) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            List(sortedMembers, id: \.member.id) { entry in
                HStack(spacing: 12) {
                    // Avatar - profile image or initials fallback
                    if let image = memberProfileImages[entry.member.username] {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 40, height: 40)
                            .clipShape(Circle())
                    } else {
                        Circle()
                            .fill(Color.semparaPrimary.opacity(0.2))
                            .frame(width: 40, height: 40)
                            .overlay {
                                Text(entry.member.initials)
                                    .font(.headline)
                                    .foregroundStyle(Color.semparaPrimary)
                            }
                    }

                    // Name and function
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(entry.member.displayName)
                                .font(.body)
                                .foregroundStyle(entry.onlineUser != nil ? .primary : .secondary)

                            if entry.member.isMuted {
                                Image(systemName: "mic.slash.fill")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            } else {
                                Image(systemName: "mic.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }
                        }

                        if let jobFunction = entry.member.jobFunction, !jobFunction.isEmpty {
                            Text(jobFunction)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    // Right side: icons + position age
                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(spacing: 6) {
                            // GPS position indicator (tappable)
                            if entry.member.hasRecentPosition {
                                Button {
                                    selectedMemberForMap = entry.member
                                } label: {
                                    Image(systemName: "location.fill")
                                        .foregroundStyle(.blue)
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)
                            }

                            // Mute/deaf icons for online users
                            if let user = entry.onlineUser {
                                if user.isMuted {
                                    Image(systemName: "mic.slash.fill")
                                        .foregroundStyle(.red)
                                }
                                if user.isDeafened {
                                    Image(systemName: "speaker.slash.fill")
                                        .foregroundStyle(.orange)
                                }
                            }

                            // Online/offline indicator
                            Circle()
                                .fill(entry.onlineUser != nil ? Color.green : Color.gray.opacity(0.4))
                                .frame(width: 10, height: 10)
                        }

                        // Position age
                        if let age = entry.member.positionAge {
                            Text(age)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(channel.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fertig") {
                        dismiss()
                    }
                }
            }
        }
        .sheet(item: $selectedMemberForMap) { member in
            if let lat = member.latitude, let lon = member.longitude {
                PositionMapSheet(
                    coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                    title: member.displayName
                )
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// Find the online Mumble user matching a backend ChannelMember
    private func findMumbleUser(for channelMember: ChannelMember) -> User? {
        let cmBase = channelMember.username.components(separatedBy: "@").first ?? channelMember.username
        return members.first { $0.name == channelMember.username }
            ?? members.first { $0.name.components(separatedBy: "@").first == cmBase }
    }
}

#Preview {
    MembersSheet(
        channel: Channel(id: 1, name: "Test Channel", userCount: 3),
        members: [
            User(session: 1, channelId: 1, name: "max@demo"),
            User(session: 2, channelId: 1, name: "anna@demo", isMuted: true),
        ],
        channelMembers: [
            ChannelMember(username: "max@demo", firstName: "Max", lastName: "Mustermann", jobFunction: "Techniker", roleName: "Moderator", hasProfileImage: false, isMuted: false, latitude: 49.445, longitude: 7.772, positionTimestamp: "2024-01-01T12:00:00"),
            ChannelMember(username: "anna@demo", firstName: "Anna", lastName: "Schmidt", jobFunction: "Leiterin", roleName: "Teilnehmer", hasProfileImage: false, isMuted: true, latitude: nil, longitude: nil, positionTimestamp: nil),
            ChannelMember(username: "peter@demo", firstName: "Peter", lastName: "Müller", jobFunction: nil, roleName: nil, hasProfileImage: false, isMuted: false, latitude: nil, longitude: nil, positionTimestamp: nil),
        ],
        memberProfileImages: [:]
    )
}
