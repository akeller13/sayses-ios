import Foundation
import Observation

@Observable
class ChannelListViewModel {
    var channels: [Channel] = []
    var favoriteChannels: [Channel] = []
    var transmissionMode: TransmissionMode = .pushToTalk
    var isLoading = false
    var errorMessage: String?

    private var favoriteIds: Set<UInt32> = []

    func loadChannels() async {
        isLoading = true

        // TODO: Load from Mumble connection
        // For now, use mock data
        channels = [
            Channel(id: 1, parentId: 0, name: "Allgemein", userCount: 5),
            Channel(id: 2, parentId: 0, name: "Team A", userCount: 3),
            Channel(id: 3, parentId: 0, name: "Team B"),
            Channel(id: 4, parentId: 2, name: "Unterkanal 1", userCount: 2, depth: 1),
            Channel(id: 5, parentId: 2, name: "Unterkanal 2", depth: 1),
        ]

        // Load favorites from storage
        loadFavorites()

        isLoading = false
    }

    func refresh() async {
        await loadChannels()
    }

    func reload() {
        Task {
            await loadChannels()
        }
    }

    func disconnect() {
        // TODO: Disconnect from Mumble
    }

    func filteredChannels(searchText: String) -> [Channel] {
        if searchText.isEmpty {
            return channels
        }
        return channels.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    func isFavorite(_ channel: Channel) -> Bool {
        favoriteIds.contains(channel.id)
    }

    func toggleFavorite(_ channel: Channel) {
        if favoriteIds.contains(channel.id) {
            favoriteIds.remove(channel.id)
        } else {
            favoriteIds.insert(channel.id)
        }
        saveFavorites()
        updateFavoriteChannels()
    }

    // MARK: - Private

    private func loadFavorites() {
        // UserDefaults stores numbers as NSNumber/Int, not UInt32
        // So we need to load as [Int] and convert to UInt32
        let ids = UserDefaults.standard.array(forKey: "favoriteChannels") as? [Int] ?? []
        favoriteIds = Set(ids.map { UInt32($0) })
        updateFavoriteChannels()
    }

    private func saveFavorites() {
        // Save as [Int] for UserDefaults compatibility
        let intIds = favoriteIds.map { Int($0) }
        UserDefaults.standard.set(intIds, forKey: "favoriteChannels")
    }

    private func updateFavoriteChannels() {
        favoriteChannels = channels.filter { favoriteIds.contains($0.id) }
    }
}
