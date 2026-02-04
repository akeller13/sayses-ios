import Foundation
import Combine
import AVFoundation
import Network
import CoreLocation
import UIKit

/// Current user profile information
struct UserProfile {
    let username: String
    var firstName: String?
    var lastName: String?
    var jobFunction: String?

    var effectiveName: String {
        let parts = [firstName, lastName].compactMap { $0?.isEmpty == false ? $0 : nil }
        return parts.isEmpty ? shortUsername : parts.joined(separator: " ")
    }

    /// Username without @tenant suffix
    var shortUsername: String {
        username.components(separatedBy: "@").first ?? username
    }
}

/// Service that manages Mumble connection and channel data
class MumbleService: NSObject, ObservableObject, MumbleConnectionDelegate, ChannelUpdatesSSEDelegate, AlarmUpdatesSSEDelegate {
    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var channels: [Channel] = []
    @Published private(set) var users: [User] = []
    @Published private(set) var serverInfo: ServerInfo?
    @Published private(set) var errorMessage: String?
    @Published private(set) var ghostKickMessage: String?
    @Published private(set) var currentUserProfile: UserProfile?

    /// The channel the local user is currently in (from server state)
    @Published private(set) var localUserChannelId: UInt32 = 0

    /// Published when user should navigate to a specific channel
    @Published var navigateToChannel: UInt32? = nil

    /// Published when user should navigate back to channel list
    @Published var navigateBackToList: Bool = false

    /// Published when user should switch to dispatcher tab after navigating back
    @Published var switchToDispatcherTab: Bool = false

    /// Audio input level (0.0 - 1.0) for UI feedback
    @Published private(set) var audioInputLevel: Float = 0

    /// Is voice detected by VAD
    @Published private(set) var isVoiceDetected: Bool = false

    /// Seconds until next reconnect attempt (0 = not reconnecting)
    @Published private(set) var reconnectCountdown: Int = 0

    // MARK: - Alarm State
    @Published private(set) var alarmTriggerState: AlarmTriggerState = .idle
    @Published private(set) var currentAlarmId: String?
    @Published private(set) var isRecordingVoice: Bool = false
    @Published private(set) var openAlarms: [AlarmEntity] = []
    @Published private(set) var lastReceivedAlarm: AlarmEntity?
    @Published var receivedAlarmForAlert: AlarmEntity?  // Triggers alert dialog when set
    @Published var receivedEndAlarmForAlert: EndAlarmMessage?  // Triggers "alarm ended" dialog when set

    // MARK: - Dispatcher Request State
    @Published private(set) var currentDispatcherRequestId: String?
    @Published private(set) var isDispatcherRequestActive: Bool = false
    @Published private(set) var dispatcherRequestHistory: [DispatcherRequestHistoryItem] = []
    @Published private(set) var isLoadingDispatcherHistory: Bool = false
    @Published var showDispatcherCancelledToast: Bool = false  // Triggers "Meldung abgebrochen" toast
    private var dispatcherRequestBackendId: String?
    private var dispatcherVoiceFilePath: URL?
    private var pendingCancelRequestId: String?  // Used for retry after reconnect
    private let dispatcherHistoryCache = DispatcherHistoryCache.shared
    private var dispatcherHistorySSETask: Task<Void, Never>?  // SSE stream task

    // MARK: - Auto-Reconnect State
    private var lastCredentials: MumbleCredentials?
    private var userDisconnected = false  // true = user chose to disconnect, no auto-reconnect
    private var wasKicked = false  // true = kicked by server (ghost/duplicate), delayed reconnect
    private var reconnectAttempts = 0
    private let maxReconnectDelaySeconds: Int = 16 * 60  // 16 minutes max
    private var reconnectTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?
    private var ghostReconnectTask: Task<Void, Never>?
    private var nextReconnectTime: Date?
    private var hasNetwork = true  // assume network is available initially
    private var networkMonitor: NWPathMonitor?

    // MARK: - Hourly Settings Refresh
    private var settingsRefreshTask: Task<Void, Never>?
    private var alarmSyncTask: Task<Void, Never>?
    @Published private(set) var alarmSettings: AlarmSettings = .defaults
    @Published private(set) var lastSettingsUpdate: Date?
    @Published private(set) var userPermissions: UserPermissions = .none
    @Published private(set) var latencyMs: Int64 = -1
    @Published private(set) var tlsCipherSuite: String = ""

    private let apiClient = SemparaAPIClient()
    private let keycloakService = KeycloakAuthService()
    private let audioService = AudioService()
    private let locationService = LocationService()
    private lazy var positionTracker = PositionTracker(locationService: locationService, apiClient: apiClient)
    private let voiceRecorder = VoiceRecorder()
    private var _credentials: MumbleCredentials?
    private let mumbleConnection = MumbleConnection()
    private var channelUpdatesSSE: ChannelUpdatesSSE?
    private var alarmUpdatesSSE: AlarmUpdatesSSE?

    /// Public getter for credentials (for AudioCast API calls)
    var credentials: MumbleCredentials? {
        _credentials
    }

    // Alarm tracking
    private var currentVoiceFilePath: URL?
    private var alarmBackendId: String?
    private var alarmRepository: AlarmRepository?
    private var positionTrackingAlarmId: String?  // Alarm ID currently being position-tracked
    private var positionTrackingBackendId: String?  // Backend ID for position uploads

    // Opus codec for audio encoding/decoding
    private var opusCodec: OpusCodecBridge?
    private var audioSequenceNumber: Int64 = 0

    // Audio playback state
    private var isMixedPlaybackStarted = false

    // Tenant filtering
    private var _tenantSubdomain: String?
    private(set) var tenantChannelId: UInt32 = 0

    /// Public getter for tenant subdomain (for AudioCast API calls)
    var tenantSubdomain: String? {
        _tenantSubdomain
    }

    // Track currently viewed channel for sync
    var currentlyViewedChannelId: UInt32? = nil

    var localSession: UInt32 {
        return mumbleConnection.localSession
    }

    /// Check if user is in the tenant (root) channel
    var isInTenantChannel: Bool {
        localUserChannelId == 0 || localUserChannelId == tenantChannelId
    }

    /// Check if current user has an own open alarm (cannot trigger another while one is active)
    var hasOwnOpenAlarm: Bool {
        guard let username = credentials?.username else { return false }
        // Use case-insensitive comparison (backend might return different case)
        let usernameLower = username.lowercased()
        return openAlarms.contains { $0.triggeredByUsername.lowercased() == usernameLower }
    }

    private var audioLevelObserver: NSKeyValueObservation?
    private var voiceDetectedObserver: NSKeyValueObservation?
    private var cancellables = Set<AnyCancellable>()

    override init() {
        super.init()
        mumbleConnection.delegate = self
        observeAudioService()
        setupOpusCodec()
        setupNetworkMonitoring()
        setupAlarmRepository()
        loadDispatcherHistoryFromCache()
    }

    private func loadDispatcherHistoryFromCache() {
        // Load cached dispatcher history for immediate display
        let cachedItems = dispatcherHistoryCache.getItems()
        if !cachedItems.isEmpty {
            DispatchQueue.main.async {
                self.dispatcherRequestHistory = cachedItems
                print("[MumbleService] Loaded \(cachedItems.count) dispatcher history items from cache")
            }
        }
    }

    private func setupAlarmRepository() {
        Task { @MainActor in
            alarmRepository = AlarmRepository.shared()
            // Load existing alarms immediately so UI shows them right away
            let existingAlarms = alarmRepository?.getOpenAlarms() ?? []
            print("[MumbleService] AlarmRepository initialized with \(existingAlarms.count) existing alarms")
            for alarm in existingAlarms {
                print("[MumbleService]   Initial load: \(alarm.alarmId) lat=\(alarm.latitude ?? -999), lon=\(alarm.longitude ?? -999), hasLocation=\(alarm.hasLocation)")
            }
            if !existingAlarms.isEmpty {
                self.objectWillChange.send()
                openAlarms = existingAlarms
            }
        }
    }

    deinit {
        networkMonitor?.cancel()
        // Cancel tasks directly without creating new closures (avoids weak reference issues during deallocation)
        reconnectTask?.cancel()
        countdownTask?.cancel()
        ghostReconnectTask?.cancel()
        settingsRefreshTask?.cancel()
        alarmSyncTask?.cancel()
    }

    private func setupOpusCodec() {
        opusCodec = OpusCodecBridge()
        if opusCodec != nil {
            NSLog("[MumbleService] Opus codec initialized (48kHz, 64kbps)")
        } else {
            NSLog("[MumbleService] ERROR: Failed to initialize Opus codec")
        }
    }

    private func observeAudioService() {
        // Observe audio input level from AudioService
        audioService.$inputLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                self?.audioInputLevel = level
            }
            .store(in: &cancellables)

        audioService.$isVoiceDetected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] detected in
                self?.isVoiceDetected = detected
            }
            .store(in: &cancellables)
    }

    // MARK: - Network Monitoring

    private func setupNetworkMonitoring() {
        networkMonitor = NWPathMonitor()
        networkMonitor?.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }

            let wasAvailable = self.hasNetwork
            self.hasNetwork = path.status == .satisfied

            if self.hasNetwork && !wasAvailable {
                // Network restored
                print("[MumbleService] Network restored")
                if self.connectionState == .disconnected || self.connectionState == .failed {
                    if !self.userDisconnected && self.lastCredentials != nil {
                        print("[MumbleService] Network restored - attempting reconnect")
                        self.scheduleReconnect(immediate: true)
                    }
                }
            } else if !self.hasNetwork && wasAvailable {
                // Network lost
                print("[MumbleService] Network lost - canceling reconnect attempts")
                self.cancelReconnect()
            }
        }
        networkMonitor?.start(queue: DispatchQueue.global(qos: .utility))
    }

    // MARK: - Hourly Settings Refresh

    /// Start hourly settings refresh at the top of each hour.
    /// Fetches alarm settings from backend every 60 minutes.
    private func startHourlySettingsRefresh() {
        settingsRefreshTask?.cancel()
        settingsRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                // Calculate milliseconds until next full hour
                let now = Date()
                let calendar = Calendar.current
                var components = calendar.dateComponents([.year, .month, .day, .hour], from: now)
                components.hour! += 1
                components.minute = 0
                components.second = 0

                guard let nextHour = calendar.date(from: components) else {
                    try? await Task.sleep(nanoseconds: 60 * 60 * 1_000_000_000)  // fallback: 1 hour
                    continue
                }

                let delaySeconds = nextHour.timeIntervalSince(now)
                let delayMinutes = Int(delaySeconds / 60)
                print("[MumbleService] Next settings refresh in \(delayMinutes) minutes (at \(nextHour))")

                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                guard !Task.isCancelled else { return }

                // Fetch settings from backend
                await self?.refreshAlarmSettings()
            }
        }
    }

    /// Fetch alarm settings from backend and update local storage.
    private func refreshAlarmSettings() async {
        guard let subdomain = tenantSubdomain,
              let certificateHash = credentials?.certificateHash else {
            print("[MumbleService] No subdomain or certificate hash - skipping settings refresh")
            return
        }

        do {
            let settings = try await apiClient.getSettings(subdomain: subdomain, certificateHash: certificateHash)

            await MainActor.run {
                self.alarmSettings = settings
                self.lastSettingsUpdate = Date()
            }

            // Update fleet tracking based on settings
            positionTracker.updateBaseInterval(settings.gpsTrackingInterval)
            if settings.gpsUserTracking {
                if !positionTracker.isBackgroundEnabled {
                    positionTracker.setEnabled(true, subdomain: subdomain, certificateHash: certificateHash)
                    NSLog("[MumbleService] Fleet tracking started (gpsUserTracking=true, interval=%ds)", settings.gpsTrackingInterval)
                }
            } else {
                if positionTracker.isBackgroundEnabled {
                    positionTracker.setEnabled(false, subdomain: subdomain, certificateHash: certificateHash)
                    NSLog("[MumbleService] Fleet tracking stopped (gpsUserTracking=false)")
                }
            }

            print("[MumbleService] Hourly settings refresh: hold=\(settings.alarmHoldDuration)s, countdown=\(settings.alarmCountdownDuration)s, gpsWait=\(settings.gpsWaitDuration)s, voiceNote=\(settings.alarmVoiceNoteDuration)s, gpsTracking=\(settings.gpsUserTracking), trackingInterval=\(settings.gpsTrackingInterval)s")
        } catch {
            print("[MumbleService] Hourly settings refresh failed: \(error)")
        }

        // Also refresh user permissions
        await refreshUserPermissions()
    }

    /// Fetch user permissions from backend
    private func refreshUserPermissions() async {
        guard let subdomain = tenantSubdomain,
              let certificateHash = credentials?.certificateHash else {
            return
        }

        do {
            let response = try await apiClient.getUserAlarmPermissions(subdomain: subdomain, certificateHash: certificateHash)

            await MainActor.run {
                self.userPermissions = UserPermissions(
                    canReceiveAlarm: response.canReceiveAlarm,
                    canTriggerAlarm: response.canTriggerAlarm,
                    canEndAlarm: response.canEndAlarm,
                    canManageAudiocast: response.canManageAudiocast,
                    canPlayAudiocast: response.canPlayAudiocast,
                    canCallDispatcher: response.canCallDispatcher,
                    canActAsDispatcher: response.canActAsDispatcher
                )
            }

            print("[MumbleService] User permissions refreshed: receive=\(response.canReceiveAlarm), trigger=\(response.canTriggerAlarm), end=\(response.canEndAlarm)")
        } catch {
            print("[MumbleService] User permissions refresh failed: \(error)")
        }
    }

    /// Stop the hourly settings refresh task
    private func stopHourlySettingsRefresh() {
        settingsRefreshTask?.cancel()
        settingsRefreshTask = nil
    }

    // MARK: - Alarm Sync Timer (every 20 seconds)

    /// Start periodic alarm sync every 20 seconds
    private func startAlarmSyncTimer() {
        alarmSyncTask?.cancel()
        alarmSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                // Wait 20 seconds
                try? await Task.sleep(nanoseconds: 20 * 1_000_000_000)

                guard !Task.isCancelled else { break }

                // Sync alarms with backend
                await self?.syncAlarms()
            }
        }
        print("[MumbleService] Alarm sync timer started (20s interval)")
    }

    /// Stop the alarm sync timer
    private func stopAlarmSyncTimer() {
        alarmSyncTask?.cancel()
        alarmSyncTask = nil
        print("[MumbleService] Alarm sync timer stopped")
    }

    // MARK: - Channel Updates SSE

    /// Start SSE connection for real-time channel permission updates
    private func startChannelUpdatesSSE() {
        guard let subdomain = tenantSubdomain,
              let certificateHash = credentials?.certificateHash else {
            print("[MumbleService] Cannot start channel updates SSE: missing credentials")
            return
        }

        // Stop any existing SSE connection
        channelUpdatesSSE?.stop()

        // Create and start new SSE connection
        let sse = ChannelUpdatesSSE(subdomain: subdomain, certificateHash: certificateHash)
        sse.delegate = self
        sse.start()
        channelUpdatesSSE = sse

        print("[MumbleService] Channel updates SSE started for \(subdomain)")
    }

    /// Stop the SSE connection for channel updates
    private func stopChannelUpdatesSSE() {
        channelUpdatesSSE?.stop()
        channelUpdatesSSE = nil
        print("[MumbleService] Channel updates SSE stopped")
    }

    // MARK: - ChannelUpdatesSSEDelegate

    func channelPermissionsChanged(action: String, channelIds: [String]) {
        print("[MumbleService] SSE: Channel permissions \(action) for \(channelIds.count) channel(s)")

        // Request fresh permissions from Mumble server
        mumbleConnection.requestAllChannelPermissions()

        // Delay slightly then refresh channel list (give Mumble server time to update ACLs)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            // Trigger channel list update by re-applying filtering
            let currentChannels = self.mumbleConnection.getChannelList()
            self.channelsUpdated(currentChannels)
            print("[MumbleService] Channel list refreshed after SSE update")
        }
    }

    func sseConnectionStateChanged(isConnected: Bool) {
        print("[MumbleService] SSE connection state: \(isConnected ? "connected" : "disconnected")")
    }

    // MARK: - Alarm Updates SSE

    /// Start SSE connection for real-time alarm updates
    private func startAlarmUpdatesSSE() {
        guard let subdomain = tenantSubdomain,
              let certificateHash = credentials?.certificateHash else {
            print("[MumbleService] Cannot start alarm updates SSE: missing credentials")
            return
        }

        // Stop any existing SSE connection
        alarmUpdatesSSE?.stop()

        // Create and start new SSE connection
        let sse = AlarmUpdatesSSE(subdomain: subdomain, certificateHash: certificateHash)
        sse.delegate = self
        sse.start()
        alarmUpdatesSSE = sse

        print("[MumbleService] Alarm updates SSE started for \(subdomain)")
    }

    /// Stop the SSE connection for alarm updates
    private func stopAlarmUpdatesSSE() {
        alarmUpdatesSSE?.stop()
        alarmUpdatesSSE = nil
        print("[MumbleService] Alarm updates SSE stopped")
    }

    // MARK: - AlarmUpdatesSSEDelegate

    @MainActor
    func alarmStarted(_ data: AlarmSSEData) {
        NSLog("[MumbleService] SSE: alarm_started id=%@", data.id)
        NSLog("[MumbleService] SSE:   currentAlarmId=%@, alarmBackendId=%@", currentAlarmId ?? "nil", alarmBackendId ?? "nil")
        NSLog("[MumbleService] SSE:   sseUsername=%@, myUsername=%@", data.alarmStartUserName ?? "nil", credentials?.username ?? "nil")
        print("[MumbleService] SSE: alarm_started \(data.id)")
        print("[MumbleService] SSE:   currentAlarmId=\(currentAlarmId ?? "nil"), alarmBackendId=\(alarmBackendId ?? "nil")")
        print("[MumbleService] SSE:   alarmTriggerState=\(alarmTriggerState), sseUsername=\(data.alarmStartUserName ?? "nil"), myUsername=\(credentials?.username ?? "nil")")

        // CRITICAL: Ignore if this is our own alarm (we triggered it)
        // Check 1: By alarm ID (may not match due to local vs backend ID)
        if data.id == currentAlarmId || data.id == alarmBackendId {
            NSLog("[MumbleService] SSE: Ignoring own alarm - matched by ID")
            print("[MumbleService] SSE: Ignoring own alarm - matched by ID")
            return
        }

        // Check 2: By username - ALWAYS check this regardless of state
        // This handles the race condition where SSE arrives before currentAlarmId is set
        if let myUsername = credentials?.username,
           let sseUsername = data.alarmStartUserName,
           myUsername.lowercased() == sseUsername.lowercased() {
            NSLog("[MumbleService] SSE: Ignoring own alarm - username match: %@", sseUsername)
            print("[MumbleService] SSE: Ignoring own alarm - matched by username: \(sseUsername)")
            // Store the backend ID for future reference
            if alarmBackendId == nil {
                alarmBackendId = data.id
            }
            return
        }

        // Check if user can receive alarms
        guard userPermissions.canReceiveAlarm else {
            print("[MumbleService] SSE: User cannot receive alarms - ignoring")
            return
        }

        // Ensure repository is initialized
        if alarmRepository == nil {
            alarmRepository = AlarmRepository.shared()
        }

        // Check for duplicate
        if alarmRepository?.alarmExists(alarmId: data.id) == true {
            print("[MumbleService] SSE: Alarm already exists - ignoring duplicate")
            return
        }

        // Create alarm entity from SSE data
        let alarm = AlarmEntity(
            alarmId: data.id,
            backendAlarmId: data.id,  // SSE uses backend ID directly
            triggeredByUsername: data.alarmStartUserName ?? "",
            triggeredByDisplayName: data.alarmStartUserDisplayname,
            triggeredByUserId: 0,  // Not available via SSE
            channelId: UInt32(data.channelId ?? 0),
            channelName: data.channelName ?? "",
            latitude: data.latitude,
            longitude: data.longitude,
            locationType: data.locationType,
            locationUpdatedAt: data.latitude != nil ? Date() : nil
        )
        alarmRepository?.insertAlarm(alarm)

        // Update published state
        lastReceivedAlarm = alarm
        openAlarms = alarmRepository?.getOpenAlarms() ?? []

        print("[MumbleService] SSE: Alarm stored: \(alarm.alarmId), open alarms: \(openAlarms.count)")

        // Play alarm sound
        let selectedSound = UserDefaults.standard.selectedAlarmSound
        AlarmSoundPlayer.shared.startAlarm(sound: selectedSound)
        NSLog("[MumbleService] SSE: TRIGGERING ALERT for alarm %@", alarm.alarmId)
        print("[MumbleService] SSE: Started alarm sound: \(selectedSound.displayName)")

        // Trigger alert dialog
        receivedAlarmForAlert = alarm
        print("[MumbleService] SSE: Alert dialog triggered for alarm: \(alarm.alarmId)")
    }

    @MainActor
    func alarmUpdated(_ data: AlarmSSEData) {
        print("[MumbleService] SSE: alarm_updated \(data.id)")
        print("[MumbleService] SSE:   location: lat=\(data.latitude ?? -999), lon=\(data.longitude ?? -999)")

        // Ensure repository is initialized
        if alarmRepository == nil {
            alarmRepository = AlarmRepository.shared()
        }

        // Find alarm by ID (try both alarmId and backendAlarmId)
        guard let alarm = alarmRepository?.getAlarm(byAlarmId: data.id) ??
                          alarmRepository?.getAlarm(byBackendId: data.id) else {
            print("[MumbleService] SSE: Alarm not found for update: \(data.id)")
            return
        }

        // Update location if provided
        if let lat = data.latitude, let lon = data.longitude {
            alarm.latitude = lat
            alarm.longitude = lon
            alarm.locationType = data.locationType
            alarm.locationUpdatedAt = Date()
        }

        // Update voice message status
        if let hasVoice = data.hasVoiceMessage, hasVoice {
            alarm.hasRemoteVoiceMessage = true
        }
        if let text = data.voiceMessageText {
            alarm.voiceMessageText = text
        }

        alarmRepository?.save()
        openAlarms = alarmRepository?.getOpenAlarms() ?? []

        print("[MumbleService] SSE: Alarm updated: \(alarm.alarmId)")
    }

    @MainActor
    func alarmEnded(alarmId: String, closedAt: Date, closedBy: String?) {
        print("[MumbleService] SSE: alarm_ended \(alarmId) by \(closedBy ?? "unknown")")
        print("[MumbleService] SSE:   currentAlarmId=\(currentAlarmId ?? "nil"), alarmBackendId=\(alarmBackendId ?? "nil")")

        // IMPORTANT: Determine if this is our own alarm BEFORE clearing the variables
        var wasOwnAlarm = alarmId == currentAlarmId || alarmId == alarmBackendId

        // Also check by username in repository (handles case where IDs were already cleared)
        if !wasOwnAlarm, let myUsername = credentials?.username {
            if let alarm = alarmRepository?.getAlarm(byAlarmId: alarmId) ?? alarmRepository?.getAlarm(byBackendId: alarmId) {
                if alarm.triggeredByUsername.lowercased() == myUsername.lowercased() {
                    wasOwnAlarm = true
                    print("[MumbleService] SSE: Detected own alarm by username match in repository")
                }
            }
        }

        // Stop tracking if this is our own alarm
        if wasOwnAlarm {
            print("[MumbleService] SSE: Stopping position tracking for ended own alarm")
            stopPositionTracking()
            currentAlarmId = nil
            alarmBackendId = nil
            alarmTriggerState = .idle
        }

        // Ensure repository is initialized
        if alarmRepository == nil {
            alarmRepository = AlarmRepository.shared()
        }

        // Check if alarm existed before we close it (for showing dialog)
        let alarmExisted = alarmRepository?.getAlarm(byAlarmId: alarmId) != nil ||
                           alarmRepository?.getAlarm(byBackendId: alarmId) != nil

        // Close alarm (try both alarmId and backendAlarmId)
        alarmRepository?.closeAlarm(alarmId: alarmId, closedAt: closedAt)

        // Also try to close by backend ID if alarm not found by alarmId
        if let alarm = alarmRepository?.getAlarm(byBackendId: alarmId) {
            alarmRepository?.closeAlarm(alarmId: alarm.alarmId, closedAt: closedAt)
        }

        // Refresh open alarms
        openAlarms = alarmRepository?.getOpenAlarms() ?? []

        // Stop alarm sound if no more open alarms
        if openAlarms.isEmpty {
            AlarmSoundPlayer.shared.stopAlarm()
            print("[MumbleService] SSE: Stopped alarm sound - no more open alarms")
        }

        // Clear lastReceivedAlarm if it was this alarm
        if lastReceivedAlarm?.alarmId == alarmId || lastReceivedAlarm?.backendAlarmId == alarmId {
            lastReceivedAlarm = nil
        }

        // Dismiss start alarm alert if showing this alarm
        if receivedAlarmForAlert?.alarmId == alarmId || receivedAlarmForAlert?.backendAlarmId == alarmId {
            receivedAlarmForAlert = nil
        }

        // Show "alarm ended" dialog only if:
        // 1. User can receive alarms
        // 2. We actually had this alarm (it existed in our repository before closing)
        // 3. It's not our own alarm that we triggered (we don't need to see "alarm ended" for our own alarm)
        if userPermissions.canReceiveAlarm && !wasOwnAlarm {
            // Only show dialog if we knew about this alarm (received it or had it stored)
            // Note: After closeAlarm(), the alarm is marked as closed but still exists
            if alarmExisted || lastReceivedAlarm?.alarmId == alarmId || lastReceivedAlarm?.backendAlarmId == alarmId {
                let endMessage = EndAlarmMessage(
                    id: alarmId,
                    userId: 0,  // Not available via SSE
                    userName: closedBy ?? "",
                    displayName: closedBy ?? "Unbekannt"
                )
                print("[MumbleService] SSE: Showing end alarm dialog - closedBy=\(closedBy ?? "unknown")")
                receivedEndAlarmForAlert = endMessage
            } else {
                print("[MumbleService] SSE: Not showing end dialog - alarm was not known to this device")
            }
        } else if wasOwnAlarm {
            print("[MumbleService] SSE: Not showing end dialog - this was our own alarm")
        }

        print("[MumbleService] SSE: Alarm closed, open alarms: \(openAlarms.count)")
    }

    @MainActor
    func alarmSSEConnectionStateChanged(isConnected: Bool) {
        print("[MumbleService] Alarm SSE connection state: \(isConnected ? "connected" : "disconnected")")

        // If SSE disconnects, do a one-time sync as fallback
        if !isConnected {
            Task {
                await syncAlarms()
            }
        }
    }

    // MARK: - Auto-Reconnect

    /// Schedule a reconnection attempt with exponential backoff.
    /// - Parameter immediate: If true, reconnect after 1 second (e.g., when network restored)
    private func scheduleReconnect(immediate: Bool = false) {
        logReconnectState("scheduleReconnect called, immediate=\(immediate)")

        if userDisconnected {
            print("[MumbleService] scheduleReconnect: user disconnected, not reconnecting")
            return
        }

        if lastCredentials == nil {
            print("[MumbleService] scheduleReconnect: no credentials, cannot reconnect")
            return
        }

        // Cancel any existing reconnect attempt
        cancelReconnect()

        let delaySeconds: Int
        if immediate {
            delaySeconds = 1  // Small delay to let network stabilize
        } else {
            // Exponential backoff: 2s, 4s, 8s, 16s, ... up to max 16 minutes (matches Android)
            let exponentialDelay = 2 * Int(pow(2.0, Double(reconnectAttempts)))
            delaySeconds = min(exponentialDelay, maxReconnectDelaySeconds)
        }

        print("[MumbleService] Scheduling reconnect in \(delaySeconds)s (attempt \(reconnectAttempts + 1))")

        // Set next reconnect time and start countdown
        nextReconnectTime = Date().addingTimeInterval(Double(delaySeconds))
        startCountdown()

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.attemptReconnect()
        }
    }

    /// Start countdown timer for UI feedback
    private func startCountdown() {
        stopCountdown()

        countdownTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self, let nextTime = self.nextReconnectTime else { break }

                let remaining = Int(nextTime.timeIntervalSinceNow)
                await MainActor.run {
                    self.reconnectCountdown = max(0, remaining)
                }

                if remaining <= 0 { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second
            }
        }
    }

    /// Stop countdown timer
    private func stopCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        // Update on main thread synchronously to avoid weak reference issues during deallocation
        if Thread.isMainThread {
            reconnectCountdown = 0
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.reconnectCountdown = 0
            }
        }
    }

    /// Cancel any pending reconnection attempt
    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        ghostReconnectTask?.cancel()
        ghostReconnectTask = nil
        stopCountdown()
    }

    /// Attempt to reconnect using stored credentials
    private func attemptReconnect() async {
        if userDisconnected {
            print("[MumbleService] attemptReconnect: user disconnected, aborting")
            return
        }

        if !hasNetwork {
            print("[MumbleService] attemptReconnect: no network, waiting...")
            return
        }

        guard lastCredentials != nil else {
            print("[MumbleService] attemptReconnect: no credentials stored")
            return
        }

        if connectionState == .synchronized || connectionState == .connecting {
            print("[MumbleService] attemptReconnect: already connected/connecting")
            await MainActor.run {
                self.reconnectAttempts = 0
            }
            return
        }

        await MainActor.run {
            self.reconnectAttempts += 1
        }
        print("[MumbleService] Attempting reconnect (attempt \(reconnectAttempts))")

        // Perform reconnection
        await connectWithStoredCredentials()

        // If still not connected, schedule next attempt
        if connectionState != .synchronized && connectionState != .connecting {
            scheduleReconnect()
        }
    }

    /// Called when connection is established successfully. Resets reconnect counter.
    private func onConnectionSuccess() {
        print("[MumbleService] === onConnectionSuccess() ===")
        print("[MumbleService] tenantSubdomain=\(tenantSubdomain ?? "nil")")
        print("[MumbleService] credentials=\(credentials != nil ? "SET (hash=\(credentials!.certificateHash.prefix(8))...)" : "nil")")

        reconnectAttempts = 0
        cancelReconnect()
        wasKicked = false
        ghostKickMessage = nil

        // Start hourly settings refresh
        startHourlySettingsRefresh()

        // Fetch settings, sync alarms, and resume position tracking
        Task { @MainActor in
            print("[MumbleService] Starting initial sync task...")
            await refreshAlarmSettings()
            print("[MumbleService] Settings refreshed, now syncing alarms...")
            await syncAlarms()
            print("[MumbleService] Initial sync complete")

            // Resume position tracking for own alarms after reconnect
            resumePositionTrackingForOwnAlarms()

            // Retry pending dispatcher cancel if any
            await retryPendingDispatcherCancel()
        }

        // Start periodic alarm sync (every 20 seconds)
        startAlarmSyncTimer()

        // Start SSE for real-time channel permission updates
        startChannelUpdatesSSE()

        // Start SSE for real-time alarm updates
        startAlarmUpdatesSSE()

        print("[MumbleService] === onConnectionSuccess() done ===")
    }

    /// Synchronize alarms with backend (like Android).
    /// - Fetches open alarms from backend API
    /// - Closes local alarms that are not open on backend
    /// - Updates local alarms with backend data
    private func syncAlarms() async {
        print("[MumbleService] syncAlarms() called - tenantSubdomain=\(tenantSubdomain ?? "nil"), credentials=\(credentials != nil ? "SET" : "nil")")

        guard let subdomain = tenantSubdomain,
              let certificateHash = credentials?.certificateHash else {
            print("[MumbleService] Cannot sync alarms: missing credentials (subdomain=\(tenantSubdomain ?? "nil"), credentials=\(credentials != nil ? "SET" : "nil"))")
            return
        }

        print("[MumbleService] Syncing alarms with backend (subdomain=\(subdomain))...")

        do {
            let response = try await apiClient.getOpenAlarms(
                subdomain: subdomain,
                certificateHash: certificateHash
            )

            // Backend alarm IDs (these are backend IDs, not local UUIDs)
            let backendAlarmIds = Set(response.alarms.map { $0.id })
            print("[MumbleService] Backend has \(response.alarms.count) open alarms: \(backendAlarmIds)")

            // Log voice message and location info for each backend alarm
            for backendAlarm in response.alarms {
                print("[MumbleService] Backend alarm \(backendAlarm.id): lat=\(backendAlarm.latitude ?? 0), lon=\(backendAlarm.longitude ?? 0), voiceMessage=\(backendAlarm.voiceMessage != nil ? "EXISTS" : "nil")")
            }

            await MainActor.run {
                // Initialize repository if not yet ready (race condition fix)
                if alarmRepository == nil {
                    alarmRepository = AlarmRepository.shared()
                    print("[MumbleService] AlarmRepository initialized during sync")
                }

                guard let repository = alarmRepository else {
                    print("[MumbleService] ERROR: AlarmRepository still nil after init!")
                    return
                }

                // Get local open alarms
                let localAlarms = repository.getOpenAlarms()
                print("[MumbleService] Sync: Local has \(localAlarms.count) open alarms, backend has \(response.alarms.count)")

                // Track which backend alarms have been matched (to prevent multiple matches)
                var matchedBackendIds = Set<String>()

                for localAlarm in localAlarms {
                    var shouldKeep = false
                    var matchedId: String? = nil
                    var reason = ""

                    // PROTECTION: Never delete our own active alarm (the one we triggered and is still active)
                    let isOwnActiveAlarm = localAlarm.alarmId == currentAlarmId
                    if isOwnActiveAlarm {
                        shouldKeep = true
                        reason = "OWN ACTIVE ALARM"
                        print("[MumbleService] Sync: PROTECTING own active alarm \(localAlarm.alarmId)")
                    }

                    // First try: match by backendAlarmId (also for own active alarm to get backend data)
                    if let backendId = localAlarm.backendAlarmId, backendAlarmIds.contains(backendId) {
                        if !matchedBackendIds.contains(backendId) {
                            shouldKeep = true
                            matchedId = backendId
                            if !isOwnActiveAlarm {
                                reason = "backendAlarmId match"
                            }
                            matchedBackendIds.insert(backendId)
                        }
                    }

                    // Second try (if no backendAlarmId or own active alarm without match): match by username + channel + time
                    // But only match ONE local alarm per backend alarm
                    // Also try for own active alarms without a backend match yet, to get backend data
                    if matchedId == nil && localAlarm.backendAlarmId == nil {
                        for backend in response.alarms where !matchedBackendIds.contains(backend.id) {
                            let usernameMatch = backend.alarmStartUserName == localAlarm.triggeredByUsername
                            let channelMatch = backend.channelName == localAlarm.channelName
                            let localTimeMs = Int64(localAlarm.receivedAt.timeIntervalSince1970 * 1000)
                            let timeMatch = backend.triggeredAt != nil && abs(backend.triggeredAt! - localTimeMs) < 60000

                            if usernameMatch && channelMatch && timeMatch {
                                if !isOwnActiveAlarm {
                                    shouldKeep = true
                                    reason = "fallback match"
                                }
                                matchedId = backend.id
                                matchedBackendIds.insert(backend.id)
                                // Update local alarm with backend ID for future syncs
                                repository.updateBackendAlarmId(alarmId: localAlarm.alarmId, backendAlarmId: backend.id)
                                break
                            }
                        }
                    }

                    if shouldKeep {
                        print("[MumbleService] Sync: KEEPING alarm \(localAlarm.alarmId) (\(reason), backendId=\(matchedId ?? "none"))")

                        // UPDATE existing alarm with backend data (like Android's syncWithBackend)
                        if let matchedBackendId = matchedId,
                           let backendAlarm = response.alarms.first(where: { $0.id == matchedBackendId }) {

                            // Use backend's position_updated_at timestamp (or current time as fallback)
                            let backendLocationTimestamp: Date?
                            if let posUpdatedAt = backendAlarm.positionUpdatedAt {
                                backendLocationTimestamp = Date(timeIntervalSince1970: Double(posUpdatedAt) / 1000)
                            } else if backendAlarm.latitude != nil {
                                backendLocationTimestamp = Date()
                            } else {
                                backendLocationTimestamp = nil
                            }

                            // Check if update is needed
                            let backendHasVoice = backendAlarm.hasVoiceMessage
                            let needsUpdate = localAlarm.latitude != backendAlarm.latitude ||
                                              localAlarm.longitude != backendAlarm.longitude ||
                                              localAlarm.hasRemoteVoiceMessage != backendHasVoice ||
                                              localAlarm.voiceMessageText != backendAlarm.voiceMessageText

                            print("[MumbleService] Sync: Alarm \(localAlarm.alarmId) - local hasRemoteVoiceMessage=\(localAlarm.hasRemoteVoiceMessage), backend has_voice_message=\(backendHasVoice), voiceText=\(backendAlarm.voiceMessageText != nil ? "SET" : "nil")")

                            if needsUpdate {
                                print("[MumbleService] Sync: UPDATING alarm \(localAlarm.alarmId) with backend data (hasVoice=\(backendHasVoice))")
                                print("[MumbleService] Sync: BEFORE update - localAlarm.lat=\(localAlarm.latitude ?? -999), lon=\(localAlarm.longitude ?? -999)")
                                print("[MumbleService] Sync: Backend data - lat=\(backendAlarm.latitude ?? -999), lon=\(backendAlarm.longitude ?? -999)")
                                repository.updateFromBackend(
                                    alarmId: localAlarm.alarmId,
                                    latitude: backendAlarm.latitude,
                                    longitude: backendAlarm.longitude,
                                    locationType: backendAlarm.locationType,
                                    locationUpdatedAt: backendLocationTimestamp,
                                    hasRemoteVoiceMessage: backendHasVoice,
                                    voiceMessageText: backendAlarm.voiceMessageText
                                )
                                print("[MumbleService] Sync: AFTER update - localAlarm.lat=\(localAlarm.latitude ?? -999), lon=\(localAlarm.longitude ?? -999)")
                            } else if backendLocationTimestamp != nil {
                                // Always update locationUpdatedAt from backend (even if position unchanged)
                                repository.updateLocationTimestamp(alarmId: localAlarm.alarmId, timestamp: backendLocationTimestamp!)
                            }
                        }
                    } else {
                        print("[MumbleService] Sync: DELETING alarm \(localAlarm.alarmId) (no match on backend)")
                        repository.closeAlarm(alarmId: localAlarm.alarmId)
                    }
                }

                // ADD NEW ALARMS FROM BACKEND (like Android's syncWithBackend)
                // Find backend alarms that weren't matched to any local alarm
                for backendAlarm in response.alarms {
                    // Skip if already matched
                    if matchedBackendIds.contains(backendAlarm.id) {
                        continue
                    }

                    // Check if this backend alarm already exists locally by backendAlarmId
                    if repository.getAlarm(byBackendId: backendAlarm.id) != nil {
                        print("[MumbleService] Sync: Backend alarm \(backendAlarm.id) already exists locally")
                        continue
                    }

                    // Create new local alarm from backend data (like Android)
                    print("[MumbleService] Sync: ADDING new alarm from backend: \(backendAlarm.id)")
                    print("[MumbleService] Sync:   Backend location: lat=\(backendAlarm.latitude ?? -999), lon=\(backendAlarm.longitude ?? -999), type=\(backendAlarm.locationType ?? "nil")")
                    let now = Date()
                    let receivedAt: Date
                    if let triggeredAtMs = backendAlarm.triggeredAt {
                        receivedAt = Date(timeIntervalSince1970: Double(triggeredAtMs) / 1000)
                    } else {
                        receivedAt = now
                    }

                    // Use backend's position_updated_at timestamp (or current time as fallback)
                    let locationUpdatedAt: Date?
                    if let posUpdatedAt = backendAlarm.positionUpdatedAt {
                        locationUpdatedAt = Date(timeIntervalSince1970: Double(posUpdatedAt) / 1000)
                    } else if backendAlarm.latitude != nil && backendAlarm.longitude != nil {
                        locationUpdatedAt = now
                    } else {
                        locationUpdatedAt = nil
                    }

                    let newAlarm = AlarmEntity(
                        alarmId: backendAlarm.id,  // Use backend ID as local ID (like Android)
                        backendAlarmId: backendAlarm.id,
                        receivedAt: receivedAt,
                        triggeredByUsername: backendAlarm.alarmStartUserName ?? "",
                        triggeredByDisplayName: backendAlarm.alarmStartUserDisplayname,
                        triggeredByUserId: 0,  // Not available from backend
                        channelId: UInt32(backendAlarm.channelId ?? 0),
                        channelName: backendAlarm.channelName ?? "Kein Kanal",
                        latitude: backendAlarm.latitude,
                        longitude: backendAlarm.longitude,
                        locationType: backendAlarm.locationType,
                        locationUpdatedAt: locationUpdatedAt,
                        hasRemoteVoiceMessage: backendAlarm.hasVoiceMessage,
                        voiceMessageText: backendAlarm.voiceMessageText
                    )
                    repository.insertAlarm(newAlarm)
                    print("[MumbleService] Sync:   Inserted alarm with lat=\(newAlarm.latitude ?? -999), lon=\(newAlarm.longitude ?? -999)")
                }

                // Refresh open alarms list
                self.objectWillChange.send()
                openAlarms = repository.getOpenAlarms()
                print("[MumbleService] Sync complete: \(openAlarms.count) open alarms remaining")

                // Debug: Log location for each alarm after sync
                for alarm in openAlarms {
                    print("[MumbleService] Sync:   Final alarm \(alarm.alarmId): lat=\(alarm.latitude ?? -999), lon=\(alarm.longitude ?? -999), hasLocation=\(alarm.hasLocation)")
                }

                // Log final state of each alarm after sync
                for alarm in openAlarms {
                    print("[MumbleService] After SYNC: alarm \(alarm.alarmId) hasVoiceMessage=\(alarm.hasVoiceMessage), hasRemoteVoiceMessage=\(alarm.hasRemoteVoiceMessage), backendAlarmId=\(alarm.backendAlarmId ?? "nil")")
                }

                // Stop alarm sound if no more open alarms
                if openAlarms.isEmpty {
                    AlarmSoundPlayer.shared.stopAlarm()
                }
            }
        } catch {
            print("[MumbleService] Alarm sync failed: \(error)")
            // Non-fatal - keep existing local alarms
        }
    }

    /// Called when connection is lost (not by user choice). Triggers auto-reconnect if conditions are met.
    private func onConnectionLost(reason: String) {
        print("[MumbleService] === CONNECTION LOST ===")
        print("[MumbleService]   reason: \(reason)")
        logReconnectState("onConnectionLost entry")

        // Stop SSE connections (will be restarted on reconnect)
        stopChannelUpdatesSSE()
        stopAlarmUpdatesSSE()

        if userDisconnected {
            print("[MumbleService] User disconnected - not auto-reconnecting")
            return
        }

        let reasonLower = reason.lowercased()

        // Check if rejected due to invalid credentials (user deactivated, certificate revoked)
        let isInvalidCredentials = reasonLower.contains("invalid server password") ||
                                   reasonLower.contains("wrong certificate") ||
                                   reasonLower.contains("invalid certificate")

        if isInvalidCredentials {
            print("[MumbleService] Connection rejected due to invalid credentials - NOT reconnecting")
            userDisconnected = true  // Prevent auto-reconnect
            cancelReconnect()
            lastCredentials = nil
            return
        }

        // Check if kicked because another client connected with same credentials (ghost disconnect)
        // UserRemove reason from Mumble server may contain "kicked" or the actual reason text
        let isGhostDisconnect = reasonLower.contains("ghost") ||
                               reasonLower.contains("another") ||
                               reasonLower.contains("duplicate") ||
                               reasonLower.contains("kicked")

        if isGhostDisconnect {
            print("[MumbleService] Kicked (ghost/duplicate session) - NOT auto-reconnecting to prevent ping-pong")
            wasKicked = true
            userDisconnected = true  // Prevent auto-reconnect
            cancelReconnect()
            ghostKickMessage = "Sie wurden getrennt, da sich ein anderes Gerät mit Ihrem Konto angemeldet hat."
            return
        }

        // Normal disconnect - reset wasKicked and reconnect immediately
        if wasKicked {
            print("[MumbleService] Normal disconnect while wasKicked=true - resetting and reconnecting")
            wasKicked = false
            cancelReconnect()
        }

        if hasNetwork && lastCredentials != nil {
            print("[MumbleService] Will attempt auto-reconnect")
            scheduleReconnect()
        } else {
            print("[MumbleService] Cannot reconnect: hasNetwork=\(hasNetwork), hasCredentials=\(lastCredentials != nil)")
        }
    }

    /// Log full reconnect state for debugging
    private func logReconnectState(_ context: String) {
        print("[MumbleService] === RECONNECT STATE (\(context)) ===")
        print("[MumbleService]   connectionState=\(connectionState)")
        print("[MumbleService]   userDisconnected=\(userDisconnected)")
        print("[MumbleService]   wasKicked=\(wasKicked)")
        print("[MumbleService]   hasNetwork=\(hasNetwork)")
        print("[MumbleService]   lastCredentials=\(lastCredentials != nil ? "SET" : "NULL")")
        print("[MumbleService]   reconnectAttempts=\(reconnectAttempts)")
        print("[MumbleService]   reconnectCountdown=\(reconnectCountdown)")
        print("[MumbleService] ================================")
    }

    // MARK: - Token Management

    private func getValidAccessToken() async throws -> String {
        // Check if we have a valid token
        if let token = keycloakService.accessToken,
           let expiry = keycloakService.tokenExpiry,
           expiry > Date() {
            return token
        }

        // Try to refresh the token
        let refreshed = try await keycloakService.tryAutoLogin()
        if refreshed, let token = keycloakService.accessToken {
            return token
        }

        throw AuthError.tokenExpired
    }

    // MARK: - Connection

    func connectWithStoredCredentials() async {
        print("[MumbleService] connectWithStoredCredentials() called, state: \(connectionState)")

        // Don't reconnect if already connected or connecting
        guard connectionState == .disconnected || connectionState == .failed else {
            print("[MumbleService] Already connected or connecting (\(connectionState)), skipping connectWithStoredCredentials")
            return
        }

        // Clear any cached data from previous session before connecting
        clearCache()

        guard let subdomain = UserDefaults.standard.string(forKey: "subdomain") else {
            print("[MumbleService] No subdomain stored!")
            await MainActor.run {
                errorMessage = "Keine Anmeldedaten vorhanden"
                connectionState = .failed
            }
            return
        }
        print("[MumbleService] Subdomain: \(subdomain)")

        // Store subdomain for tenant filtering
        self._tenantSubdomain = subdomain

        await MainActor.run {
            connectionState = .connecting
            errorMessage = nil
        }

        // STEP 1: Try to use cached credentials (like Android's CertificateStore)
        // This allows offline operation without Keycloak
        if let cachedCreds = CredentialsStore.shared.getStoredCredentials() {
            print("[MumbleService] Found cached credentials:")
            print("[MumbleService]   - username: \(cachedCreds.username)")
            print("[MumbleService]   - server: \(cachedCreds.serverHost):\(cachedCreds.serverPort)")
            print("[MumbleService]   - expires: \(cachedCreds.expiresAt)")
            print("[MumbleService]   - certHash: \(cachedCreds.certificateHash.prefix(16))...")
            print("[MumbleService]   - certP12 length: \(cachedCreds.certificateP12Base64.count) chars")

            if CredentialsStore.shared.hasValidCredentials() {
                print("[MumbleService] Credentials valid - connecting with cached credentials")
                await connectWithCredentials(cachedCreds)
                return
            } else {
                print("[MumbleService] Cached credentials expired, will fetch new ones")
            }
        } else {
            print("[MumbleService] No cached credentials found in Keychain")
        }

        // STEP 2: No valid cached credentials - fetch new ones from API
        // Try to get valid access token (refresh if needed)
        let accessToken: String
        do {
            print("[MumbleService] Getting access token...")
            accessToken = try await getValidAccessToken()
            print("[MumbleService] Got access token (length: \(accessToken.count))")
        } catch {
            print("[MumbleService] Token error: \(error)")

            // Fallback: Try cached credentials even if expired (offline mode)
            if let cachedCreds = CredentialsStore.shared.getStoredCredentials() {
                print("[MumbleService] No token available, trying cached credentials as fallback")
                await connectWithCredentials(cachedCreds)
                return
            }

            await MainActor.run {
                errorMessage = "Anmeldung fehlgeschlagen. Bitte später erneut versuchen."
                connectionState = .failed
            }
            return
        }

        do {
            // Fetch Mumble credentials from tenant API
            _credentials = try await apiClient.fetchMumbleCredentials(
                subdomain: subdomain,
                accessToken: accessToken
            )

            guard let creds = _credentials else {
                throw APIError.invalidResponse
            }

            print("[MumbleService] Got credentials for \(creds.serverHost):\(creds.serverPort)")
            print("[MumbleService] Username: \(creds.username)")
            print("[MumbleService] Display name: \(creds.displayName)")
            print("[MumbleService] Tenant subdomain: \(subdomain)")

            // Set current user profile and permissions from credentials
            await MainActor.run {
                self.currentUserProfile = UserProfile(
                    username: creds.username,
                    firstName: creds.firstName,
                    lastName: creds.lastName
                )

                // Extract permissions from credentials
                self.userPermissions = UserPermissions(
                    canReceiveAlarm: creds.canReceiveAlarm ?? false,
                    canTriggerAlarm: creds.canTriggerAlarm ?? false,
                    canEndAlarm: creds.canEndAlarm ?? false,
                    canManageAudiocast: creds.canManageAudiocast ?? false,
                    canPlayAudiocast: creds.canPlayAudiocast ?? false,
                    canCallDispatcher: creds.canCallDispatcher ?? false,
                    canActAsDispatcher: creds.canActAsDispatcher ?? false
                )
            }

            // Store tenant channel ID for filtering and auto-join
            if let channelId = creds.tenantChannelId {
                self.tenantChannelId = UInt32(channelId)
                print("[MumbleService] Tenant channel ID: \(channelId)")
            }

            // Store credentials for auto-reconnect (in memory)
            lastCredentials = creds
            userDisconnected = false
            wasKicked = false

            // Persist credentials for offline/auto-login (like Android's CertificateStore)
            CredentialsStore.shared.saveCredentials(creds)

            // Connect to Mumble server
            mumbleConnection.connect(
                host: creds.serverHost,
                port: creds.serverPort,
                username: creds.username,
                certificateP12Base64: creds.certificateP12Base64,
                certificatePassword: creds.certificatePassword
            )

        } catch let error as APIError {
            print("[MumbleService] API error: \(error)")

            // Handle specific HTTP errors (matches Android behavior)
            if case .httpError(let statusCode) = error {
                if statusCode == 401 {
                    // Token expired - try to refresh and retry once
                    print("[MumbleService] HTTP 401 - attempting token refresh...")
                    do {
                        let refreshed = try await keycloakService.tryAutoLogin()
                        if refreshed {
                            print("[MumbleService] Token refreshed - retrying connection...")
                            // Retry with new token (recursive call, but only once due to fresh token)
                            await connectWithStoredCredentials()
                            return
                        }
                    } catch {
                        print("[MumbleService] Token refresh failed: \(error)")
                    }
                    // Refresh failed - need re-login
                    await MainActor.run {
                        errorMessage = "Sitzung abgelaufen - bitte neu anmelden"
                        connectionState = .failed
                    }
                    // Signal that re-login is needed (clear credentials to prevent auto-reconnect)
                    lastCredentials = nil
                    userDisconnected = true
                    return
                } else if statusCode == 403 {
                    // Not authorized - need re-login
                    print("[MumbleService] HTTP 403 - not authorized, re-login required")
                    await MainActor.run {
                        errorMessage = "Nicht autorisiert - bitte neu anmelden"
                        connectionState = .failed
                    }
                    // Signal that re-login is needed
                    lastCredentials = nil
                    userDisconnected = true
                    return
                }
            }

            await MainActor.run {
                errorMessage = error.errorDescription ?? "Unbekannter API-Fehler"
                connectionState = .failed
            }
        } catch {
            print("[MumbleService] Failed to get credentials: \(error)")
            await MainActor.run {
                errorMessage = "Verbindung zum Server fehlgeschlagen: \(error.localizedDescription)"
                connectionState = .failed
            }
        }
    }

    /// Helper to connect with given credentials (used for both fresh and cached credentials)
    private func connectWithCredentials(_ creds: MumbleCredentials) async {
        print("[MumbleService] connectWithCredentials: \(creds.serverHost):\(creds.serverPort)")
        print("[MumbleService] Username: \(creds.username)")
        print("[MumbleService] Display name: \(creds.displayName)")

        // Set current user profile and permissions from credentials
        await MainActor.run {
            self.currentUserProfile = UserProfile(
                username: creds.username,
                firstName: creds.firstName,
                lastName: creds.lastName
            )

            // Extract permissions from credentials
            self.userPermissions = UserPermissions(
                canReceiveAlarm: creds.canReceiveAlarm ?? false,
                canTriggerAlarm: creds.canTriggerAlarm ?? false,
                canEndAlarm: creds.canEndAlarm ?? false,
                canManageAudiocast: creds.canManageAudiocast ?? false,
                canPlayAudiocast: creds.canPlayAudiocast ?? false,
                canCallDispatcher: creds.canCallDispatcher ?? false,
                canActAsDispatcher: creds.canActAsDispatcher ?? false
            )
        }

        // Store tenant channel ID for filtering and auto-join
        if let channelId = creds.tenantChannelId {
            self.tenantChannelId = UInt32(channelId)
            print("[MumbleService] Tenant channel ID: \(channelId)")
        }

        // Store credentials for auto-reconnect (in memory)
        lastCredentials = creds
        _credentials = creds
        userDisconnected = false
        wasKicked = false

        // Connect to Mumble server
        mumbleConnection.connect(
            host: creds.serverHost,
            port: creds.serverPort,
            username: creds.username,
            certificateP12Base64: creds.certificateP12Base64,
            certificatePassword: creds.certificatePassword
        )
    }

    /// Update current user profile with metadata from profile API
    func updateCurrentUserProfile(firstName: String?, lastName: String?, jobFunction: String?) {
        guard var profile = currentUserProfile else { return }
        profile.firstName = firstName
        profile.lastName = lastName
        profile.jobFunction = jobFunction
        currentUserProfile = profile
    }

    func connect(host: String, port: Int, username: String, password: String, certificatePath: String? = nil) {
        print("[MumbleService] Direct connect not supported - use connectWithStoredCredentials()")
    }

    /// Disconnect from server (user-initiated). Will NOT auto-reconnect.
    func disconnect() {
        print("[MumbleService] Disconnecting (user-initiated)")
        userDisconnected = true  // Prevent auto-reconnect
        cancelReconnect()
        stopHourlySettingsRefresh()
        stopAlarmSyncTimer()
        stopChannelUpdatesSSE()
        stopAlarmUpdatesSSE()
        stopTransmitting()
        stopAudioPlayback()
        mumbleConnection.disconnect()
        clearCache()
    }

    /// Clear all cached data (channels, users, etc.)
    /// Called on disconnect to ensure fresh data on next login
    private func clearCache() {
        print("[MumbleService] Clearing cached data")
        DispatchQueue.main.async {
            self.channels = []
            self.users = []
            self.openAlarms = []
            self.currentAlarmId = nil
            self.alarmBackendId = nil
            self.tenantChannelId = 0
            self.localUserChannelId = 0
        }
    }

    /// Disconnect for manual reconnect via UI. Does NOT set userDisconnected - allows auto-reconnect.
    @MainActor
    func disconnectForReconnect() {
        print("[MumbleService] Disconnecting for reconnect (manual)")
        cancelReconnect()
        reconnectAttempts = 0  // Reset counter for fresh start
        stopTransmitting()
        stopAudioPlayback()

        // Set state BEFORE disconnect to avoid race condition
        // The delegate callback uses DispatchQueue.main.async which may not execute immediately
        connectionState = .disconnected

        mumbleConnection.disconnect()
    }

    @MainActor
    func reconnect() async {
        print("[MumbleService] reconnect() called, current state: \(connectionState)")

        // Reset ghost kick state so manual reconnect is allowed
        userDisconnected = false
        wasKicked = false
        ghostKickMessage = nil

        // Ensure we're disconnected first
        if connectionState != .disconnected && connectionState != .failed {
            print("[MumbleService] reconnect: disconnecting first...")
            disconnectForReconnect()
            // Wait for disconnect to complete
            try? await Task.sleep(nanoseconds: 500_000_000)
            print("[MumbleService] reconnect: after sleep, state: \(connectionState)")
        }

        print("[MumbleService] reconnect: calling connectWithStoredCredentials...")
        await connectWithStoredCredentials()
        print("[MumbleService] reconnect: connectWithStoredCredentials returned, state: \(connectionState)")
    }

    // MARK: - Channel Operations

    func joinChannel(_ channelId: UInt32) {
        print("[MumbleService] Joining channel \(channelId)")
        mumbleConnection.joinChannel(channelId)
    }

    /// Leave current channel and return to tenant channel
    func leaveChannel() {
        print("[MumbleService] Leaving channel - joining tenant channel \(tenantChannelId)")
        joinChannel(tenantChannelId)
    }

    /// Get channel by ID
    func getChannel(_ channelId: UInt32) -> Channel? {
        return channels.first { $0.id == channelId }
    }

    func getChannelUsers(_ channelId: UInt32) -> [User] {
        return users.filter { $0.channelId == channelId }
    }

    func getChannelsForDisplay() -> [Channel] {
        return channels
    }

    // MARK: - Audio

    func startTransmitting() {
        NSLog("[MumbleService] Start transmitting, connectionState=\(connectionState)")

        // Only reset sequence if not already transmitting
        if !audioService.isCapturing {
            audioSequenceNumber = 0
        }

        audioService.startCapture { [weak self] data, frames in
            guard let self = self else { return }
            self.encodeAndSendAudio(data: data, frames: frames)
        }
    }

    private func encodeAndSendAudio(data: UnsafePointer<Int16>, frames: Int) {
        guard let codec = opusCodec else {
            NSLog("[MumbleService] encodeAndSendAudio: No opus codec!")
            return
        }
        guard connectionState == .synchronized else {
            NSLog("[MumbleService] encodeAndSendAudio: Not synchronized (state=\(connectionState))")
            return
        }

        // Buffer samples and encode in 480-sample chunks (iOS may deliver 512, 1024, etc.)
        codec.addSamplesAndEncode(data, frameCount: Int32(frames)) { [weak self] opusData in
            guard let self = self else { return }

            // Send encoded packet to server
            // IMPORTANT: isTerminator must be true for single-frame packets!
            // This tells the server this is the last frame in the UDP packet.
            // Without this bit, the server waits for more frames and doesn't process the audio.
            self.mumbleConnection.sendAudioPacket(
                opusData: opusData,
                sequenceNumber: self.audioSequenceNumber,
                isTerminator: true
            )

            self.audioSequenceNumber += 1
        }
    }

    func stopTransmitting() {
        NSLog("[MumbleService] Stop transmitting")
        audioService.stopCapture()

        // Clear any buffered samples
        opusCodec?.clearBuffer()

        // Send terminator packet to indicate end of transmission
        if connectionState == .synchronized {
            mumbleConnection.sendAudioPacket(
                opusData: Data(),
                sequenceNumber: audioSequenceNumber,
                isTerminator: true
            )
        }
    }

    func setSelfMute(_ mute: Bool) {
        print("[MumbleService] Self mute: \(mute)")
        mumbleConnection.setSelfMute(mute)
    }

    func setSelfDeaf(_ deaf: Bool) {
        print("[MumbleService] Self deaf: \(deaf)")
        mumbleConnection.setSelfDeaf(deaf)
    }

    // MARK: - Alarm

    /// Start GPS warm-up when user begins holding the alarm button (Phase 1)
    func startAlarmWarmUp() {
        print("[MumbleService] Starting alarm warm-up (GPS + location permission)")
        locationService.warmUp()

        // Request location permission if needed
        if !locationService.isLocationAvailable {
            locationService.requestAuthorization()
        }
    }

    /// Start voice recording when hold duration is reached
    func startVoiceRecording() {
        print("[MumbleService] Starting voice recording for alarm")
        print("[MumbleService]   maxDuration: \(alarmSettings.alarmVoiceNoteDuration)s")
        voiceRecorder.maxDuration = TimeInterval(alarmSettings.alarmVoiceNoteDuration)
        currentVoiceFilePath = voiceRecorder.startRecording()

        // Set isRecordingVoice synchronously based on whether recording started successfully
        let recordingStarted = currentVoiceFilePath != nil
        print("[MumbleService]   voiceFilePath: \(currentVoiceFilePath?.lastPathComponent ?? "nil")")
        print("[MumbleService]   voiceRecorder.isRecording: \(voiceRecorder.isRecording)")
        print("[MumbleService]   recordingStarted: \(recordingStarted)")

        // Update on main thread but set the value we know is correct
        DispatchQueue.main.async {
            self.isRecordingVoice = recordingStarted && self.voiceRecorder.isRecording
            print("[MumbleService]   isRecordingVoice set to: \(self.isRecordingVoice)")
        }
    }

    /// Stop voice recording
    func stopVoiceRecording() -> URL? {
        let path = voiceRecorder.stopRecording()
        DispatchQueue.main.async {
            self.isRecordingVoice = false
        }
        return path
    }

    /// Cancel voice recording and delete file
    func cancelVoiceRecording() {
        voiceRecorder.cancelRecording()
        currentVoiceFilePath = nil
        DispatchQueue.main.async {
            self.isRecordingVoice = false
        }
    }

    /// Cancel alarm warm-up (user released button before hold completed)
    func cancelAlarmWarmUp() {
        print("[MumbleService] Canceling alarm warm-up")
        locationService.stopWarmUp()
        cancelVoiceRecording()

        DispatchQueue.main.async {
            self.alarmTriggerState = .cancelled
            // Reset to idle after a short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.alarmTriggerState = .idle
            }
        }
    }

    /// Trigger the alarm (Phase 3) - called after countdown completes
    func triggerAlarm() async {
        guard userPermissions.canTriggerAlarm else {
            print("[MumbleService] User does not have permission to trigger alarm")
            await MainActor.run {
                alarmTriggerState = .failed(error: "Keine Berechtigung zum Auslösen von Alarmen")
            }
            return
        }

        guard !hasOwnOpenAlarm else {
            print("[MumbleService] User already has an open alarm - cannot trigger another")
            await MainActor.run {
                alarmTriggerState = .failed(error: "Sie haben bereits einen offenen Alarm")
            }
            return
        }

        guard connectionState == .synchronized else {
            print("[MumbleService] Cannot trigger alarm - not connected")
            await MainActor.run {
                alarmTriggerState = .failed(error: "Nicht verbunden")
            }
            return
        }

        await MainActor.run {
            alarmTriggerState = .triggering
        }

        // Stop voice recording
        let voicePath = stopVoiceRecording()
        currentVoiceFilePath = voicePath

        // Get current location
        let location = await locationService.getCurrentLocation()
        locationService.stopWarmUp()

        let alarmId = UUID().uuidString
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let channelId = localUserChannelId > 0 ? localUserChannelId : tenantChannelId
        let channelName = getChannel(channelId)?.name ?? "Kein Kanal"

        let latitude = location?.coordinate.latitude
        let longitude = location?.coordinate.longitude
        let locationType: String
        if let loc = location {
            locationType = locationService.getLocationType(for: loc).rawValue
        } else {
            locationType = LocationType.unknown.rawValue
        }

        print("[MumbleService] Triggering alarm: id=\(alarmId), channel=\(channelName), location=(\(latitude ?? 0), \(longitude ?? 0)) [\(locationType)]")

        // Create START_ALARM message
        let alarmMessage = StartAlarmMessage(
            id: alarmId,
            userId: localSession,
            userName: credentials?.username ?? "",
            displayName: currentUserProfile?.effectiveName ?? "",
            channelId: channelId,
            channelName: channelName,
            timestamp: timestamp,
            latitude: latitude,
            longitude: longitude,
            locationType: locationType
        )

        // 1. Send via Tree Message to tenant channel (real-time notification)
        if let jsonData = try? JSONEncoder().encode(alarmMessage),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            mumbleConnection.sendTreeMessage(tenantChannelId, message: jsonString)
            print("[MumbleService] Alarm sent via Tree Message")
        }

        // 1b. Store own alarm locally (so it appears in openAlarms)
        await MainActor.run {
            let alarm = alarmRepository?.insertAlarm(from: alarmMessage)
            if let alarm = alarm {
                openAlarms = alarmRepository?.getOpenAlarms() ?? []
                print("[MumbleService] Own alarm stored: \(alarm.alarmId), open alarms: \(openAlarms.count)")
            }
        }

        // 2. Send to backend API
        await sendAlarmToBackend(alarmMessage: alarmMessage, voicePath: voicePath)

        // Update state
        await MainActor.run {
            currentAlarmId = alarmId
            alarmTriggerState = .triggered(alarmId: alarmId)
        }

        // 3. Start position tracking if we have a location
        if location != nil {
            startPositionTracking(alarmId: alarmId)
        }

        // 4. If we only got network location, wait for GPS fix
        if locationType == LocationType.network.rawValue {
            await waitForGPSAndUpdate(alarmId: alarmId)
        }
    }

    /// Trigger the alarm but keep voice recording running (for post-alarm recording dialog)
    /// Called when user wants to continue recording after alarm is triggered
    func triggerAlarmWithoutStoppingRecording() async {
        guard userPermissions.canTriggerAlarm else {
            print("[MumbleService] User does not have permission to trigger alarm")
            await MainActor.run {
                alarmTriggerState = .failed(error: "Keine Berechtigung zum Auslösen von Alarmen")
            }
            return
        }

        guard !hasOwnOpenAlarm else {
            print("[MumbleService] User already has an open alarm - cannot trigger another")
            await MainActor.run {
                alarmTriggerState = .failed(error: "Sie haben bereits einen offenen Alarm")
            }
            return
        }

        guard connectionState == .synchronized else {
            print("[MumbleService] Cannot trigger alarm - not connected")
            await MainActor.run {
                alarmTriggerState = .failed(error: "Nicht verbunden")
            }
            return
        }

        await MainActor.run {
            alarmTriggerState = .triggering
        }

        // NOTE: Do NOT stop voice recording here - it continues for post-alarm dialog

        // Get current location
        let location = await locationService.getCurrentLocation()
        locationService.stopWarmUp()

        let alarmId = UUID().uuidString
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let channelId = localUserChannelId > 0 ? localUserChannelId : tenantChannelId
        let channelName = getChannel(channelId)?.name ?? "Kein Kanal"

        let latitude = location?.coordinate.latitude
        let longitude = location?.coordinate.longitude
        let locationType: String
        if let loc = location {
            locationType = locationService.getLocationType(for: loc).rawValue
        } else {
            locationType = LocationType.unknown.rawValue
        }

        print("[MumbleService] Triggering alarm (recording continues): id=\(alarmId), channel=\(channelName), location=(\(latitude ?? 0), \(longitude ?? 0)) [\(locationType)]")

        // Create START_ALARM message
        let alarmMessage = StartAlarmMessage(
            id: alarmId,
            userId: localSession,
            userName: credentials?.username ?? "",
            displayName: currentUserProfile?.effectiveName ?? "",
            channelId: channelId,
            channelName: channelName,
            timestamp: timestamp,
            latitude: latitude,
            longitude: longitude,
            locationType: locationType
        )

        // 1. Send via Tree Message to tenant channel (real-time notification)
        if let jsonData = try? JSONEncoder().encode(alarmMessage),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            mumbleConnection.sendTreeMessage(tenantChannelId, message: jsonString)
            print("[MumbleService] Alarm sent via Tree Message")
        }

        // 1b. Store own alarm locally (so it appears in openAlarms)
        await MainActor.run {
            let alarm = alarmRepository?.insertAlarm(from: alarmMessage)
            if let alarm = alarm {
                openAlarms = alarmRepository?.getOpenAlarms() ?? []
                print("[MumbleService] Own alarm stored: \(alarm.alarmId), open alarms: \(openAlarms.count)")
            }
        }

        // 2. Send to backend API (without voice message - that comes later)
        await sendAlarmToBackend(alarmMessage: alarmMessage, voicePath: nil)

        print("[MumbleService] After sendAlarmToBackend: alarmBackendId=\(alarmBackendId ?? "nil")")

        // Update state
        await MainActor.run {
            currentAlarmId = alarmId
            alarmTriggerState = .triggered(alarmId: alarmId)
        }

        // 3. Start position tracking if we have a location
        if location != nil {
            print("[MumbleService] Starting position tracking for alarm \(alarmId)")
            startPositionTracking(alarmId: alarmId)
        } else {
            print("[MumbleService] No location available, skipping position tracking")
        }

        // 4. If we only got network location, wait for GPS fix
        if locationType == LocationType.network.rawValue {
            await waitForGPSAndUpdate(alarmId: alarmId)
        }
    }

    /// Submit voice recording after post-alarm recording is complete
    /// Stops recording, uploads to backend, and notifies other clients
    /// Waits up to 30 seconds for backend alarm ID if not yet available (like Android)
    func submitVoiceRecording() async {
        print("[MumbleService] Submitting voice recording...")
        print("[MumbleService]   alarmBackendId=\(alarmBackendId ?? "nil")")
        print("[MumbleService]   currentAlarmId=\(currentAlarmId ?? "nil")")
        print("[MumbleService]   isRecordingVoice=\(isRecordingVoice)")
        print("[MumbleService]   currentVoiceFilePath=\(currentVoiceFilePath?.lastPathComponent ?? "nil")")

        // Stop recording and get the file path
        var voicePath = stopVoiceRecording()

        // Fallback: use stored path if stopVoiceRecording returned nil
        // (can happen if recording was auto-stopped due to max duration)
        if voicePath == nil, let storedPath = currentVoiceFilePath {
            print("[MumbleService] Using stored currentVoiceFilePath as fallback")
            voicePath = storedPath
        }

        guard let voicePath = voicePath else {
            print("[MumbleService] No voice recording to submit - no path available")
            return
        }

        print("[MumbleService] Voice file path: \(voicePath.path)")
        print("[MumbleService] Voice file exists: \(FileManager.default.fileExists(atPath: voicePath.path))")

        // Wait for backend alarm ID (like Android: max 30 seconds, polling every 1 second)
        let maxWaitSeconds = 30
        var waitedSeconds = 0

        while alarmBackendId == nil && waitedSeconds < maxWaitSeconds {
            print("[MumbleService] Waiting for backend alarm ID... (\(waitedSeconds + 1)/\(maxWaitSeconds)s)")
            try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second
            waitedSeconds += 1
        }

        // Check if we have a backend alarm ID to upload to
        guard let backendId = alarmBackendId else {
            print("[MumbleService] ERROR: No backend alarm ID after \(maxWaitSeconds)s - cannot upload voice message!")
            print("[MumbleService] Voice file saved at: \(voicePath.path)")
            // Keep the file path for potential manual retry
            currentVoiceFilePath = voicePath
            return
        }

        print("[MumbleService] Backend alarm ID available: \(backendId) (waited \(waitedSeconds)s)")
        print("[MumbleService] Uploading voice message to backend alarm: \(backendId)")

        // Upload the voice message
        await uploadVoiceMessage(alarmId: backendId, filePath: voicePath)

        // Clean up
        currentVoiceFilePath = nil
        print("[MumbleService] Voice recording submission complete")
    }

    /// Send alarm to backend API
    private func sendAlarmToBackend(alarmMessage: StartAlarmMessage, voicePath: URL?) async {
        guard let subdomain = tenantSubdomain,
              let certificateHash = credentials?.certificateHash else {
            print("[MumbleService] Missing subdomain or certificate hash for backend API")
            return
        }

        let request = AlarmRequest(
            channelId: alarmMessage.channelId,
            channelName: alarmMessage.channelName,
            alarmStartUserName: alarmMessage.userName,
            alarmStartUserDisplayname: alarmMessage.displayName,
            triggeredAt: alarmMessage.timestamp,
            latitude: alarmMessage.latitude,
            longitude: alarmMessage.longitude,
            locationType: alarmMessage.locationType
        )

        print("[MumbleService] Sending alarm to backend API...")

        do {
            let response = try await apiClient.triggerAlarm(
                subdomain: subdomain,
                certificateHash: certificateHash,
                request: request
            )

            print("[MumbleService] Backend response: success=\(response.success ?? false), alarmId=\(response.alarmId ?? "nil")")

            if let backendId = response.alarmId {
                print("[MumbleService] Backend alarm ID: \(backendId)")
                alarmBackendId = backendId

                // Save backend ID to local entity for sync matching
                await MainActor.run {
                    alarmRepository?.updateBackendAlarmId(alarmId: alarmMessage.id, backendAlarmId: backendId)
                }

                // Upload voice message if available
                if let voicePath = voicePath {
                    await uploadVoiceMessage(alarmId: backendId, filePath: voicePath)
                }
            } else {
                print("[MumbleService] WARNING: Backend did not return alarm ID!")
            }
        } catch {
            print("[MumbleService] Failed to send alarm to backend: \(error)")
            // Alarm was still sent via Tree Message, so it's not a complete failure
        }
    }

    /// Upload voice message to backend
    private func uploadVoiceMessage(alarmId: String, filePath: URL) async {
        guard let subdomain = tenantSubdomain,
              let certificateHash = credentials?.certificateHash else {
            print("[MumbleService] Cannot upload voice: missing subdomain or certificateHash")
            return
        }

        print("[MumbleService] Uploading voice message...")
        print("[MumbleService]   alarmId: \(alarmId)")
        print("[MumbleService]   filePath: \(filePath.path)")
        print("[MumbleService]   subdomain: \(subdomain)")

        do {
            try await apiClient.uploadVoiceMessage(
                subdomain: subdomain,
                certificateHash: certificateHash,
                alarmId: alarmId,
                filePath: filePath
            )
            print("[MumbleService] Voice message uploaded successfully!")

            // Send UPDATE_ALARM to notify others about voice message
            // Use currentAlarmId (local UUID) for the Tree Message, backendAlarmId for reference
            let localAlarmId = currentAlarmId ?? alarmId
            print("[MumbleService] Sending UPDATE_ALARM with hasVoiceMessage=true")
            print("[MumbleService]   localAlarmId (for Tree Message): \(localAlarmId)")
            print("[MumbleService]   backendAlarmId: \(alarmId)")
            sendUpdateAlarm(alarmId: localAlarmId, hasVoiceMessage: true, backendAlarmId: alarmId)

            // Also update local database to mark voice message available
            await MainActor.run {
                alarmRepository?.updateHasRemoteVoiceMessage(alarmId: localAlarmId, hasRemote: true)
                alarmRepository?.markVoiceMessageUploaded(alarmId: localAlarmId)
                // Refresh openAlarms to trigger UI update
                openAlarms = alarmRepository?.getOpenAlarms() ?? []
            }

        } catch {
            print("[MumbleService] Failed to upload voice message: \(error)")
        }
    }

    /// Download voice message for an alarm
    /// - Parameter backendAlarmId: The backend alarm ID
    /// - Returns: Local file path to the downloaded voice message, or nil if failed
    func downloadVoiceMessage(backendAlarmId: String) async -> URL? {
        guard let subdomain = tenantSubdomain,
              let certificateHash = credentials?.certificateHash else {
            print("[MumbleService] Cannot download voice: missing credentials")
            return nil
        }

        do {
            let filePath = try await apiClient.downloadVoiceMessage(
                subdomain: subdomain,
                certificateHash: certificateHash,
                alarmId: backendAlarmId
            )
            print("[MumbleService] Voice message downloaded: \(filePath.lastPathComponent)")
            return filePath
        } catch {
            print("[MumbleService] Failed to download voice message: \(error)")
            return nil
        }
    }

    /// Start continuous position tracking for alarm using PositionTracker
    private func startPositionTracking(alarmId: String, backendAlarmId: String? = nil) {
        // Don't start if already tracking this same alarm
        if positionTrackingAlarmId == alarmId && positionTracker.state != .idle {
            print("[MumbleService] Already tracking position for alarm \(alarmId)")
            return
        }

        // If tracking a different alarm, stop it first
        if positionTrackingAlarmId != alarmId && positionTracker.state != .idle {
            print("[MumbleService] Stopping tracking for previous alarm \(positionTrackingAlarmId ?? "nil") to start tracking \(alarmId)")
            positionTracker.endBoost()
        }

        let resolvedBackendId = backendAlarmId ?? alarmBackendId
        print("[MumbleService] startPositionTracking called")
        print("[MumbleService]   alarmId: \(alarmId)")
        print("[MumbleService]   backendAlarmId param: \(backendAlarmId ?? "nil")")
        print("[MumbleService]   alarmBackendId: \(self.alarmBackendId ?? "nil")")
        print("[MumbleService]   resolvedBackendId: \(resolvedBackendId ?? "nil")")

        guard let subdomain = tenantSubdomain,
              let certificateHash = credentials?.certificateHash,
              let backendId = resolvedBackendId else {
            print("[MumbleService] Cannot start position tracking: missing credentials or backendId")
            return
        }

        positionTrackingAlarmId = alarmId
        positionTrackingBackendId = backendId

        // Use PositionTracker with boost mode for high-frequency tracking
        // Session ID format: "alarm_{backendId}" for unified GPS endpoint
        let alarmInterval = alarmSettings.alarmGpsInterval
        positionTracker.boost(
            sessionId: "alarm_\(backendId)",
            frequencySeconds: alarmInterval,
            subdomain: subdomain,
            certificateHash: certificateHash
        ) { [weak self] location, _ in
            guard let self = self else { return }

            let locationType = self.locationService.getLocationType(for: location)

            // Send UPDATE_ALARM via Tree Message (for real-time updates to other clients)
            self.sendUpdateAlarm(
                alarmId: alarmId,
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                locationType: locationType.rawValue
            )

            // Update local database immediately (like Android does)
            Task { @MainActor in
                self.alarmRepository?.updateLocation(
                    alarmId: alarmId,
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    locationType: locationType.rawValue
                )
                // Refresh openAlarms to trigger UI update
                self.openAlarms = self.alarmRepository?.getOpenAlarms() ?? []
            }
            // Note: Backend upload is handled by PositionTracker automatically
        }
    }

    /// Stop position tracking
    func stopPositionTracking() {
        NSLog("[MumbleService] Stopping position tracking - alarmId=%@", positionTrackingAlarmId ?? "nil")
        print("[MumbleService] Stopping position tracking")
        positionTracker.endBoost()
        positionTrackingAlarmId = nil
        positionTrackingBackendId = nil
    }

    /// Resume position tracking for own alarms after reconnect
    /// Called when connection is restored to continue tracking if we have an active alarm
    @MainActor
    private func resumePositionTrackingForOwnAlarms() {
        guard let username = credentials?.username else {
            print("[MumbleService] Cannot resume position tracking: no username")
            return
        }

        // Already tracking? Don't start again
        if positionTracker.state != .idle {
            print("[MumbleService] Position tracking already active")
            return
        }

        // Get open alarms from repository
        guard let repository = alarmRepository else {
            print("[MumbleService] Cannot resume position tracking: no repository")
            return
        }

        let alarms = repository.getOpenAlarms()
        print("[MumbleService] Checking for own open alarms to resume tracking (openAlarms=\(alarms.count))")

        // Find our own alarm - try exact match first, then case-insensitive
        var ownAlarm = alarms.first(where: { $0.triggeredByUsername == username })
        if ownAlarm == nil {
            // Fallback: case-insensitive match (backend might return different case)
            ownAlarm = alarms.first(where: { $0.triggeredByUsername.lowercased() == username.lowercased() })
        }
        guard let ownAlarm = ownAlarm else {
            print("[MumbleService] No own open alarm found - not resuming position tracking")
            return
        }

        print("[MumbleService] Found own open alarm: \(ownAlarm.alarmId) (backendId=\(ownAlarm.backendAlarmId ?? "nil"))")

        // Start position tracking for this alarm
        startPositionTracking(alarmId: ownAlarm.alarmId, backendAlarmId: ownAlarm.backendAlarmId)
    }

    /// Wait for GPS fix and send update if we initially only had network location
    private func waitForGPSAndUpdate(alarmId: String) async {
        print("[MumbleService] Waiting for GPS fix (max \(alarmSettings.gpsWaitDuration)s)...")

        let startTime = Date()
        let maxWait = TimeInterval(alarmSettings.gpsWaitDuration)

        while Date().timeIntervalSince(startTime) < maxWait {
            try? await Task.sleep(nanoseconds: 2_000_000_000)  // Check every 2 seconds

            if let location = await locationService.getCurrentLocation() {
                let locationType = locationService.getLocationType(for: location)
                if locationType == .gps {
                    print("[MumbleService] Got GPS fix, sending update")
                    sendUpdateAlarm(
                        alarmId: alarmId,
                        latitude: location.coordinate.latitude,
                        longitude: location.coordinate.longitude,
                        locationType: locationType.rawValue
                    )
                    break
                }
            }
        }
    }

    /// Send UPDATE_ALARM message via Tree Message
    private func sendUpdateAlarm(
        alarmId: String,
        latitude: Double? = nil,
        longitude: Double? = nil,
        locationType: String? = nil,
        hasVoiceMessage: Bool? = nil,
        backendAlarmId: String? = nil
    ) {
        print("[MumbleService] sendUpdateAlarm called:")
        print("[MumbleService]   alarmId: \(alarmId)")
        print("[MumbleService]   latitude: \(latitude ?? 0), longitude: \(longitude ?? 0)")
        print("[MumbleService]   locationType: \(locationType ?? "nil")")
        print("[MumbleService]   hasVoiceMessage: \(hasVoiceMessage ?? false)")
        print("[MumbleService]   tenantChannelId: \(tenantChannelId)")

        let updateMessage = UpdateAlarmMessage(
            id: alarmId,
            latitude: latitude,
            longitude: longitude,
            locationType: locationType,
            hasVoiceMessage: hasVoiceMessage,
            backendAlarmId: backendAlarmId ?? alarmBackendId
        )

        if let jsonData = try? JSONEncoder().encode(updateMessage),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            print("[MumbleService] UPDATE_ALARM JSON: \(jsonString)")
            mumbleConnection.sendTreeMessage(tenantChannelId, message: jsonString)
            print("[MumbleService] UPDATE_ALARM sent to channel \(tenantChannelId)")
        } else {
            print("[MumbleService] ERROR: Failed to encode UPDATE_ALARM message")
        }
    }

    /// End an active alarm
    func endAlarm(alarmId: String) async {
        guard userPermissions.canEndAlarm else {
            print("[MumbleService] User does not have permission to end alarm")
            return
        }

        NSLog("[MumbleService] endAlarm called: alarmId=%@, currentAlarmId=%@, alarmBackendId=%@", alarmId, currentAlarmId ?? "nil", alarmBackendId ?? "nil")
        print("[MumbleService] endAlarm called for alarmId: \(alarmId)")

        // Stop position tracking if this is our alarm
        if alarmId == currentAlarmId {
            stopPositionTracking()
        }

        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)

        // Get backendAlarmId from local database BEFORE closing the alarm
        let backendAlarmId: String? = await MainActor.run {
            if alarmRepository == nil {
                alarmRepository = AlarmRepository.shared()
            }
            let alarm = alarmRepository?.getAlarm(byAlarmId: alarmId)
            print("[MumbleService] Found alarm in DB: \(alarm != nil), backendAlarmId: \(alarm?.backendAlarmId ?? "nil")")
            return alarm?.backendAlarmId
        }

        // Create END_ALARM message
        let endMessage = EndAlarmMessage(
            id: alarmId,
            userId: localSession,
            userName: credentials?.username ?? "",
            displayName: currentUserProfile?.effectiveName ?? "",
            triggeredByDisplayName: nil,  // Will be filled by receiver
            closedAt: timestamp
        )

        // Send via Tree Message
        if let jsonData = try? JSONEncoder().encode(endMessage),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            mumbleConnection.sendTreeMessage(tenantChannelId, message: jsonString)
            print("[MumbleService] END_ALARM sent via Tree Message")
        }

        // Update local database immediately (like Android)
        await MainActor.run {
            alarmRepository?.closeAlarm(alarmId: alarmId)
            openAlarms = alarmRepository?.getOpenAlarms() ?? []
            print("[MumbleService] Alarm closed locally, open alarms: \(openAlarms.count)")

            // Stop alarm sound if no more open alarms
            if openAlarms.isEmpty {
                AlarmSoundPlayer.shared.stopAlarm()
                print("[MumbleService] Stopped alarm sound - no more open alarms")
            }
        }

        // Send to backend using backendAlarmId (not local alarmId!)
        if let backendId = backendAlarmId {
            await sendEndAlarmToBackend(backendAlarmId: backendId, timestamp: timestamp)
        } else {
            print("[MumbleService] No backendAlarmId available - skipping backend notification")
        }

        // Clear local state if this was our alarm
        if alarmId == currentAlarmId {
            await MainActor.run {
                currentAlarmId = nil
                self.alarmBackendId = nil
                alarmTriggerState = .idle
            }
        }
    }

    /// Send end alarm to backend
    /// - Parameter backendAlarmId: The backend's alarm ID (not the local UUID!)
    private func sendEndAlarmToBackend(backendAlarmId: String, timestamp: Int64) async {
        guard let subdomain = tenantSubdomain,
              let certificateHash = credentials?.certificateHash else {
            print("[MumbleService] Cannot end alarm on backend: missing subdomain or certificateHash")
            return
        }

        print("[MumbleService] Sending END_ALARM to backend")
        print("[MumbleService]   backendAlarmId: \(backendAlarmId)")
        print("[MumbleService]   subdomain: \(subdomain)")

        let request = AlarmEndRequest(
            alarmId: backendAlarmId,  // Use backend ID, not local UUID!
            alarmEndUserName: credentials?.username,
            alarmEndUserDisplayname: currentUserProfile?.effectiveName,
            endedAt: timestamp
        )

        do {
            let response = try await apiClient.endAlarm(
                subdomain: subdomain,
                certificateHash: certificateHash,
                request: request
            )
            print("[MumbleService] Alarm ended on backend successfully")
            print("[MumbleService]   Response: success=\(response.success ?? false), message=\(response.message ?? "nil")")
        } catch {
            print("[MumbleService] Failed to end alarm on backend: \(error)")
        }
    }

    /// Reset alarm state (e.g., after cancellation or error)
    func resetAlarmState() {
        cancelVoiceRecording()
        locationService.stopWarmUp()
        DispatchQueue.main.async {
            self.alarmTriggerState = .idle
            self.currentAlarmId = nil
        }
    }

    // MARK: - Dispatcher Request

    /// Start GPS warm-up when user begins holding the dispatcher request button
    func startDispatcherRequestWarmUp() {
        print("[MumbleService] Starting dispatcher request warm-up (GPS)")
        locationService.warmUp()

        if !locationService.isLocationAvailable {
            locationService.requestAuthorization()
        }
    }

    /// Cancel dispatcher request warm-up (user released button before hold completed)
    func cancelDispatcherRequestWarmUp() {
        print("[MumbleService] Canceling dispatcher request warm-up")
        locationService.stopWarmUp()
    }

    /// Start voice recording for dispatcher request
    func startDispatcherVoiceRecording() {
        print("[MumbleService] Starting voice recording for dispatcher request")
        print("[MumbleService]   maxDuration: \(alarmSettings.dispatcherVoiceMaxDuration)s")
        voiceRecorder.maxDuration = TimeInterval(alarmSettings.dispatcherVoiceMaxDuration)
        dispatcherVoiceFilePath = voiceRecorder.startRecording()

        let recordingStarted = dispatcherVoiceFilePath != nil
        print("[MumbleService]   voiceFilePath: \(dispatcherVoiceFilePath?.lastPathComponent ?? "nil")")

        DispatchQueue.main.async {
            self.isRecordingVoice = recordingStarted && self.voiceRecorder.isRecording
        }
    }

    /// Cancel voice recording for dispatcher request (user pressed cancel button)
    /// Calls the backend API to update the request status to "cancelled"
    func cancelDispatcherVoiceRecording() async {
        print("[MumbleService] Canceling dispatcher voice recording")

        // 1. Stop the recording immediately
        voiceRecorder.cancelRecording()
        dispatcherVoiceFilePath = nil

        await MainActor.run {
            self.isRecordingVoice = false
        }

        // 2. Call the cancel API if we have a request ID
        guard let requestId = dispatcherRequestBackendId else {
            print("[MumbleService] No dispatcher request ID to cancel")
            await resetDispatcherState()
            return
        }

        // 3. Update local cache immediately for instant UI feedback
        dispatcherHistoryCache.updateLocalStatus(id: requestId, status: "cancelled")
        await MainActor.run {
            self.dispatcherRequestHistory = self.dispatcherHistoryCache.getItems()
        }

        guard let subdomain = tenantSubdomain,
              let certificateHash = credentials?.certificateHash else {
            print("[MumbleService] Missing subdomain or certificate hash for cancel API")
            await resetDispatcherState()
            return
        }

        do {
            try await apiClient.cancelDispatcherRequest(
                subdomain: subdomain,
                certificateHash: certificateHash,
                requestId: requestId
            )
            print("[MumbleService] Dispatcher request cancelled successfully on backend")

            // Show success toast
            await MainActor.run {
                self.showDispatcherCancelledToast = true
            }

            // Clear pending cancel (if any)
            pendingCancelRequestId = nil

        } catch {
            print("[MumbleService] Failed to cancel dispatcher request on backend: \(error)")

            // Store the request ID for retry after reconnect
            pendingCancelRequestId = requestId

            // Trigger reconnect
            print("[MumbleService] Triggering reconnect to retry cancel")
            Task {
                await reconnect()
            }
        }

        await resetDispatcherState()
    }

    /// Reset dispatcher request state after cancel or completion
    private func resetDispatcherState() async {
        await MainActor.run {
            self.isDispatcherRequestActive = false
            self.currentDispatcherRequestId = nil
            self.dispatcherRequestBackendId = nil
        }
        positionTracker.endBoost()
    }

    /// Retry pending cancel request after reconnect (called from reconnect logic)
    func retryPendingDispatcherCancel() async {
        guard let requestId = pendingCancelRequestId else { return }

        print("[MumbleService] Retrying pending dispatcher cancel for request: \(requestId)")

        guard let subdomain = tenantSubdomain,
              let certificateHash = credentials?.certificateHash else {
            print("[MumbleService] Missing credentials for retry")
            pendingCancelRequestId = nil
            return
        }

        do {
            try await apiClient.cancelDispatcherRequest(
                subdomain: subdomain,
                certificateHash: certificateHash,
                requestId: requestId
            )
            print("[MumbleService] Pending dispatcher cancel succeeded")

            await MainActor.run {
                self.showDispatcherCancelledToast = true
            }

            pendingCancelRequestId = nil
        } catch {
            print("[MumbleService] Retry of dispatcher cancel failed: \(error)")
            // Keep pendingCancelRequestId for next reconnect attempt
        }
    }

    /// Trigger dispatcher request - called when hold duration is reached
    /// Sends request to backend immediately, then updates location asynchronously
    func triggerDispatcherRequest() async {
        guard userPermissions.canCallDispatcher else {
            print("[MumbleService] User does not have permission to call dispatcher")
            return
        }

        guard connectionState == .synchronized else {
            print("[MumbleService] Cannot send dispatcher request - not connected")
            return
        }

        await MainActor.run {
            isDispatcherRequestActive = true
        }

        guard let subdomain = tenantSubdomain,
              let certificateHash = credentials?.certificateHash else {
            print("[MumbleService] Missing subdomain or certificate hash for backend API")
            return
        }

        // Send request to backend immediately WITHOUT waiting for location
        // Location will be updated via position tracking
        let request = DispatcherRequestCreateRequest(
            latitude: nil,
            longitude: nil,
            locationType: nil
        )

        do {
            let response = try await apiClient.createDispatcherRequest(
                subdomain: subdomain,
                certificateHash: certificateHash,
                request: request
            )

            print("[MumbleService] Dispatcher request created: id=\(response.id), queuePosition=\(response.queuePosition)")

            await MainActor.run {
                currentDispatcherRequestId = response.id
                dispatcherRequestBackendId = response.id
            }

            // Add to local cache immediately for instant UI update
            dispatcherHistoryCache.addLocalRequest(id: response.id, status: "pending")
            await MainActor.run {
                self.dispatcherRequestHistory = self.dispatcherHistoryCache.getItems()
            }

            // Start position tracking - PositionTracker will send location updates including initial position
            startDispatcherPositionTracking(requestId: response.id)

            // Stop GPS warm-up (PositionTracker handles tracking from here)
            locationService.stopWarmUp()

        } catch {
            print("[MumbleService] Failed to create dispatcher request: \(error)")
            await MainActor.run {
                isDispatcherRequestActive = false
            }
        }
    }

    /// Submit dispatcher voice recording after recording is complete
    func submitDispatcherVoiceRecording() async {
        print("[MumbleService] Submitting dispatcher voice recording...")
        print("[MumbleService]   dispatcherRequestBackendId=\(dispatcherRequestBackendId ?? "nil")")
        print("[MumbleService]   dispatcherVoiceFilePath=\(dispatcherVoiceFilePath?.lastPathComponent ?? "nil")")

        // Stop recording and get file path
        var voicePath = stopVoiceRecording()

        // Fallback: use stored path if stopVoiceRecording returned nil
        if voicePath == nil, let storedPath = dispatcherVoiceFilePath {
            print("[MumbleService] Using stored dispatcherVoiceFilePath as fallback")
            voicePath = storedPath
        }

        guard let voicePath = voicePath else {
            print("[MumbleService] No voice recording to submit")
            return
        }

        // Wait for backend request ID (max 30 seconds)
        let maxWaitSeconds = 30
        var waitedSeconds = 0

        while dispatcherRequestBackendId == nil && waitedSeconds < maxWaitSeconds {
            print("[MumbleService] Waiting for dispatcher request ID... (\(waitedSeconds + 1)/\(maxWaitSeconds)s)")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            waitedSeconds += 1
        }

        guard let backendId = dispatcherRequestBackendId else {
            print("[MumbleService] ERROR: No dispatcher request ID after \(maxWaitSeconds)s - cannot upload voice message!")
            return
        }

        guard let subdomain = tenantSubdomain,
              let certificateHash = credentials?.certificateHash else {
            print("[MumbleService] Cannot upload voice: missing credentials")
            return
        }

        print("[MumbleService] Uploading dispatcher voice message to request: \(backendId)")

        do {
            try await apiClient.uploadDispatcherRequestVoice(
                subdomain: subdomain,
                certificateHash: certificateHash,
                requestId: backendId,
                filePath: voicePath
            )
            print("[MumbleService] Dispatcher voice message uploaded successfully!")
        } catch {
            print("[MumbleService] Failed to upload dispatcher voice message: \(error)")
        }

        dispatcherVoiceFilePath = nil
    }

    /// Start position tracking for dispatcher request using PositionTracker
    private func startDispatcherPositionTracking(requestId: String) {
        print("[MumbleService] Starting position tracking for dispatcher request: \(requestId)")

        guard let subdomain = tenantSubdomain,
              let certificateHash = credentials?.certificateHash else {
            print("[MumbleService] Cannot start dispatcher position tracking: missing credentials")
            return
        }

        // Use PositionTracker with boost mode for high-frequency tracking
        // Session ID format: "dispatcher_{requestId}" for unified GPS endpoint
        let dispatcherInterval = alarmSettings.dispatcherGpsInterval
        positionTracker.boost(
            sessionId: "dispatcher_\(requestId)",
            frequencySeconds: dispatcherInterval,
            subdomain: subdomain,
            certificateHash: certificateHash
        )
        // Note: No callback needed for dispatcher - just position upload handled by PositionTracker
    }

    /// Stop dispatcher request tracking
    func stopDispatcherRequest() {
        print("[MumbleService] Stopping dispatcher request")
        positionTracker.endBoost()
        cancelVoiceRecording()

        DispatchQueue.main.async {
            self.isDispatcherRequestActive = false
            self.currentDispatcherRequestId = nil
            self.dispatcherRequestBackendId = nil
            self.dispatcherVoiceFilePath = nil
        }
    }

    /// Fetch dispatcher request history for the current user
    func fetchDispatcherRequestHistory() async {
        print("[MumbleService] fetchDispatcherRequestHistory() called")
        print("[MumbleService]   tenantSubdomain: \(tenantSubdomain ?? "nil")")
        if let hash = credentials?.certificateHash {
            print("[MumbleService]   certificateHash: \(hash.prefix(20))...")
        } else {
            print("[MumbleService]   certificateHash: nil")
        }

        guard let subdomain = tenantSubdomain,
              let certificateHash = credentials?.certificateHash else {
            print("[MumbleService] Cannot fetch dispatcher history: missing credentials")
            return
        }

        await MainActor.run {
            isLoadingDispatcherHistory = true
        }

        do {
            print("[MumbleService] Calling API getDispatcherRequestHistory...")
            let response = try await apiClient.getDispatcherRequestHistory(
                subdomain: subdomain,
                certificateHash: certificateHash,
                limit: 10
            )

            // Sync with local cache (merges backend data with local changes)
            dispatcherHistoryCache.syncWithBackend(response.requests)

            await MainActor.run {
                // Update UI from synced cache
                self.dispatcherRequestHistory = self.dispatcherHistoryCache.getItems()
                self.isLoadingDispatcherHistory = false
            }

            print("[MumbleService] Fetched \(response.requests.count) dispatcher history items from backend")
            for (index, item) in response.requests.enumerated() {
                print("[MumbleService]   [\(index)] id=\(item.id.prefix(8))... status=\(item.status)")
            }
        } catch {
            print("[MumbleService] Failed to fetch dispatcher history: \(error)")
            await MainActor.run {
                self.isLoadingDispatcherHistory = false
            }
        }
    }

    /// Flag to control SSE reconnection loop
    private var shouldRunDispatcherHistorySSE = false

    /// Start SSE stream for dispatcher history updates
    /// Call when user navigates to dispatcher tab
    /// Automatically reconnects when connection is reset (e.g., by Cloudflare after ~60s)
    func startDispatcherHistoryStream() {
        guard !shouldRunDispatcherHistorySSE else { return }

        guard let subdomain = tenantSubdomain,
              let certificateHash = credentials?.certificateHash else { return }

        shouldRunDispatcherHistorySSE = true

        dispatcherHistorySSETask = Task {
            var reconnectCount = 0
            let maxReconnectDelay: UInt64 = 10_000_000_000 // 10 seconds max

            while shouldRunDispatcherHistorySSE && !Task.isCancelled {
                do {
                    let stream = apiClient.streamDispatcherRequestHistory(
                        subdomain: subdomain,
                        certificateHash: certificateHash,
                        limit: 10
                    )

                    reconnectCount = 0

                    for try await response in stream {
                        if Task.isCancelled || !shouldRunDispatcherHistorySSE {
                            return
                        }

                        dispatcherHistoryCache.syncWithBackend(response.requests)

                        await MainActor.run {
                            self.dispatcherRequestHistory = self.dispatcherHistoryCache.getItems()
                            self.isLoadingDispatcherHistory = false
                        }
                    }

                } catch {
                    if Task.isCancelled || !shouldRunDispatcherHistorySSE {
                        return
                    }

                    reconnectCount += 1
                    let delay = min(UInt64(reconnectCount) * 2_000_000_000, maxReconnectDelay)
                    try? await Task.sleep(nanoseconds: delay)
                }
            }
            await MainActor.run {
                self.dispatcherHistorySSETask = nil
            }
        }
    }

    /// Stop SSE stream for dispatcher history updates
    /// Call when user leaves dispatcher tab
    func stopDispatcherHistoryStream() {
        guard shouldRunDispatcherHistorySSE else {
            return
        }

        shouldRunDispatcherHistorySSE = false
        dispatcherHistorySSETask?.cancel()
        dispatcherHistorySSETask = nil
    }

    // MARK: - MumbleConnectionDelegate

    func connectionStateChanged(_ state: ConnectionState) {
        let previousState = connectionState
        print("[MumbleService] connectionStateChanged: \(previousState) -> \(state)")

        DispatchQueue.main.async {
            self.connectionState = state

            // Handle state transitions for auto-reconnect
            if state == .synchronized {
                print("[MumbleService] State is .synchronized - calling onConnectionSuccess()")
                // Connection successful
                self.onConnectionSuccess()
                self.autoJoinTenantChannel()
            } else if state == .disconnected || state == .failed {
                // Connection lost - trigger auto-reconnect if applicable
                if previousState == .synchronized || previousState == .connecting || previousState == .connected {
                    let reason = self.errorMessage ?? "Unknown"
                    self.onConnectionLost(reason: reason)
                }
            }
        }
    }

    private func autoJoinTenantChannel() {
        guard tenantChannelId > 0 else {
            print("[MumbleService] No tenant channel ID - skipping auto-join")
            return
        }

        print("[MumbleService] Auto-joining tenant channel \(tenantChannelId)")

        // Join immediately - connection is already synchronized
        joinChannel(tenantChannelId)
    }

    // Debounce timer for channel updates
    private var channelUpdateWorkItem: DispatchWorkItem?
    private var pendingChannelList: [Channel]?

    func channelsUpdated(_ channelList: [Channel]) {
        // Cancel any pending update
        channelUpdateWorkItem?.cancel()

        // Store the latest channel list
        pendingChannelList = channelList

        // Debounce: wait 100ms for more updates before processing
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, let channels = self.pendingChannelList else { return }
            self.pendingChannelList = nil

            let filteredChannels = self.applyChannelFiltering(channels)
            self.channels = filteredChannels

            // IMPORTANT: Update user counts after setting channels
            // This fixes race condition where debounced channelsUpdated overwrites
            // correct user counts that were set by usersUpdated
            // (Matches Android behavior where user counts are always recalculated)
            self.updateChannelUserCounts()
        }

        channelUpdateWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }

    func usersUpdated(_ userList: [User]) {
        DispatchQueue.main.async {
            self.users = userList

            // Update user counts on existing channels without re-filtering
            self.updateChannelUserCounts()

            // Update local user's channel from user list
            self.updateLocalUserChannel()
        }
    }

    /// Update user counts on existing filtered channels
    private func updateChannelUserCounts() {
        // Build a map of channel ID -> user count
        var userCountByChannel: [UInt32: Int] = [:]
        for user in users {
            userCountByChannel[user.channelId, default: 0] += 1
        }

        // Update counts on existing channels
        let updatedChannels = channels.map { channel in
            var updated = channel
            updated.userCount = userCountByChannel[channel.id] ?? 0
            return updated
        }

        channels = updatedChannels
    }

    private func updateLocalUserChannel() {
        let session = localSession
        guard session > 0 else { return }

        // Find local user in user list
        if let localUser = users.first(where: { $0.session == session }) {
            let newChannelId = localUser.channelId
            let oldChannelId = localUserChannelId

            if newChannelId != oldChannelId {
                print("[MumbleService] Local user channel changed: \(oldChannelId) -> \(newChannelId)")
                localUserChannelId = newChannelId

                // Check if we need to sync UI with server state
                handleChannelSync(newChannelId: newChannelId)
            }
        }
    }

    private func handleChannelSync(newChannelId: UInt32) {
        let viewedChannel = currentlyViewedChannelId
        print("[MumbleService] handleChannelSync: newChannelId=\(newChannelId), viewedChannel=\(viewedChannel ?? 0), tenantChannelId=\(tenantChannelId)")

        // If user is viewing a channel that doesn't match server state
        if let viewed = viewedChannel, viewed != newChannelId {
            print("[MumbleService] Channel mismatch: viewing \(viewed) but server says \(newChannelId)")

            if newChannelId == 0 || newChannelId == tenantChannelId {
                print("[MumbleService] User moved to tenant/root channel - navigating back to list")
                navigateBackToList = true
            } else {
                print("[MumbleService] User in different channel - navigating to \(newChannelId)")
                navigateToChannel = newChannelId
            }
        } else if viewedChannel == nil && newChannelId != 0 && newChannelId != tenantChannelId {
            print("[MumbleService] User in channel \(newChannelId) but viewing list - triggering navigation")
            navigateToChannel = newChannelId
        } else {
            print("[MumbleService] No navigation needed (viewedChannel=\(viewedChannel ?? 0), newChannelId=\(newChannelId))")
        }
    }

    func serverInfoReceived(_ info: ServerInfo) {
        DispatchQueue.main.async {
            // Merge with existing serverInfo to preserve version and OS
            if let existing = self.serverInfo {
                self.serverInfo = ServerInfo(
                    welcomeMessage: info.welcomeMessage,
                    maxBandwidth: info.maxBandwidth,
                    maxUsers: info.maxUsers,
                    serverVersion: existing.serverVersion.isEmpty ? info.serverVersion : existing.serverVersion,
                    serverOs: existing.serverOs,
                    tlsCipherSuite: self.tlsCipherSuite,
                    latencyMs: self.latencyMs
                )
            } else {
                self.serverInfo = info
            }
        }
    }

    func serverVersionReceived(version: String, os: String, osVersion: String) {
        DispatchQueue.main.async {
            let fullOs = osVersion.isEmpty ? os : "\(os) \(osVersion)"

            if var existing = self.serverInfo {
                // Update existing serverInfo with version details
                self.serverInfo = ServerInfo(
                    welcomeMessage: existing.welcomeMessage,
                    maxBandwidth: existing.maxBandwidth,
                    maxUsers: existing.maxUsers,
                    serverVersion: version,
                    serverOs: fullOs,
                    tlsCipherSuite: self.tlsCipherSuite,
                    latencyMs: existing.latencyMs
                )
            } else {
                // Create new serverInfo with version details
                self.serverInfo = ServerInfo(
                    serverVersion: version,
                    serverOs: fullOs,
                    tlsCipherSuite: self.tlsCipherSuite
                )
            }
        }
    }

    func connectionRejected(reason: MumbleRejectReason, message: String) {
        DispatchQueue.main.async {
            self.errorMessage = message.isEmpty ? reason.localizedDescription : message

            // usernameInUse means our ghost session is still on the server — treat as ghost kick
            if reason == .usernameInUse {
                print("[MumbleService] Reject: usernameInUse — treating as ghost kick")
                self.wasKicked = true
                self.userDisconnected = true
                self.cancelReconnect()
                self.ghostKickMessage = "Sie wurden getrennt, da sich ein anderes Gerät mit Ihrem Konto angemeldet hat."
            }

            self.connectionState = .failed
        }
    }

    func connectionError(_ message: String) {
        DispatchQueue.main.async {
            self.errorMessage = message
            // Don't set connectionState here — let connectionStateChanged() handle
            // the state transition so onConnectionLost() sees the correct previousState
        }
    }

    func permissionQueryReceived(channelId: UInt32, permissions: Int, flush: Bool) {
        print("[MumbleService] Permission update: channel=\(channelId), permissions=0x\(String(permissions, radix: 16)), flush=\(flush)")
    }

    func textMessageReceived(_ message: ParsedTextMessage) {
        // Check if this is a tree message (used for alarms)
        guard !message.treeIds.isEmpty || !message.channelIds.isEmpty else {
            print("[MumbleService] Ignoring direct text message")
            return
        }

        // Try to parse as alarm message
        guard let parsed = AlarmMessageParser.parse(message.message) else {
            print("[MumbleService] Text message is not an alarm message")
            return
        }

        // Handle alarm message on main thread
        Task { @MainActor in
            switch parsed {
            case .startAlarm(let alarmMessage):
                handleStartAlarm(alarmMessage, senderSession: message.actor)

            case .updateAlarm(let updateMessage):
                handleUpdateAlarm(updateMessage)

            case .endAlarm(let endMessage):
                handleEndAlarm(endMessage)

            case .unknown(let type):
                print("[MumbleService] Unknown alarm message type: \(type)")
            }
        }
    }

    // MARK: - Alarm Message Handlers

    @MainActor
    private func handleStartAlarm(_ message: StartAlarmMessage, senderSession: UInt32) {
        NSLog("[MumbleService] TREE: START_ALARM id=%@, senderSession=%u, localSession=%u", message.id, senderSession, localSession)
        print("[MumbleService] START_ALARM received: id=\(message.id), from=\(message.displayName), channel=\(message.channelName)")

        // Ignore our own alarm messages
        if senderSession == localSession {
            NSLog("[MumbleService] TREE: Ignoring own START_ALARM - session match")
            print("[MumbleService] Ignoring own START_ALARM")
            return
        }

        // Check if user can receive alarms
        guard userPermissions.canReceiveAlarm else {
            print("[MumbleService] User cannot receive alarms - ignoring")
            return
        }

        // Ensure repository is initialized
        if alarmRepository == nil {
            alarmRepository = AlarmRepository.shared()
        }

        // Check if alarm already exists (duplicate message)
        if alarmRepository?.alarmExists(alarmId: message.id) == true {
            print("[MumbleService] Alarm already exists - ignoring duplicate")
            return
        }

        // Create and store alarm entity
        let alarm = alarmRepository?.insertAlarm(from: message)

        if let alarm = alarm {
            // Update published state
            lastReceivedAlarm = alarm
            openAlarms = alarmRepository?.getOpenAlarms() ?? []

            print("[MumbleService] Alarm stored: \(alarm.alarmId), open alarms: \(openAlarms.count)")

            // Play alarm sound
            let selectedSound = UserDefaults.standard.selectedAlarmSound
            AlarmSoundPlayer.shared.startAlarm(sound: selectedSound)
            NSLog("[MumbleService] TREE: TRIGGERING ALERT for alarm %@", alarm.alarmId)
            print("[MumbleService] Started alarm sound: \(selectedSound.displayName)")

            // Trigger alert dialog
            receivedAlarmForAlert = alarm
            print("[MumbleService] Alert dialog triggered for alarm: \(alarm.alarmId)")

            // TODO: Show local notification (for background)
        }
    }

    /// Dismiss the alarm alert dialog and stop alarm sound
    func dismissReceivedAlarm() {
        print("[MumbleService] Dismissing alarm alert")
        AlarmSoundPlayer.shared.stopAlarm()
        receivedAlarmForAlert = nil
    }

    /// Dismiss the "alarm ended" alert dialog
    func dismissEndAlarmAlert() {
        print("[MumbleService] Dismissing end alarm alert")
        receivedEndAlarmForAlert = nil
    }

    @MainActor
    private func handleUpdateAlarm(_ message: UpdateAlarmMessage) {
        print("[MumbleService] UPDATE_ALARM received: id=\(message.id), hasVoiceMessage=\(message.hasVoiceMessage?.description ?? "nil"), backendAlarmId=\(message.backendAlarmId ?? "nil")")

        // Ensure repository is initialized
        if alarmRepository == nil {
            alarmRepository = AlarmRepository.shared()
        }

        // Apply update to repository
        alarmRepository?.applyUpdate(message)

        // Refresh open alarms list
        openAlarms = alarmRepository?.getOpenAlarms() ?? []

        // Log current state after update
        for alarm in openAlarms {
            print("[MumbleService] After UPDATE: alarm \(alarm.alarmId) hasVoiceMessage=\(alarm.hasVoiceMessage), hasRemoteVoiceMessage=\(alarm.hasRemoteVoiceMessage), backendAlarmId=\(alarm.backendAlarmId ?? "nil")")
        }
    }

    @MainActor
    private func handleEndAlarm(_ message: EndAlarmMessage) {
        print("[MumbleService] END_ALARM received: id=\(message.id), closedBy=\(message.displayName)")

        // Ensure repository is initialized
        if alarmRepository == nil {
            alarmRepository = AlarmRepository.shared()
        }

        // Close alarm in repository
        alarmRepository?.closeAlarm(from: message)

        // Refresh open alarms list
        openAlarms = alarmRepository?.getOpenAlarms() ?? []

        // Clear lastReceivedAlarm if it was this alarm
        if lastReceivedAlarm?.alarmId == message.id {
            lastReceivedAlarm = nil
        }

        // Also dismiss the start alarm alert if it was showing this alarm
        if receivedAlarmForAlert?.alarmId == message.id {
            receivedAlarmForAlert = nil
        }

        // Stop alarm sound if no more open alarms
        if openAlarms.isEmpty {
            AlarmSoundPlayer.shared.stopAlarm()
            print("[MumbleService] Stopped alarm sound - no more open alarms")
        }

        // If this was our active alarm, reset state
        if message.id == currentAlarmId {
            stopPositionTracking()
            currentAlarmId = nil
            alarmBackendId = nil
            alarmTriggerState = .idle
        }

        // Show "alarm ended" dialog if:
        // 1. The alarm was NOT closed by us (don't show dialog for our own action)
        // 2. User has permission to receive alarms
        if message.userId != localSession && userPermissions.canReceiveAlarm {
            print("[MumbleService] Showing end alarm dialog - closedBy=\(message.displayName)")
            receivedEndAlarmForAlert = message
        }

        print("[MumbleService] Alarm closed, open alarms: \(openAlarms.count)")
    }

    /// Refresh open alarms from repository
    @MainActor
    func refreshOpenAlarms() {
        self.objectWillChange.send()
        openAlarms = alarmRepository?.getOpenAlarms() ?? []
        print("[MumbleService] refreshOpenAlarms: \(openAlarms.count) alarms")
    }

    /// Sync open alarms with backend and refresh local list
    /// Call this when opening the open alarms screen to ensure fresh data
    func syncAndRefreshOpenAlarms() async {
        print("[MumbleService] syncAndRefreshOpenAlarms() called")
        await syncAlarms()
        await MainActor.run {
            refreshOpenAlarms()
        }
    }

    func audioReceived(session: UInt32, pcmData: UnsafePointer<Int16>, frames: Int, sequence: Int64) {
        // Pass decoded audio to C++ engine for per-user buffering, float mixing, and crossfade
        audioService.addUserAudio(userId: session, samples: pcmData, frames: frames, sequence: sequence)

        // Start mixed playback if not already running
        if !isMixedPlaybackStarted {
            NSLog("[MumbleService] Starting mixed playback for first audio reception")
            isMixedPlaybackStarted = audioService.startMixedPlayback()
            NSLog("[MumbleService] Mixed playback started: %d", isMixedPlaybackStarted ? 1 : 0)
        }
    }

    func userAudioEnded(session: UInt32) {
        // Notify C++ engine that user stopped talking (triggers crossfade)
        audioService.notifyUserTalkingEnded(session)
    }

    func latencyUpdated(_ latencyMs: Int64) {
        DispatchQueue.main.async {
            self.latencyMs = latencyMs
            // Also update serverInfo if available
            if var info = self.serverInfo {
                info.latencyMs = latencyMs
                self.serverInfo = info
            }
        }
    }

    func tlsCipherSuiteDetected(_ cipherSuite: String) {
        DispatchQueue.main.async {
            self.tlsCipherSuite = cipherSuite
        }
    }

    private func stopAudioPlayback() {
        guard isMixedPlaybackStarted else { return }
        isMixedPlaybackStarted = false
        audioService.stopPlayback()
        NSLog("[MumbleService] Stopped audio playback")
    }

    // MARK: - Channel Filtering Pipeline (from Android)

    private var expandedChannelIds: Set<UInt32> = []

    func toggleChannelExpanded(_ channelId: UInt32) {
        if expandedChannelIds.contains(channelId) {
            expandedChannelIds.remove(channelId)
        } else {
            expandedChannelIds.insert(channelId)
        }
        let flatChannels = mumbleConnection.getChannelList()
        DispatchQueue.main.async {
            self.channels = self.applyChannelFiltering(flatChannels)
        }
    }

    func isChannelExpanded(_ channelId: UInt32) -> Bool {
        expandedChannelIds.contains(channelId)
    }

    private func applyChannelFiltering(_ flatChannels: [Channel]) -> [Channel] {
        let hierarchy = Channel.buildHierarchy(from: flatChannels)
        let accessibleChannels = Channel.filterAccessible(hierarchy)
        let tenantChannels = Channel.filterByTenant(accessibleChannels, subdomain: tenantSubdomain)
        let withDepths = Channel.updateDepths(tenantChannels)
        let allIds = Set(flatChannels.map { $0.id })
        let effectiveExpandedIds = expandedChannelIds.isEmpty ? allIds : expandedChannelIds
        let flattened = Channel.flatten(withDepths, expandedIds: effectiveExpandedIds)
        return flattened
    }
}

// MARK: - Connection State

enum ConnectionState {
    case disconnected
    case connecting
    case connected
    case synchronizing
    case synchronized
    case disconnecting
    case failed

    var displayText: String {
        switch self {
        case .disconnected: return "Getrennt"
        case .connecting: return "Verbinde..."
        case .connected: return "Verbunden"
        case .synchronizing: return "Synchronisiere..."
        case .synchronized: return "Bereit"
        case .disconnecting: return "Trenne..."
        case .failed: return "Fehler"
        }
    }
}

// MARK: - ServerInfo

struct ServerInfo {
    let welcomeMessage: String
    let maxBandwidth: UInt32
    let maxUsers: UInt32
    let serverVersion: String
    let serverOs: String
    let tlsCipherSuite: String
    var latencyMs: Int64

    init(
        welcomeMessage: String = "",
        maxBandwidth: UInt32 = 0,
        maxUsers: UInt32 = 0,
        serverVersion: String = "",
        serverOs: String = "",
        tlsCipherSuite: String = "",
        latencyMs: Int64 = -1
    ) {
        self.welcomeMessage = welcomeMessage
        self.maxBandwidth = maxBandwidth
        self.maxUsers = maxUsers
        self.serverVersion = serverVersion
        self.serverOs = serverOs
        self.tlsCipherSuite = tlsCipherSuite
        self.latencyMs = latencyMs
    }
}

// MARK: - User Permissions

struct UserPermissions {
    let canReceiveAlarm: Bool
    let canTriggerAlarm: Bool
    let canEndAlarm: Bool
    let canManageAudiocast: Bool
    let canPlayAudiocast: Bool
    let canCallDispatcher: Bool
    let canActAsDispatcher: Bool

    static let none = UserPermissions(
        canReceiveAlarm: false,
        canTriggerAlarm: false,
        canEndAlarm: false,
        canManageAudiocast: false,
        canPlayAudiocast: false,
        canCallDispatcher: false,
        canActAsDispatcher: false
    )
}

