import Foundation

struct Channel: Identifiable, Hashable {
    let id: UInt32
    let parentId: UInt32?
    let name: String
    let position: Int32
    var subChannels: [Channel]
    var isFavorite: Bool
    var isExpanded: Bool
    var userCount: Int
    var depth: Int
    var permissions: Int  // -1 = unknown, bitmask from server

    // Mumble permission flags
    static let PERMISSION_WRITE: Int = 0x01      // Can modify channel
    static let PERMISSION_TRAVERSE: Int = 0x02  // Can see the channel
    static let PERMISSION_ENTER: Int = 0x04     // Can enter the channel
    static let PERMISSION_SPEAK: Int = 0x08     // Can speak in the channel
    static let PERMISSION_CACHED: Int = 0x8000000  // Permissions are cached

    init(
        id: UInt32,
        parentId: UInt32? = nil,
        name: String,
        position: Int32 = 0,
        subChannels: [Channel] = [],
        isFavorite: Bool = false,
        isExpanded: Bool = true,
        userCount: Int = 0,
        depth: Int = 0,
        permissions: Int = -1
    ) {
        self.id = id
        self.parentId = parentId
        self.name = name
        self.position = position
        self.subChannels = subChannels
        self.isFavorite = isFavorite
        self.isExpanded = isExpanded
        self.userCount = userCount
        self.depth = depth
        self.permissions = permissions
    }

    /// Check if this is the actual root channel (id=0)
    var isRootChannel: Bool {
        id == 0
    }

    /// Check if this is a direct child of root
    var isTopLevel: Bool {
        parentId == 0
    }

    var hasSubChannels: Bool {
        !subChannels.isEmpty
    }

    /// Check if user can see this channel (has Traverse or Enter permission)
    /// If permissions are unknown (-1), channel is NOT accessible (must wait for server response)
    var canAccess: Bool {
        permissions != -1 && (
            (permissions & Channel.PERMISSION_TRAVERSE) != 0 ||
            (permissions & Channel.PERMISSION_ENTER) != 0
        )
    }

    /// Check if user can speak in this channel
    var canSpeak: Bool {
        permissions == -1 || (permissions & Channel.PERMISSION_SPEAK) != 0
    }

    // MARK: - Hierarchy Building

    /// Build channel hierarchy from flat list
    /// Returns direct children of root (parentId == 0), not the root itself
    static func buildHierarchy(from flatChannels: [Channel]) -> [Channel] {
        func attachSubChannels(_ channel: Channel, allChannels: [Channel]) -> Channel {
            let children = allChannels
                .filter { $0.parentId == channel.id }
                .map { attachSubChannels($0, allChannels: allChannels) }
                .sorted { $0.name.lowercased() < $1.name.lowercased() }

            var updatedChannel = channel
            updatedChannel.subChannels = children
            return updatedChannel
        }

        // Get direct children of the root channel (parentId == 0)
        // Don't show the root channel itself, only its children
        let topLevelChannels = flatChannels
            .filter { $0.parentId == 0 }
            .map { attachSubChannels($0, allChannels: flatChannels) }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }

        return topLevelChannels
    }

    /// Filter channels by permission (recursive)
    static func filterAccessible(_ channels: [Channel]) -> [Channel] {
        channels
            .filter { channel in
                let accessible = channel.canAccess
                if !accessible {
                    print("[Channel] Filtering out '\(channel.name)' (id=\(channel.id)) - no permission (0x\(String(channel.permissions, radix: 16)))")
                }
                return accessible
            }
            .map { channel in
                if channel.hasSubChannels {
                    var filtered = channel
                    filtered.subChannels = filterAccessible(channel.subChannels)
                    return filtered
                }
                return channel
            }
    }

    /// Filter channels by tenant subdomain
    /// Only shows sub-channels under the tenant's root channel
    static func filterByTenant(_ channels: [Channel], subdomain: String?) -> [Channel] {
        guard let subdomain = subdomain, !subdomain.isEmpty else {
            print("[Channel] No tenant subdomain set - showing all channels")
            return channels
        }

        print("[Channel] Filtering by tenant subdomain: '\(subdomain)'")

        // Find the tenant root channel (direct child of root with matching name)
        if let tenantRoot = channels.first(where: { $0.name.lowercased() == subdomain.lowercased() }) {
            print("[Channel] Found tenant root: '\(tenantRoot.name)' (id=\(tenantRoot.id)), showing \(tenantRoot.subChannels.count) sub-channels")
            return tenantRoot.subChannels
        }

        // Tenant channel not found
        print("[Channel] Tenant root channel '\(subdomain)' not found in \(channels.count) channels")
        channels.forEach { ch in
            print("[Channel]   Available: '\(ch.name)' (id=\(ch.id))")
        }
        // Return empty list to prevent data leakage
        return []
    }

    /// Update depths for flattened display
    static func updateDepths(_ channels: [Channel], depth: Int = 0) -> [Channel] {
        channels.map { channel in
            var updated = channel
            updated.depth = depth
            updated.subChannels = updateDepths(channel.subChannels, depth: depth + 1)
            return updated
        }
    }

    /// Flatten hierarchy for UI display
    static func flatten(_ channels: [Channel], expandedIds: Set<UInt32>) -> [Channel] {
        var result: [Channel] = []
        for channel in channels {
            result.append(channel)
            if channel.hasSubChannels && expandedIds.contains(channel.id) {
                result.append(contentsOf: flatten(channel.subChannels, expandedIds: expandedIds))
            }
        }
        return result
    }
}
