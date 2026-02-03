import SwiftUI

/// Cache for channel images loaded from backend
@MainActor
class ChannelImageCache: ObservableObject {
    static let shared = ChannelImageCache()

    @Published private(set) var images: [UInt32: Image] = [:]
    private var loadingChannels: Set<UInt32> = []
    private var failedChannels: Set<UInt32> = []

    private let apiClient = SemparaAPIClient()

    private init() {}

    /// Get cached image for channel
    func image(for channelId: UInt32) -> Image? {
        images[channelId]
    }

    /// Check if image is available or being loaded
    func hasImage(for channelId: UInt32) -> Bool {
        images[channelId] != nil
    }

    /// Check if loading failed for this channel
    func loadingFailed(for channelId: UInt32) -> Bool {
        failedChannels.contains(channelId)
    }

    /// Load image for channel if not already cached or loading
    func loadImageIfNeeded(channelId: UInt32, subdomain: String?, certificateHash: String?) {
        guard let subdomain = subdomain, let certificateHash = certificateHash else { return }
        guard !images.keys.contains(channelId) else { return }
        guard !loadingChannels.contains(channelId) else { return }
        guard !failedChannels.contains(channelId) else { return }

        loadingChannels.insert(channelId)

        Task {
            do {
                if let imageData = try await apiClient.getChannelImage(
                    subdomain: subdomain,
                    certificateHash: certificateHash,
                    mumbleChannelId: channelId
                ) {
                    if let uiImage = UIImage(data: imageData) {
                        images[channelId] = Image(uiImage: uiImage)
                    } else {
                        failedChannels.insert(channelId)
                    }
                } else {
                    // No image for this channel (404)
                    failedChannels.insert(channelId)
                }
            } catch {
                print("[ChannelImageCache] Failed to load image for channel \(channelId): \(error)")
                failedChannels.insert(channelId)
            }
            loadingChannels.remove(channelId)
        }
    }

    /// Clear all cached images (e.g., on logout)
    func clearCache() {
        images.removeAll()
        loadingChannels.removeAll()
        failedChannels.removeAll()
    }
}
