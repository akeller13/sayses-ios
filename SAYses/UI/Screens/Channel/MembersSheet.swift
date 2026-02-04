import SwiftUI

struct MembersSheet: View {
    let channel: Channel
    let members: [User]
    let channelMembers: [ChannelMember]
    let memberProfileImages: [String: UIImage]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(members) { member in
                let channelMember = findChannelMember(for: member.name)

                HStack(spacing: 12) {
                    // Avatar - profile image or initials fallback
                    if let channelMember = channelMember,
                       let image = memberProfileImages[channelMember.username] {
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
                                Text(channelMember?.initials ?? String(member.name.prefix(1)).uppercased())
                                    .font(.headline)
                                    .foregroundStyle(Color.semparaPrimary)
                            }
                    }

                    // Name and function
                    VStack(alignment: .leading, spacing: 2) {
                        Text(channelMember?.displayName ?? member.name)
                            .font(.body)

                        if let jobFunction = channelMember?.jobFunction, !jobFunction.isEmpty {
                            Text(jobFunction)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    // Status icons
                    if member.isMuted {
                        Image(systemName: "mic.slash.fill")
                            .foregroundStyle(.red)
                    }
                    if member.isDeafened {
                        Image(systemName: "speaker.slash.fill")
                            .foregroundStyle(.orange)
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
        .presentationDetents([.medium, .large])
    }

    /// Match Mumble username to backend ChannelMember by username
    private func findChannelMember(for mumbleName: String) -> ChannelMember? {
        // Backend usernames include @tenant suffix (e.g. "jack.bauer@deltasecurity")
        // Match directly, or fallback to matching without suffix
        return channelMembers.first { $0.username == mumbleName }
            ?? channelMembers.first { $0.username.components(separatedBy: "@").first == mumbleName.components(separatedBy: "@").first }
    }
}

#Preview {
    MembersSheet(
        channel: Channel(id: 1, name: "Test Channel", userCount: 3),
        members: [
            User(session: 1, channelId: 1, name: "max@demo"),
            User(session: 2, channelId: 1, name: "anna@demo", isMuted: true),
            User(session: 3, channelId: 1, name: "peter@demo")
        ],
        channelMembers: [
            ChannelMember(username: "max", firstName: "Max", lastName: "Mustermann", jobFunction: "Techniker", hasProfileImage: false),
            ChannelMember(username: "anna", firstName: "Anna", lastName: "Schmidt", jobFunction: "Leiterin", hasProfileImage: false),
        ],
        memberProfileImages: [:]
    )
}
