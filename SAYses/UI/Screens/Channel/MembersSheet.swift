import SwiftUI

struct MembersSheet: View {
    let channel: Channel
    let members: [User]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(members) { member in
                HStack(spacing: 12) {
                    // Avatar
                    Circle()
                        .fill(Color.semparaPrimary.opacity(0.2))
                        .frame(width: 40, height: 40)
                        .overlay {
                            Text(member.name.prefix(1).uppercased())
                                .font(.headline)
                                .foregroundStyle(Color.semparaPrimary)
                        }

                    // Name
                    Text(member.name)
                        .font(.body)

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
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

#Preview {
    MembersSheet(
        channel: Channel(id: 1, name: "Test Channel", userCount: 3),
        members: [
            User(session: 1, channelId: 1, name: "Max Mustermann"),
            User(session: 2, channelId: 1, name: "Anna Schmidt", isMuted: true),
            User(session: 3, channelId: 1, name: "Peter Müller")
        ]
    )
}
