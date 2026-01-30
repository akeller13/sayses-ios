import SwiftUI
import UIKit

enum ChannelListTab {
    case channels
    case dispatcher
}

struct ChannelListView: View {
    @Environment(AuthViewModel.self) private var authViewModel
    @ObservedObject var mumbleService: MumbleService
    @State private var searchText = ""
    @State private var showSettings = false
    @State private var showTransmissionMode = false
    @State private var showInfo = false
    @State private var favoriteIds: Set<UInt32> = []
    @State private var navigationPath = NavigationPath()
    @State private var showOnlyFavorites = false
    @State private var selectedTab: ChannelListTab = .channels

    // Alarm state
    @State private var showAlarmCountdown = false
    @State private var showOpenAlarms = false
    @State private var alarmTextVisible = true

    // Post-alarm recording state
    @State private var showPostAlarmRecording = false
    @State private var remainingRecordingTime = 0

    // Settings from AppStorage
    @AppStorage("transmissionMode") private var transmissionModeRaw = TransmissionMode.pushToTalk.rawValue
    @AppStorage("keepAwake") private var keepAwake = true

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
                        HStack(spacing: 16) {
                            // Open alarms button with badge
                            if mumbleService.userPermissions.canReceiveAlarm {
                                Button(action: { showOpenAlarms = true }) {
                                    ZStack(alignment: .topTrailing) {
                                        Image(systemName: "bell.fill")
                                            .font(.body)
                                            .foregroundStyle(mumbleService.openAlarms.isEmpty ? .secondary : Color.alarmRed)

                                        // Badge for open alarms count
                                        if !mumbleService.openAlarms.isEmpty {
                                            Text("\(mumbleService.openAlarms.count)")
                                                .font(.caption2)
                                                .fontWeight(.bold)
                                                .foregroundStyle(.white)
                                                .padding(4)
                                                .background(Color.alarmRed)
                                                .clipShape(Circle())
                                                .offset(x: 8, y: -8)
                                        }
                                    }
                                }
                            }

                            optionsMenu
                        }
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
            // Alarm button - using safeAreaInset to not interfere with NavigationStack
            // Only show on channels tab, not on dispatcher tab
            .safeAreaInset(edge: .bottom) {
                if selectedTab == .channels && mumbleService.userPermissions.canTriggerAlarm && mumbleService.connectionState == .synchronized && !mumbleService.hasOwnOpenAlarm {
                    AlarmTriggerButton(
                        holdDuration: Double(mumbleService.alarmSettings.alarmHoldDuration),
                        onHoldStart: {
                            // Phase 1 start: Begin GPS warm-up
                            mumbleService.startAlarmWarmUp()
                        },
                        onHoldComplete: {
                            // Phase 1 complete: Start voice recording and show countdown
                            mumbleService.startVoiceRecording()
                            showAlarmCountdown = true
                        },
                        onHoldCancel: {
                            // User released early: Cancel warm-up
                            mumbleService.cancelAlarmWarmUp()
                        }
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
            }

            // Offline status banner at bottom
            OfflineStatusBanner(secondsUntilRetry: mumbleService.reconnectCountdown)
                .allowsHitTesting(false)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environment(authViewModel)
        }
        .sheet(isPresented: $showTransmissionMode) {
            TransmissionModeSheet()
        }
        .sheet(isPresented: $showInfo) {
            InfoView(mumbleService: mumbleService)
        }
        .fullScreenCover(isPresented: $showAlarmCountdown) {
            AlarmCountdownDialog(
                countdownDuration: mumbleService.alarmSettings.alarmCountdownDuration,
                onCancel: {
                    // User cancelled during countdown - cancel everything including recording
                    showAlarmCountdown = false
                    mumbleService.cancelVoiceRecording()
                    mumbleService.cancelAlarmWarmUp()
                },
                onTriggerNow: { elapsedSeconds in
                    // User wants to trigger alarm immediately
                    showAlarmCountdown = false
                    triggerAlarmAndShowPostRecording(elapsedCountdownSeconds: elapsedSeconds)
                },
                onComplete: {
                    // Countdown complete - trigger alarm (full countdown elapsed)
                    showAlarmCountdown = false
                    triggerAlarmAndShowPostRecording(elapsedCountdownSeconds: mumbleService.alarmSettings.alarmCountdownDuration)
                }
            )
        }
        .fullScreenCover(isPresented: $showPostAlarmRecording) {
            PostAlarmRecordingDialog(
                remainingSeconds: remainingRecordingTime,
                onSubmit: {
                    // User submitted recording (early or auto)
                    print("[ChannelListView] PostAlarmRecordingDialog onSubmit called - closing dialog and submitting voice recording")
                    showPostAlarmRecording = false
                    Task {
                        await mumbleService.submitVoiceRecording()
                    }
                }
            )
        }
        .sheet(isPresented: $showOpenAlarms) {
            OpenAlarmsScreen(mumbleService: mumbleService)
        }
        .task {
            loadFavorites()
            await mumbleService.connectWithStoredCredentials()
        }
        .onAppear {
            if keepAwake {
                UIApplication.shared.isIdleTimerDisabled = true
            }
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
        // Blink animation for ALARM text
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            if !mumbleService.openAlarms.isEmpty {
                withAnimation(.easeInOut(duration: 0.25)) {
                    alarmTextVisible.toggle()
                }
            } else {
                alarmTextVisible = true
            }
        }
    }

    // MARK: - Alarm Helpers

    /// Trigger alarm and show post-recording dialog if there's remaining recording time
    private func triggerAlarmAndShowPostRecording(elapsedCountdownSeconds: Int) {
        // Prevent race condition: if this function is called multiple times for the same alarm
        // (e.g., both onComplete and onTriggerNow fire due to timing), only process the first call
        guard !showPostAlarmRecording else {
            print("[ChannelListView] triggerAlarmAndShowPostRecording: dialog already showing, ignoring duplicate call")
            return
        }

        // Calculate remaining recording time
        let totalVoiceNoteDuration = mumbleService.alarmSettings.alarmVoiceNoteDuration
        let remaining = totalVoiceNoteDuration - elapsedCountdownSeconds

        print("[ChannelListView] triggerAlarmAndShowPostRecording called")
        print("[ChannelListView]   remaining: \(remaining)")

        // Show dialog IMMEDIATELY if there's remaining time (don't wait for alarm trigger)
        if remaining > 0 {
            print("[ChannelListView] Showing PostAlarmRecordingDialog with \(remaining) seconds")
            remainingRecordingTime = remaining
            showPostAlarmRecording = true
        }

        // Trigger alarm in background (don't block UI)
        Task {
            await mumbleService.triggerAlarmWithoutStoppingRecording()

            // If no remaining time, submit immediately after alarm is triggered
            if remaining <= 0 {
                print("[ChannelListView] No remaining time - submitting immediately")
                await mumbleService.submitVoiceRecording()
            }
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

            Text("Verbindung fehlgeschlagen")
                .font(.headline)

            if let error = mumbleService.errorMessage {
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            // Debug info
            let hasSubdomain = UserDefaults.standard.string(forKey: "subdomain") != nil
            let hasCreds = CredentialsStore.shared.getStoredCredentials() != nil
            Text("Debug: subdomain=\(hasSubdomain), creds=\(hasCreds)")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Button("Erneut versuchen") {
                Task {
                    await mumbleService.reconnect()
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var hasDispatcherPermission: Bool {
        mumbleService.userPermissions.canCallDispatcher || mumbleService.userPermissions.canActAsDispatcher
    }

    private var channelListContent: some View {
        List {
            // Tab header section
            Section {
                HStack {
                    // Kanäle tab (left)
                    Button {
                        selectedTab = .channels
                    } label: {
                        Text("Kanäle")
                            .font(.title2)
                            .fontWeight(selectedTab == .channels ? .bold : .regular)
                            .foregroundStyle(selectedTab == .channels ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)

                    // Favorites star (only shown when channels tab is active)
                    if selectedTab == .channels {
                        Button {
                            showOnlyFavorites.toggle()
                        } label: {
                            Image(systemName: "star.fill")
                                .font(.title3)
                                .foregroundStyle(showOnlyFavorites ? Color(red: 1.0, green: 0.84, blue: 0) : .secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()

                    // Dispatcher tab (right, only if user has permission)
                    if hasDispatcherPermission {
                        Button {
                            selectedTab = .dispatcher
                        } label: {
                            Text(mumbleService.alarmSettings.dispatcherAlias)
                                .font(.title2)
                                .fontWeight(selectedTab == .dispatcher ? .bold : .regular)
                                .foregroundStyle(selectedTab == .dispatcher ? .primary : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .padding(.horizontal)
                .padding(.top, 8)
            }

            // Content based on selected tab
            if selectedTab == .channels {
                // Search field
                Section {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Suchen...", text: $searchText)
                    }
                }

                // Channel list
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
            } else {
                // Dispatcher tab content (placeholder)
                Section {
                    Text("Dispatcher-Inhalt folgt...")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 40)
                }
            }
        }
        .refreshable {
            await mumbleService.reconnect()
        }
    }

    private var profileMenu: some View {
        Menu {
            Button {
                showOnlyFavorites = false
            } label: {
                Label("Alle Kanäle", systemImage: "list.bullet")
            }

            Button {
                showOnlyFavorites = true
            } label: {
                Label("Nur Favoriten", systemImage: "star")
            }

            Divider()

            Button {
                showInfo = true
            } label: {
                Label("Information", systemImage: "info.circle")
            }

            Button {
                showSettings = true
            } label: {
                Label("Einstellungen", systemImage: "gear")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "person.circle.fill")
                    .font(.title2)
                Text(mumbleService.currentUserProfile?.effectiveName ?? "")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .frame(maxWidth: 180)
            }
        }
    }

    private var optionsMenu: some View {
        Menu {
            Button {
                showTransmissionMode = true
            } label: {
                Label("Übertragungsmodus", systemImage: "mic")
            }

            Button {
                Task { await mumbleService.reconnect() }
            } label: {
                Label("Neu laden", systemImage: "arrow.clockwise")
            }

            Divider()

            Button(role: .destructive) {
                logout()
            } label: {
                Label("Abmelden", systemImage: "rectangle.portrait.and.arrow.right")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title2)
        }
    }

    // MARK: - Computed Properties

    private var filteredChannels: [Channel] {
        // Access mumbleService.channels directly to ensure proper SwiftUI observation
        // (calling a function might not establish observation correctly)
        var channels = mumbleService.channels

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
        // UserDefaults stores numbers as NSNumber/Int, not UInt32
        // So we need to load as [Int] and convert to UInt32
        let ids = UserDefaults.standard.array(forKey: "favoriteChannels") as? [Int] ?? []
        favoriteIds = Set(ids.map { UInt32($0) })
    }

    private func saveFavorites() {
        // Save as [Int] for UserDefaults compatibility
        let intIds = favoriteIds.map { Int($0) }
        UserDefaults.standard.set(intIds, forKey: "favoriteChannels")
    }

    private func logout() {
        mumbleService.disconnect()
        authViewModel.logout()
    }

    // Note: triggerAlarm is now called via AlarmCountdownDialog.onComplete
    // The 3-phase workflow is:
    // 1. User holds button -> onHoldStart -> GPS warm-up
    // 2. Hold complete -> onHoldComplete -> Voice recording + Countdown dialog
    // 3. Countdown complete -> onComplete -> triggerAlarm()
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

// MARK: - Info View

struct InfoView: View {
    @ObservedObject var mumbleService: MumbleService
    @Environment(\.dismiss) private var dismiss

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    var body: some View {
        NavigationStack {
            List {
                Section("SAYses") {
                    LabeledContent("Version", value: "\(appVersion) (\(buildNumber))")
                }

                Section("Server") {
                    if let info = mumbleService.serverInfo {
                        LabeledContent("Version", value: info.serverVersion)
                        if !info.serverOs.isEmpty {
                            LabeledContent("Betriebssystem", value: info.serverOs)
                        }
                    } else {
                        LabeledContent("Version", value: "—")
                    }
                }

                Section("Kontrollkanal") {
                    LabeledContent("Latenz", value: formatLatency(mumbleService.latencyMs))
                    LabeledContent("Verschlüsselung", value: formatCipherSuite(mumbleService.tlsCipherSuite))
                }

                Section("Sprachkanal") {
                    LabeledContent("Latenz", value: formatLatency(mumbleService.latencyMs))
                    LabeledContent("Verschlüsselung", value: "128 bit OCB-AES-128")
                    LabeledContent("Transport", value: "UDP über TCP (Tunnel)")
                    LabeledContent("Codec", value: "Opus")
                }

                Section("Audio") {
                    if let info = mumbleService.serverInfo {
                        LabeledContent("Max. Bandbreite", value: "\(info.maxBandwidth / 1000) kbit/s")
                    } else {
                        LabeledContent("Max. Bandbreite", value: "—")
                    }
                }

                Section("Server Einstellungen") {
                    LabeledContent("Haltezeit Alarmbutton", value: formatHoldDuration(mumbleService.alarmSettings.alarmHoldDuration))
                    LabeledContent("Countdown-Dauer", value: "\(mumbleService.alarmSettings.alarmCountdownDuration)s")
                    LabeledContent("Wartezeit GPS-Fix", value: "\(mumbleService.alarmSettings.gpsWaitDuration)s")
                    LabeledContent("Max. Dauer Alarm-Sprachnotiz", value: "\(mumbleService.alarmSettings.alarmVoiceNoteDuration)s")
                    LabeledContent("Dispatcher Alias", value: mumbleService.alarmSettings.dispatcherAlias)
                    LabeledContent("Haltezeit Dispatcher-Button", value: formatHoldDuration(mumbleService.alarmSettings.dispatcherButtonHoldTime))
                    LabeledContent("Wartezeit GPS Dispatcher", value: "\(mumbleService.alarmSettings.dispatcherGpsWaitTime)s")
                    LabeledContent("Max. Dauer Dispatcher-Sprachnotiz", value: "\(mumbleService.alarmSettings.dispatcherVoiceMaxDuration)s")
                    LabeledContent("Letzte Aktualisierung", value: formatTimestamp(mumbleService.lastSettingsUpdate))
                }

                Section("Benutzer-Rechte") {
                    PermissionRow(label: "Alarme empfangen", hasPermission: mumbleService.userPermissions.canReceiveAlarm)
                    PermissionRow(label: "Alarme auslösen", hasPermission: mumbleService.userPermissions.canTriggerAlarm)
                    PermissionRow(label: "Alarme beenden", hasPermission: mumbleService.userPermissions.canEndAlarm)
                    PermissionRow(label: "AudioCast verwalten", hasPermission: mumbleService.userPermissions.canManageAudiocast)
                    PermissionRow(label: "AudioCast abspielen", hasPermission: mumbleService.userPermissions.canPlayAudiocast)
                    PermissionRow(label: "Dispatcher rufen", hasPermission: mumbleService.userPermissions.canCallDispatcher)
                    PermissionRow(label: "Als Dispatcher agieren", hasPermission: mumbleService.userPermissions.canActAsDispatcher)
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

    private func formatLatency(_ latencyMs: Int64) -> String {
        latencyMs < 0 ? "— ms" : "\(latencyMs) ms"
    }

    private func formatCipherSuite(_ cipherSuite: String) -> String {
        if cipherSuite.isEmpty { return "—" }
        var formatted = cipherSuite
        if formatted.hasPrefix("TLS_") {
            formatted = String(formatted.dropFirst(4))
        }
        return formatted.replacingOccurrences(of: "_", with: "-")
    }

    private func formatHoldDuration(_ duration: Float) -> String {
        duration == floor(duration) ? "\(Int(duration))s" : String(format: "%.1fs", duration)
    }

    private func formatTimestamp(_ date: Date?) -> String {
        guard let date = date else { return "—" }
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy HH:mm"
        formatter.locale = Locale(identifier: "de_DE")
        return formatter.string(from: date)
    }
}

struct PermissionRow: View {
    let label: String
    let hasPermission: Bool

    var body: some View {
        HStack {
            Image(systemName: hasPermission ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(hasPermission ? .green : .secondary)
            Text(label)
                .foregroundStyle(hasPermission ? .primary : .secondary)
            Spacer()
        }
    }
}

#Preview {
    ChannelListView(mumbleService: MumbleService())
        .environment(AuthViewModel())
}
