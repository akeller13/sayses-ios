import SwiftUI

struct ChannelRowView: View {
    let channel: Channel
    let isFavorite: Bool
    @State private var isExpanded = false

    var body: some View {
        NavigationLink(value: channel) {
            HStack(spacing: 12) {
                // Expand/collapse for subchannels
                if channel.hasSubChannels {
                    Button(action: { isExpanded.toggle() }) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear
                        .frame(width: 12)
                }

                // Channel icon
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .foregroundStyle(Color.semparaPrimary)

                // Channel name
                Text(channel.name)
                    .font(.body)

                // Favorite star
                if isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                }

                Spacer()

                // User count badge
                if channel.userCount > 0 {
                    Text("\(channel.userCount)")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.semparaPrimary)
                        .clipShape(Capsule())
                }
            }
            .padding(.leading, CGFloat(channel.depth) * 16)
        }
    }
}

#Preview {
    List {
        ChannelRowView(
            channel: Channel(id: 1, name: "Test Channel", userCount: 5),
            isFavorite: true
        )
        ChannelRowView(
            channel: Channel(id: 2, name: "Another Channel"),
            isFavorite: false
        )
    }
}
