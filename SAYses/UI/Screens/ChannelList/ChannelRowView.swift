import SwiftUI

struct ChannelRowView: View {
    let channel: Channel
    let isFavorite: Bool
    let subdomain: String?
    let certificateHash: String?
    @State private var isExpanded = false
    @StateObject private var imageCache = ChannelImageCache.shared

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

                // Channel image or fallback icon
                channelImage
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

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
        .onAppear {
            imageCache.loadImageIfNeeded(
                channelId: channel.id,
                subdomain: subdomain,
                certificateHash: certificateHash
            )
        }
    }

    @ViewBuilder
    private var channelImage: some View {
        if let image = imageCache.image(for: channel.id) {
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            // Fallback icon
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.semparaPrimary.opacity(0.15))
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.semparaPrimary)
            }
        }
    }
}

#Preview {
    List {
        ChannelRowView(
            channel: Channel(id: 1, name: "Test Channel", userCount: 5),
            isFavorite: true,
            subdomain: nil,
            certificateHash: nil
        )
        ChannelRowView(
            channel: Channel(id: 2, name: "Another Channel"),
            isFavorite: false,
            subdomain: nil,
            certificateHash: nil
        )
    }
}
