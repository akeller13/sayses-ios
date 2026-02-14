import SwiftUI
import UIKit

enum ChannelListTab {
    case channels
    case dispatcher
}

enum DispatcherSubTab {
    case sendMessage  // "Meldung senden"
    case serviceDesk  // "Servicedienst"
}

/// Info struct for dispatcher recording dialog to avoid SwiftUI state timing issues
/// Using .fullScreenCover(item:) ensures values are captured at presentation time
struct DispatcherRecordingInfo: Identifiable {
    let id = UUID()
    let remainingSeconds: Int
    let dispatcherAlias: String
}

struct ChannelListView: View {
    @Environment(AuthViewModel.self) private var authViewModel
    @ObservedObject var mumbleService: MumbleService
    @State private var searchText = ""
    @State private var showSettings = false
    @State private var showTransmissionMode = false
    @State private var showInfo = false
    @State private var showProfile = false
    @State private var profileImage: UIImage?
    @State private var favoriteIds: Set<UInt32> = []
    @State private var navigationPath = NavigationPath()
    @State private var showOnlyFavorites = false
    @State private var selectedTab: ChannelListTab = .channels
    @State private var selectedDispatcherSubTab: DispatcherSubTab = .sendMessage
    @State private var isDispatcherTransmitting = false

    // Alarm state
    @State private var showAlarmCountdown = false
    @State private var showOpenAlarms = false

    // Post-alarm recording state
    @State private var showPostAlarmRecording = false
    @State private var remainingRecordingTime = 0

    // Dispatcher request state - using optional struct to avoid SwiftUI state timing issues
    @State private var dispatcherRecordingInfo: DispatcherRecordingInfo? = nil

    // Settings from AppStorage
    @AppStorage("transmissionMode") private var transmissionModeRaw = TransmissionMode.pushToTalk.rawValue
    @AppStorage("keepAwake") private var keepAwake = true

    private var transmissionMode: TransmissionMode {
        TransmissionMode(rawValue: transmissionModeRaw) ?? .pushToTalk
    }

    var body: some View {
        // Ghost kick: show full-screen message without navigation chrome
        if mumbleService.ghostKickMessage != nil {
            ghostKickView
        } else {
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
                            print("[ChannelListView] ChannelView appeared for channel \(channel.id)")
                            mumbleService.currentlyViewedChannelId = channel.id
                        }
                        .onDisappear {
                            print("[ChannelListView] ChannelView disappeared for channel \(channel.id)")
                            mumbleService.currentlyViewedChannelId = nil
                        }
                }
                .onChange(of: navigationPath) { oldPath, newPath in
                    // Sync currentlyViewedChannelId with navigation state for reliability
                    if newPath.isEmpty {
                        mumbleService.currentlyViewedChannelId = nil
                    }
                }
            }
            // Alarm button - using safeAreaInset to not interfere with NavigationStack
            // Only show on channels tab, not on dispatcher tab
            .safeAreaInset(edge: .bottom) {
                if selectedTab == .channels && navigationPath.isEmpty && mumbleService.userPermissions.canTriggerAlarm && mumbleService.connectionState == .synchronized {
                    AlarmTriggerButton(
                        isEnabled: !mumbleService.hasOwnOpenAlarm,
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

            // "Meldung abgebrochen" toast - appears at top center
            if mumbleService.showDispatcherCancelledToast {
                VStack {
                    Text("Meldung abgebrochen")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(
                            Capsule()
                                .fill(Color.black.opacity(0.8))
                        )
                        .padding(.top, 60)

                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .onAppear {
                    // Auto-hide after 2 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        withAnimation(.easeOut(duration: 0.3)) {
                            mumbleService.showDispatcherCancelledToast = false
                        }
                    }
                }
                .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: mumbleService.showDispatcherCancelledToast)
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
        .sheet(isPresented: $showProfile, onDismiss: { loadProfileImage() }) {
            ProfileView(mumbleService: mumbleService)
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
        .fullScreenCover(item: $dispatcherRecordingInfo) { info in
            DispatcherRecordingDialog(
                remainingSeconds: info.remainingSeconds,
                dispatcherAlias: info.dispatcherAlias,
                onSubmit: {
                    // User submitted recording
                    print("[ChannelListView] DispatcherRecordingDialog onSubmit called")
                    dispatcherRecordingInfo = nil
                    Task {
                        await mumbleService.submitDispatcherVoiceRecording()
                    }
                },
                onCancel: {
                    // User cancelled recording
                    print("[ChannelListView] DispatcherRecordingDialog onCancel called")
                    dispatcherRecordingInfo = nil
                    Task {
                        await mumbleService.cancelDispatcherVoiceRecording()
                    }
                }
            )
        }
        .task {
            loadFavorites()
            await mumbleService.connectWithStoredCredentials()
            loadProfileImage()
        }
        .onAppear {
            if keepAwake {
                UIApplication.shared.isIdleTimerDisabled = true
            }
        }
        // Start/stop dispatcher history SSE stream based on tab selection
        .onChange(of: selectedTab) { oldValue, newValue in
            if newValue == .dispatcher {
                print("[ChannelListView] Dispatcher tab selected - starting SSE stream")
                mumbleService.startDispatcherHistoryStream()
            } else if oldValue == .dispatcher {
                print("[ChannelListView] Leaving dispatcher tab - stopping SSE stream")
                mumbleService.stopDispatcherHistoryStream()
            }
        }
        // Handle auto-navigation from server channel changes
        .onReceive(mumbleService.$navigateToChannel) { channelId in
            guard let channelId = channelId else { return }
            // Suppress navigation to channel detail when activeCall is true
            if mumbleService.activeCall {
                print("[ChannelListView] activeCall=true - suppressing navigateToChannel \(channelId), switching to dispatcher tab")
                mumbleService.navigateToChannel = nil
                if !navigationPath.isEmpty {
                    navigationPath = NavigationPath()
                }
                selectedTab = .dispatcher
                return
            }
            if let channel = mumbleService.getChannel(channelId) {
                navigationPath.append(channel)
                mumbleService.navigateToChannel = nil
            } else {
                // Channel not yet in list - will retry on next channels update
                print("[ChannelListView] Channel \(channelId) not found for navigation, waiting...")
            }
        }
        // Retry navigation when channels update (handles timing issues)
        .onReceive(mumbleService.$channels) { _ in
            guard let channelId = mumbleService.navigateToChannel else { return }
            // Suppress navigation when activeCall is true
            if mumbleService.activeCall {
                print("[ChannelListView] activeCall=true - suppressing channel retry navigation \(channelId)")
                mumbleService.navigateToChannel = nil
                return
            }
            if let channel = mumbleService.getChannel(channelId) {
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
        // Direct observation of local user channel (more reliable than onAppear/onDisappear)
        // When user is moved to tenant/root channel while viewing another channel, pop back to list
        .onChange(of: mumbleService.localUserChannelId) { oldValue, newValue in
            guard !navigationPath.isEmpty else { return }

            let isInTenantOrRoot = newValue == 0 || newValue == mumbleService.tenantChannelId
            if isInTenantOrRoot {
                print("[ChannelListView] User moved to tenant/root channel - popping navigation")
                navigationPath = NavigationPath()
            }
        }
        // Switch to dispatcher tab when triggered from ChannelView
        .onChange(of: mumbleService.switchToDispatcherTab) { _, newValue in
            guard newValue else { return }
            selectedTab = .dispatcher
            mumbleService.switchToDispatcherTab = false
        }
        // Stop transmission if dispatcher conversation ends while PTT is pressed
        .onChange(of: mumbleService.isInDispatcherConversation) { _, newValue in
            if !newValue && isDispatcherTransmitting {
                isDispatcherTransmitting = false
                mumbleService.stopTransmitting()
            }
        }
        .overlay(alignment: .topLeading) {
            if let profileImage, navigationPath.isEmpty, mumbleService.currentlyViewedChannelId == nil {
                Menu {
                    Button {
                        showProfile = true
                    } label: {
                        Label("Profil", systemImage: "person.crop.circle")
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
                    Image(uiImage: profileImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 70, height: 70)
                        .clipShape(Circle())
                }
                .padding(.leading, 10)
                .padding(.top, 0)
            }
        }
        } // else (not ghost kick)
    }

    // MARK: - Ghost Kick View

    private var ghostKickView: some View {
        VStack(spacing: 30) {
            Spacer()

            Image("LaunchLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 120, height: 120)

            VStack(spacing: 12) {
                Image(systemName: "iphone.and.arrow.forward")
                    .font(.system(size: 40))
                    .foregroundStyle(.blue)

                Text("Anderes Gerät angemeldet")
                    .font(.headline)

                if let message = mumbleService.ghostKickMessage {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }

            Button("Erneut anmelden") {
                mumbleService.disconnect()
                authViewModel.logout()
            }
            .buttonStyle(.borderedProminent)

            Spacer()
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

    // MARK: - Dispatcher Request Helpers

    /// Trigger dispatcher request and show recording dialog
    private func triggerDispatcherRequestAndShowRecording() {
        let maxDuration = mumbleService.alarmSettings.dispatcherVoiceMaxDuration
        let alias = mumbleService.alarmSettings.dispatcherAlias

        print("[ChannelListView] triggerDispatcherRequestAndShowRecording called")
        print("[ChannelListView]   dispatcherVoiceMaxDuration = \(maxDuration)")
        print("[ChannelListView]   dispatcherAlias = \(alias)")
        print("[ChannelListView]   isRecordingVoice BEFORE = \(mumbleService.isRecordingVoice)")

        // Start voice recording immediately
        mumbleService.startDispatcherVoiceRecording()

        print("[ChannelListView]   isRecordingVoice AFTER = \(mumbleService.isRecordingVoice)")

        // Show recording dialog - using struct to ensure values are captured correctly
        // This avoids SwiftUI state timing issues where the dialog might see stale values
        dispatcherRecordingInfo = DispatcherRecordingInfo(
            remainingSeconds: maxDuration,
            dispatcherAlias: alias
        )
        print("[ChannelListView]   dispatcherRecordingInfo created with remainingSeconds = \(maxDuration)")

        // Trigger request in background
        Task {
            await mumbleService.triggerDispatcherRequest()
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

    private var hasBothDispatcherPermissions: Bool {
        mumbleService.userPermissions.canCallDispatcher && mumbleService.userPermissions.canActAsDispatcher
    }

    private var dispatcherRequestButton: some View {
        DispatcherRequestButton(
            holdDuration: Double(mumbleService.alarmSettings.dispatcherButtonHoldTime),
            dispatcherAlias: mumbleService.alarmSettings.dispatcherAlias,
            onHoldStart: {
                // Start GPS warm-up
                mumbleService.startDispatcherRequestWarmUp()
            },
            onHoldComplete: {
                // Trigger request and start voice recording
                triggerDispatcherRequestAndShowRecording()
            },
            onHoldCancel: {
                // Cancel warm-up
                mumbleService.cancelDispatcherRequestWarmUp()
            }
        )
    }

    private var dispatcherResumeButton: some View {
        Button {
            if let channelId = mumbleService.currentDispatcherChannelId {
                mumbleService.joinChannel(channelId)
            }
        } label: {
            HStack {
                Image(systemName: "phone.arrow.up.right")
                    .font(.title2)
                Text("Gespräch fortsetzen")
                    .font(.headline)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Color.dispatcherOrange)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
    }

    private var dispatcherHistorySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text("Ihre letzten Meldungen")
                    .font(.headline)
                    .padding(.top, 8)

                if mumbleService.isLoadingDispatcherHistory {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding(.vertical, 20)
                } else if mumbleService.dispatcherRequestHistory.isEmpty {
                    Text("Keine Meldungen vorhanden")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 20)
                } else {
                    // Header row
                    HStack(spacing: 0) {
                        Text("Datum")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Status")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity, alignment: .center)
                        Text("Warten")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .foregroundStyle(.secondary)

                    Divider()

                    // History rows
                    ForEach(mumbleService.dispatcherRequestHistory) { item in
                        HStack(spacing: 0) {
                            // Date/Time
                            VStack(alignment: .leading, spacing: 2) {
                                if let createdAt = item.createdAt {
                                    let date = Date(timeIntervalSince1970: Double(createdAt) / 1000)
                                    Text(date, format: .dateTime.day().month())
                                        .font(.caption)
                                    Text(date, format: .dateTime.hour().minute())
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            // Status
                            Text(formatDispatcherStatus(item.status))
                                .font(.caption)
                                .foregroundStyle(statusColor(for: item.status))
                                .frame(maxWidth: .infinity, alignment: .center)

                            // Wait time
                            Text(formatWaitTime(item.waitTimeSeconds, createdAt: item.createdAt, status: item.status))
                                .font(.caption)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .padding(.vertical, 4)

                        if item.id != mumbleService.dispatcherRequestHistory.last?.id {
                            Divider()
                        }
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    private func formatDispatcherStatus(_ status: String) -> String {
        switch status {
        case "completed": return "Erledigt"
        case "cancelled": return "Abgebr."
        case "pending": return "Wartend"
        case "in_progress": return "Aktiv"
        default: return status
        }
    }

    private func statusColor(for status: String) -> Color {
        switch status {
        case "completed": return .green
        case "cancelled": return .red
        case "pending": return .orange
        case "in_progress": return .blue
        default: return .primary
        }
    }

    private func formatWaitTime(_ seconds: Int?, createdAt: Int64?, status: String) -> String {
        var waitSeconds = seconds

        // If no wait time from backend (started_at is null) but request is pending,
        // calculate elapsed time from createdAt to now
        if waitSeconds == nil, let createdAt = createdAt, status == "pending" || status == "in_progress" {
            let createdDate = Date(timeIntervalSince1970: Double(createdAt) / 1000)
            waitSeconds = Int(Date().timeIntervalSince(createdDate))
        }

        guard let seconds = waitSeconds, seconds > 0 else { return "-" }

        if seconds < 3600 {
            // Less than 1 hour: show minutes
            let mins = max(1, seconds / 60)  // At least 1 min
            return "\(mins) min"
        } else {
            // 1 hour or more: show hours and minutes
            let hours = seconds / 3600
            let mins = (seconds % 3600) / 60
            if mins > 0 {
                return "\(hours)h \(mins)m"
            } else {
                return "\(hours)h"
            }
        }
    }

    private var channelListContent: some View {
        VStack(spacing: 0) {
            // Fixed tab bar
            VStack(spacing: 0) {
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
                    .disabled(mumbleService.isInDispatcherConversation)
                    .opacity(mumbleService.isInDispatcherConversation ? 0.3 : 1.0)

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
                            HStack(spacing: 4) {
                                if mumbleService.isDispatcherModeActive {
                                    Circle()
                                        .fill(Color(red: 0xF5/255.0, green: 0x7C/255.0, blue: 0x00/255.0))
                                        .frame(width: 8, height: 8)
                                }
                                Text(mumbleService.alarmSettings.dispatcherAlias)
                                    .font(.title2)
                                    .fontWeight(selectedTab == .dispatcher ? .bold : .regular)
                                    .foregroundStyle(selectedTab == .dispatcher ? .primary : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
                .padding(.top, profileImage != nil ? 46 : 8)
                .padding(.bottom, 6)

                // Divider line directly under tabs
                Rectangle()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(height: 1)
            }
            .background(Color(UIColor.systemGroupedBackground))

            List {
            // Sub-tabs for dispatcher (Meldung/Servicedienst)
            if selectedTab == .dispatcher && hasBothDispatcherPermissions {
                Section {
                    HStack {
                        // "Meldung" tab (left)
                        Button {
                            selectedDispatcherSubTab = .sendMessage
                        } label: {
                            Text("Meldung")
                                .font(.title3)
                                .fontWeight(selectedDispatcherSubTab == .sendMessage ? .bold : .regular)
                                .foregroundStyle(selectedDispatcherSubTab == .sendMessage ? .primary : .secondary)
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        // "Servicedienst" tab (right)
                        Button {
                            selectedDispatcherSubTab = .serviceDesk
                        } label: {
                            Text("Servicedienst")
                                .font(.title3)
                                .fontWeight(selectedDispatcherSubTab == .serviceDesk ? .bold : .regular)
                                .foregroundStyle(selectedDispatcherSubTab == .serviceDesk ? .primary : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal)
                    .padding(.top, 4)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
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
                            subdomain: mumbleService.tenantSubdomain,
                            certificateHash: mumbleService.credentials?.certificateHash,
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
                // Dispatcher tab content
                if hasBothDispatcherPermissions {
                    // Content based on selected sub-tab (sub-tabs are now in header section above)
                    if selectedDispatcherSubTab == .sendMessage {
                        if mumbleService.isInDispatcherConversation {
                            Section {
                                PttButton(
                                    isTransmitting: isDispatcherTransmitting,
                                    audioLevel: mumbleService.audioInputLevel,
                                    onPressed: {
                                        isDispatcherTransmitting = true
                                        mumbleService.startTransmitting()
                                    },
                                    onReleased: {
                                        isDispatcherTransmitting = false
                                        mumbleService.stopTransmitting()
                                    },
                                    inactiveColor: .dispatcherOrange
                                )
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 20)
                            }
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                        } else if mumbleService.dispatcherConversationStatus == .interrupted {
                            Section {
                                dispatcherResumeButton
                            }
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                        } else {
                            Section {
                                dispatcherRequestButton
                            }
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                        }

                        // Dispatcher request history
                        dispatcherHistorySection
                    } else {
                        Section {
                            Text("Servicedienst - Inhalt folgt...")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 40)
                        }
                    }
                } else {
                    // Only one permission - show single content
                    if mumbleService.userPermissions.canCallDispatcher {
                        if mumbleService.isInDispatcherConversation {
                            Section {
                                PttButton(
                                    isTransmitting: isDispatcherTransmitting,
                                    audioLevel: mumbleService.audioInputLevel,
                                    onPressed: {
                                        isDispatcherTransmitting = true
                                        mumbleService.startTransmitting()
                                    },
                                    onReleased: {
                                        isDispatcherTransmitting = false
                                        mumbleService.stopTransmitting()
                                    },
                                    inactiveColor: .dispatcherOrange
                                )
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 20)
                            }
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                        } else if mumbleService.dispatcherConversationStatus == .interrupted {
                            Section {
                                dispatcherResumeButton
                            }
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                        } else {
                            Section {
                                dispatcherRequestButton
                            }
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                        }

                        // Dispatcher request history
                        dispatcherHistorySection
                    } else {
                        Section {
                            Text("Servicedienst - Inhalt folgt...")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 40)
                        }
                    }
                }
            }
        }
            .refreshable {
                await mumbleService.reconnect()
            }
        } // VStack
    }

    private var profileMenu: some View {
        Menu {
            Button {
                showProfile = true
            } label: {
                Label("Profil", systemImage: "person.crop.circle")
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
                if profileImage == nil {
                    Image(systemName: "person.circle.fill")
                        .font(.title2)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(mumbleService.currentUserProfile?.effectiveName ?? "")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if let jobFunction = mumbleService.currentUserProfile?.jobFunction,
                       !jobFunction.isEmpty {
                        Text(jobFunction)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: 180, alignment: .leading)
            }
            .padding(.leading, profileImage != nil ? 76 : 0)
        }
    }

    private func loadProfileImage() {
        guard let username = mumbleService.credentials?.username else { return }

        // Load from local cache immediately
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let url = cacheDir.appendingPathComponent("profile_\(username).jpg")
        if let data = try? Data(contentsOf: url) {
            profileImage = UIImage(data: data)
        }

        // Fetch from backend (image + name/function metadata)
        guard let subdomain = mumbleService.tenantSubdomain,
              let certificateHash = mumbleService.credentials?.certificateHash else { return }

        Task {
            do {
                let response = try await SemparaAPIClient().fetchUserProfile(
                    subdomain: subdomain,
                    certificateHash: certificateHash,
                    username: username
                )
                await MainActor.run {
                    if let data = response.imageData, let image = UIImage(data: data) {
                        profileImage = image
                        // Update local cache
                        try? data.write(to: url)
                    }
                    mumbleService.updateCurrentUserProfile(
                        firstName: response.firstName,
                        lastName: response.lastName,
                        jobFunction: response.jobFunction
                    )
                }
            } catch {
                print("[ChannelList] Failed to load profile: \(error)")
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
        // Set viewed channel BEFORE join — so handleChannelSync sees the correct state
        // when the server confirms the channel change (closes timing gap with onAppear)
        mumbleService.currentlyViewedChannelId = channel.id
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
    let subdomain: String?
    let certificateHash: String?
    let onTap: () -> Void
    @StateObject private var imageCache = ChannelImageCache.shared

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Channel image or fallback icon
                channelImage
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

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
                    LabeledContent("Version", value: "1.0.0")
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

                Section("Server Einstellungen") {
                    LabeledContent("GPS-User-Tracking", value: mumbleService.alarmSettings.gpsUserTracking ? "Aktiv" : "Inaktiv")
                    LabeledContent("GPS-Tracking-Intervall", value: "\(mumbleService.alarmSettings.gpsTrackingInterval)s")
                    LabeledContent("Haltezeit Alarmbutton", value: formatHoldDuration(mumbleService.alarmSettings.alarmHoldDuration))
                    LabeledContent("Countdown-Dauer", value: "\(mumbleService.alarmSettings.alarmCountdownDuration)s")
                    LabeledContent("Max. Dauer Alarm-Sprachnotiz", value: "\(mumbleService.alarmSettings.alarmVoiceNoteDuration)s")
                    LabeledContent("Dispatcher Alias", value: mumbleService.alarmSettings.dispatcherAlias)
                    LabeledContent("Haltezeit Dispatcher-Button", value: formatHoldDuration(mumbleService.alarmSettings.dispatcherButtonHoldTime))
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

                Section("Open-Source-Lizenzen") {
                    NavigationLink {
                        LicenseDetailView(
                            title: "KeychainAccess",
                            licenseType: "MIT License",
                            text: """
                            Copyright (c) 2014 kishikawa katsumi

                            Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

                            The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

                            THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
                            """
                        )
                    } label: {
                        LicenseRow(name: "KeychainAccess", licenseType: "MIT")
                    }

                    NavigationLink {
                        LicenseDetailView(
                            title: "libopus",
                            licenseType: "BSD License",
                            text: """
                            Copyright 2001-2011 Xiph.Org, Skype Limited, Octasic, Jean-Marc Valin, Timothy B. Terriberry, CSIRO, Gregory Maxwell, Mark Borgerding, Erik de Castro Lopo

                            Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

                            - Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

                            - Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

                            - Neither the name of Internet Society, IETF or IETF Trust, nor the names of specific contributors, may be used to endorse or promote products derived from this software without specific prior written permission.

                            THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

                            Opus is subject to the royalty-free patent licenses which are specified at:

                            Xiph.Org Foundation:
                            https://datatracker.ietf.org/ipr/1524/

                            Microsoft Corporation:
                            https://datatracker.ietf.org/ipr/1914/

                            Broadcom Corporation:
                            https://datatracker.ietf.org/ipr/1526/
                            """
                        )
                    } label: {
                        LicenseRow(name: "libopus", licenseType: "BSD")
                    }

                    NavigationLink {
                        LicenseDetailView(
                            title: "Speex-iOS",
                            licenseType: "MIT License",
                            text: """
                            Copyright (c) 2018 245185601@qq.com

                            Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

                            The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

                            THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
                            """
                        )
                    } label: {
                        LicenseRow(name: "Speex-iOS", licenseType: "MIT")
                    }
                }

                Section("Impressum") {
                    LabeledContent("Autor", value: "Andreas Keller")
                    LabeledContent("E-Mail", value: "info@sayses.com")
                    LabeledContent("Telefon", value: "+49 15678 - 531.538")
                    LabeledContent("Note", value: "Coded in the Silicon Woods")
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

struct LicenseRow: View {
    let name: String
    let licenseType: String

    var body: some View {
        HStack {
            Text(name)
            Spacer()
            Text(licenseType)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct LicenseDetailView: View {
    let title: String
    let licenseType: String
    let text: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.caption)
                .padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    ChannelListView(mumbleService: MumbleService())
        .environment(AuthViewModel())
}
