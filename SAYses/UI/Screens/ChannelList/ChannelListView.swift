import SwiftUI

struct ChannelListView: View {
    @Environment(AuthViewModel.self) private var authViewModel
    @StateObject private var mumbleService = MumbleService()
    @State private var searchText = ""
    @State private var showSettings = false
    @State private var showTransmissionMode = false
    @State private var showInfo = false
    @State private var favoriteIds: Set<UInt32> = []
    @State private var navigationPath = NavigationPath()
    @State private var showOnlyFavorites = false

    // Settings from AppStorage
    @AppStorage("transmissionMode") private var transmissionModeRaw = TransmissionMode.pushToTalk.rawValue

    private var transmissionMode: TransmissionMode {
        TransmissionMode(rawValue: transmissionModeRaw) ?? .pushToTalk
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            NavigationStack(path: $navigationPath) {
                Group {
                    if mumbleService.connectionState == .connecting {
                        connectingView
                    } else if mumbleService.connectionState == .failed {
                        errorView
                    } else {
                        channelListContent
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        profileMenu
                    }

                    ToolbarItem(placement: .topBarTrailing) {
                        optionsMenu
                    }
                }
                .navigationDestination(for: Channel.self) { channel in
                    ChannelView(channel: channel, mumbleService: mumbleService)
                        .onAppear {
                            mumbleService.currentlyViewedChannelId = channel.id
                        }
                        .onDisappear {
                            mumbleService.currentlyViewedChannelId = nil
                        }
                }
            }

            // Offline status banner at bottom
            OfflineStatusBanner(secondsUntilRetry: mumbleService.reconnectCountdown)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environment(authViewModel)
        }
        .sheet(isPresented: $showTransmissionMode) {
            TransmissionModeSheet()
        }
        .sheet(isPresented: $showInfo) {
            ServerInfoSheet(serverInfo: mumbleService.serverInfo, connectionState: mumbleService.connectionState)
        }
        .task {
            loadFavorites()
            await mumbleService.connectWithStoredCredentials()
        }
        // Handle auto-navigation from server channel changes
        .onReceive(mumbleService.$navigateToChannel) { channelId in
            guard let channelId = channelId else { return }
            if let channel = mumbleService.getChannel(channelId) {
                // Navigate to the channel
                navigationPath.append(channel)
                mumbleService.navigateToChannel = nil
            }
        }
        .onReceive(mumbleService.$navigateBackToList) { shouldNavigate in
            guard shouldNavigate else { return }
            // Pop back to root (channel list)
            navigationPath = NavigationPath()
            mumbleService.navigateBackToList = false
        }
    }

    // MARK: - Subviews

    private var connectingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Verbinde...")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
    }

    private var errorView: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 50))
                .foregroundStyle(.orange)

            Text("Verbindungsfehler")
                .font(.headline)

            if let error = mumbleService.errorMessage {
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Button("Erneut versuchen") {
                Task {
                    await mumbleService.reconnect()
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var channelListContent: some View {
        List {
            // Channels section
            Section {
                HStack {
                    Text("Kanäle")
                        .font(.title2)

                    Spacer()

                    Button {
                        showOnlyFavorites.toggle()
                    } label: {
                        Image(systemName: "star.fill")
                            .font(.title3)
                            .foregroundStyle(showOnlyFavorites ? Color(red: 1.0, green: 0.84, blue: 0) : .secondary)
                    }
                    .buttonStyle(.plain)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .padding(.horizontal)
                .padding(.top, 8)
            }

            Section {
                ForEach(filteredChannels) { channel in
                    ChannelRowButton(
                        channel: channel,
                        isFavorite: favoriteIds.contains(channel.id),
                        onTap: { joinAndNavigate(channel) }
                    )
                    .swipeActions(edge: .trailing) {
                        Button(action: { toggleFavorite(channel) }) {
                            Label(
                                favoriteIds.contains(channel.id) ? "Entfernen" : "Favorit",
                                systemImage: favoriteIds.contains(channel.id) ? "star.slash" : "star.fill"
                            )
                        }
                        .tint(.yellow)
                    }
                }
            }
        }
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Suchen...")
        .refreshable {
            await mumbleService.reconnect()
        }
    }

    private var profileMenu: some View {
        Menu {
            Button(action: {}) {
                Label("Alle Kanäle", systemImage: "list.bullet")
            }
            Button(action: {}) {
                Label("Nur Favoriten", systemImage: "star")
            }
            Divider()
            Button(action: {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    showInfo = true
                }
            }) {
                Label("Information", systemImage: "info.circle")
            }
            Button(action: {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    showSettings = true
                }
            }) {
                Label("Einstellungen", systemImage: "gear")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "person.circle.fill")
                    .font(.title2)
                Text(mumbleService.currentUserProfile?.effectiveName ?? "")
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
        }
    }

    private var optionsMenu: some View {
        Menu {
            Button(action: {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    showTransmissionMode = true
                }
            }) {
                Label("Übertragungsmodus", systemImage: "mic")
            }
            Button(action: {
                Task { await mumbleService.reconnect() }
            }) {
                Label("Neu laden", systemImage: "arrow.clockwise")
            }
            Divider()
            Button(role: .destructive, action: logout) {
                Label("Abmelden", systemImage: "rectangle.portrait.and.arrow.right")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title2)
        }
    }

    // MARK: - Computed Properties

    private var filteredChannels: [Channel] {
        var channels = mumbleService.getChannelsForDisplay()

        // Filter by favorites if enabled
        if showOnlyFavorites {
            channels = channels.filter { favoriteIds.contains($0.id) }
        }

        // Filter by search text
        if !searchText.isEmpty {
            channels = channels.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }

        return channels
    }


    // MARK: - Actions

    private func joinAndNavigate(_ channel: Channel) {
        // Join the channel on server
        mumbleService.joinChannel(channel.id)
        // Navigate to channel view
        navigationPath.append(channel)
    }

    private func toggleFavorite(_ channel: Channel) {
        if favoriteIds.contains(channel.id) {
            favoriteIds.remove(channel.id)
        } else {
            favoriteIds.insert(channel.id)
        }
        saveFavorites()
    }

    private func loadFavorites() {
        let ids = UserDefaults.standard.array(forKey: "favoriteChannels") as? [UInt32] ?? []
        favoriteIds = Set(ids)
    }

    private func saveFavorites() {
        UserDefaults.standard.set(Array(favoriteIds), forKey: "favoriteChannels")
    }

    private func logout() {
        mumbleService.disconnect()
        authViewModel.logout()
    }
}

// MARK: - Channel Row Button (tappable, not NavigationLink)

struct ChannelRowButton: View {
    let channel: Channel
    let isFavorite: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Channel icon
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .foregroundStyle(Color.semparaPrimary)

                // Channel name
                Text(channel.name)
                    .font(.body)
                    .foregroundStyle(.primary)

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

                // Chevron
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, CGFloat(channel.depth) * 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Server Info Sheet

struct ServerInfoSheet: View {
    let serverInfo: ServerInfo?
    let connectionState: ConnectionState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Verbindung") {
                    LabeledContent("Status", value: connectionState.displayText)
                }

                if let info = serverInfo {
                    Section("Server") {
                        LabeledContent("Version", value: info.serverVersion)
                        LabeledContent("Max. Benutzer", value: "\(info.maxUsers)")
                        LabeledContent("Max. Bandbreite", value: "\(info.maxBandwidth / 1000) kbit/s")
                    }

                    if !info.welcomeMessage.isEmpty {
                        Section("Willkommensnachricht") {
                            Text(info.welcomeMessage)
                                .font(.body)
                        }
                    }
                }

                Section("App") {
                    LabeledContent("Version", value: "1.0.0")
                    LabeledContent("Build", value: "1")
                }
            }
            .navigationTitle("Information")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    ChannelListView()
        .environment(AuthViewModel())
}
