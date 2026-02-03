import Foundation

/// Local cache for dispatcher request history
/// Provides offline access and immediate UI updates before backend sync
class DispatcherHistoryCache {

    // MARK: - Singleton

    static let shared = DispatcherHistoryCache()

    // MARK: - Constants

    private let maxEntries = 10
    private let cacheFileName = "dispatcher_history_cache.json"

    /// Time window (seconds) during which local entries take priority over backend
    /// This prevents backend sync from overwriting very recent local changes
    private let localPriorityWindowSeconds: TimeInterval = 30

    // MARK: - Cached Data

    private var cachedItems: [CachedHistoryItem] = []
    private let queue = DispatchQueue(label: "com.sayses.dispatcherHistoryCache", qos: .utility)

    // MARK: - Cache Item Model

    struct CachedHistoryItem: Codable, Identifiable {
        let id: String
        var status: String
        let createdAt: Int64  // milliseconds since epoch
        var startedAt: Int64?
        var completedAt: Int64?
        var serviceGroupName: String?
        var handledByUserDisplayname: String?
        var requestUserDisplayname: String?
        var waitTimeSeconds: Int?
        var locallyModifiedAt: Date?  // Track when we made local changes
        var needsSync: Bool  // True if local change not yet confirmed by backend

        init(id: String, status: String, createdAt: Int64, waitTimeSeconds: Int? = nil) {
            self.id = id
            self.status = status
            self.createdAt = createdAt
            self.startedAt = nil
            self.completedAt = nil
            self.serviceGroupName = nil
            self.handledByUserDisplayname = nil
            self.requestUserDisplayname = nil
            self.waitTimeSeconds = waitTimeSeconds
            self.locallyModifiedAt = Date()
            self.needsSync = true
        }

        /// Create from backend response item
        init(from backendItem: DispatcherRequestHistoryItem) {
            self.id = backendItem.id
            self.status = backendItem.status
            self.createdAt = backendItem.createdAt ?? Int64(Date().timeIntervalSince1970 * 1000)
            self.startedAt = backendItem.startedAt
            self.completedAt = backendItem.completedAt
            self.serviceGroupName = backendItem.serviceGroupName
            self.handledByUserDisplayname = backendItem.handledByUserDisplayname
            self.requestUserDisplayname = backendItem.requestUserDisplayname
            self.waitTimeSeconds = backendItem.waitTimeSeconds
            self.locallyModifiedAt = nil
            self.needsSync = false
        }
    }

    // MARK: - Initialization

    private init() {
        loadFromDisk()
    }

    // MARK: - Public Interface

    /// Get all cached items as DispatcherRequestHistoryItem for UI
    func getItems() -> [DispatcherRequestHistoryItem] {
        return queue.sync {
            cachedItems.map { cached in
                DispatcherRequestHistoryItem(
                    id: cached.id,
                    serviceGroupName: cached.serviceGroupName,
                    status: cached.status,
                    createdAt: cached.createdAt,
                    startedAt: cached.startedAt,
                    completedAt: cached.completedAt,
                    handledByUserDisplayname: cached.handledByUserDisplayname,
                    requestUserDisplayname: cached.requestUserDisplayname,
                    waitTimeSeconds: cached.waitTimeSeconds
                )
            }
        }
    }

    /// Add a new local request (called immediately when user triggers request)
    func addLocalRequest(id: String, status: String = "pending") {
        queue.async { [weak self] in
            guard let self = self else { return }

            // Check if already exists
            if self.cachedItems.contains(where: { $0.id == id }) {
                print("[DispatcherHistoryCache] Request \(id) already exists, skipping add")
                return
            }

            let newItem = CachedHistoryItem(
                id: id,
                status: status,
                createdAt: Int64(Date().timeIntervalSince1970 * 1000)
            )

            // Insert at beginning (newest first)
            self.cachedItems.insert(newItem, at: 0)

            // Trim to max entries
            if self.cachedItems.count > self.maxEntries {
                self.cachedItems = Array(self.cachedItems.prefix(self.maxEntries))
            }

            self.saveToDisk()
            print("[DispatcherHistoryCache] Added local request: \(id) with status: \(status)")
        }
    }

    /// Update status of a local request (e.g., when cancelled)
    func updateLocalStatus(id: String, status: String) {
        queue.async { [weak self] in
            guard let self = self else { return }

            if let index = self.cachedItems.firstIndex(where: { $0.id == id }) {
                self.cachedItems[index].status = status
                self.cachedItems[index].locallyModifiedAt = Date()
                self.cachedItems[index].needsSync = true
                self.saveToDisk()
                print("[DispatcherHistoryCache] Updated local status for \(id): \(status)")
            } else {
                print("[DispatcherHistoryCache] Request \(id) not found for status update")
            }
        }
    }

    /// Sync local cache with backend data
    /// Backend data takes priority except for very recent local changes that backend hasn't processed yet
    /// Note: This method is synchronous to ensure data is updated before getItems() is called
    func syncWithBackend(_ backendItems: [DispatcherRequestHistoryItem]) {
        queue.sync {
            var mergedItems: [CachedHistoryItem] = []
            let now = Date()

            // First, add all backend items
            for backendItem in backendItems {
                // Check if we have a local version
                if let localItem = self.cachedItems.first(where: { $0.id == backendItem.id }) {
                    // Backend has progressed past "pending" - always use backend version
                    if backendItem.status != "pending" {
                        mergedItems.append(CachedHistoryItem(from: backendItem))
                    }
                    // Backend still shows "pending" - check if we have recent local changes
                    else if let localModified = localItem.locallyModifiedAt,
                       now.timeIntervalSince(localModified) < self.localPriorityWindowSeconds,
                       localItem.needsSync {
                        mergedItems.append(localItem)
                    } else {
                        mergedItems.append(CachedHistoryItem(from: backendItem))
                    }
                } else {
                    mergedItems.append(CachedHistoryItem(from: backendItem))
                }
            }

            // Add any local-only items that are recent and not in backend yet
            for localItem in self.cachedItems {
                let isInMerged = mergedItems.contains(where: { $0.id == localItem.id })
                if !isInMerged {
                    if let localModified = localItem.locallyModifiedAt,
                       now.timeIntervalSince(localModified) < self.localPriorityWindowSeconds {
                        mergedItems.insert(localItem, at: 0)
                    }
                }
            }

            // Sort by createdAt (newest first) and trim
            mergedItems.sort { $0.createdAt > $1.createdAt }
            if mergedItems.count > self.maxEntries {
                mergedItems = Array(mergedItems.prefix(self.maxEntries))
            }

            self.cachedItems = mergedItems
            self.saveToDisk()
        }
    }

    /// Clear all cached data
    func clear() {
        queue.async { [weak self] in
            self?.cachedItems = []
            self?.saveToDisk()
            print("[DispatcherHistoryCache] Cache cleared")
        }
    }

    // MARK: - Persistence

    private var cacheFileURL: URL {
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documentsDir.appendingPathComponent(cacheFileName)
    }

    private func loadFromDisk() {
        queue.async { [weak self] in
            guard let self = self else { return }

            do {
                let data = try Data(contentsOf: self.cacheFileURL)
                let items = try JSONDecoder().decode([CachedHistoryItem].self, from: data)
                self.cachedItems = items
                print("[DispatcherHistoryCache] Loaded \(items.count) items from disk")
            } catch {
                // File might not exist yet, that's okay
                print("[DispatcherHistoryCache] Could not load from disk: \(error.localizedDescription)")
                self.cachedItems = []
            }
        }
    }

    private func saveToDisk() {
        // Note: Must be called from queue
        do {
            let data = try JSONEncoder().encode(cachedItems)
            try data.write(to: cacheFileURL, options: .atomic)
            print("[DispatcherHistoryCache] Saved \(cachedItems.count) items to disk")
        } catch {
            print("[DispatcherHistoryCache] Failed to save to disk: \(error.localizedDescription)")
        }
    }
}
