import Foundation
import Combine
import AVFoundation
import Network

/// Current user profile information
struct UserProfile {
    let username: String
    let displayName: String?

    var effectiveName: String {
        displayName ?? username
    }
}

/// Service that manages Mumble connection and channel data
class MumbleService: NSObject, ObservableObject, MumbleConnectionDelegate {
    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var channels: [Channel] = []
    @Published private(set) var users: [User] = []
    @Published private(set) var serverInfo: ServerInfo?
    @Published private(set) var errorMessage: String?
    @Published private(set) var currentUserProfile: UserProfile?

    /// The channel the local user is currently in (from server state)
    @Published private(set) var localUserChannelId: UInt32 = 0

    /// Published when user should navigate to a specific channel
    @Published var navigateToChannel: UInt32? = nil

    /// Published when user should navigate back to channel list
    @Published var navigateBackToList: Bool = false

    /// Audio input level (0.0 - 1.0) for UI feedback
    @Published private(set) var audioInputLevel: Float = 0

    /// Is voice detected by VAD
    @Published private(set) var isVoiceDetected: Bool = false

    /// Seconds until next reconnect attempt (0 = not reconnecting)
    @Published private(set) var reconnectCountdown: Int = 0

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

    private let apiClient = SemparaAPIClient()
    private let keycloakService = KeycloakAuthService()
    private let audioService = AudioService()
    private var credentials: MumbleCredentials?
    private let mumbleConnection = MumbleConnection()

    // Opus codec for audio encoding/decoding
    private var opusCodec: OpusCodecBridge?
    private var audioSequenceNumber: Int64 = 0

    // Audio playback state
    private var isMixedPlaybackStarted = false

    // Tenant filtering
    private var tenantSubdomain: String?
    private(set) var tenantChannelId: UInt32 = 0

    // Track currently viewed channel for sync
    var currentlyViewedChannelId: UInt32? = nil

    var localSession: UInt32 {
        return mumbleConnection.localSession
    }

    /// Check if user is in the tenant (root) channel
    var isInTenantChannel: Bool {
        localUserChannelId == 0 || localUserChannelId == tenantChannelId
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
    }

    deinit {
        networkMonitor?.cancel()
        // Cancel tasks directly without creating new closures (avoids weak reference issues during deallocation)
        reconnectTask?.cancel()
        countdownTask?.cancel()
        ghostReconnectTask?.cancel()
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
            // Exponential backoff: 1s, 2s, 4s, 8s, ... up to max 16 minutes
            let exponentialDelay = Int(pow(2.0, Double(reconnectAttempts)))
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
        print("[MumbleService] Connection successful - resetting reconnect counter")
        reconnectAttempts = 0
        cancelReconnect()
        wasKicked = false
    }

    /// Called when connection is lost (not by user choice). Triggers auto-reconnect if conditions are met.
    private func onConnectionLost(reason: String) {
        print("[MumbleService] === CONNECTION LOST ===")
        print("[MumbleService]   reason: \(reason)")
        logReconnectState("onConnectionLost entry")

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
        let isGhostDisconnect = reasonLower.contains("ghost") ||
                               reasonLower.contains("another") ||
                               reasonLower.contains("duplicate")

        if isGhostDisconnect {
            print("[MumbleService] Kicked (ghost/duplicate session) - will retry after 60s delay")
            wasKicked = true
            cancelReconnect()

            // Schedule a delayed reconnect after 60 seconds
            ghostReconnectTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 60_000_000_000)  // 60 seconds
                guard !Task.isCancelled, let self = self else { return }

                if !self.userDisconnected && self.lastCredentials != nil {
                    print("[MumbleService] Ghost disconnect delay expired - attempting reconnect")
                    await MainActor.run {
                        self.wasKicked = false
                    }
                    self.scheduleReconnect(immediate: true)
                }
            }
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
        // Don't reconnect if already connected or connecting
        guard connectionState == .disconnected || connectionState == .failed else {
            print("[MumbleService] Already connected or connecting, skipping connectWithStoredCredentials")
            return
        }

        guard let subdomain = UserDefaults.standard.string(forKey: "subdomain") else {
            await MainActor.run {
                errorMessage = "Keine Anmeldedaten vorhanden"
                connectionState = .failed
            }
            return
        }

        // Try to get valid access token (refresh if needed)
        let accessToken: String
        do {
            accessToken = try await getValidAccessToken()
        } catch {
            await MainActor.run {
                errorMessage = "Sitzung abgelaufen. Bitte erneut anmelden."
                connectionState = .failed
            }
            return
        }

        // Store subdomain for tenant filtering
        self.tenantSubdomain = subdomain

        await MainActor.run {
            connectionState = .connecting
            errorMessage = nil
        }

        do {
            // Fetch Mumble credentials from tenant API
            credentials = try await apiClient.fetchMumbleCredentials(
                subdomain: subdomain,
                accessToken: accessToken
            )

            guard let creds = credentials else {
                throw APIError.invalidResponse
            }

            print("[MumbleService] Got credentials for \(creds.serverHost):\(creds.serverPort)")
            print("[MumbleService] Username: \(creds.username)")
            print("[MumbleService] Display name: \(creds.displayName)")
            print("[MumbleService] Tenant subdomain: \(subdomain)")

            // Set current user profile
            await MainActor.run {
                self.currentUserProfile = UserProfile(
                    username: creds.username,
                    displayName: creds.displayName != creds.username ? creds.displayName : nil
                )
            }

            // Store tenant channel ID for filtering and auto-join
            if let channelId = creds.tenantChannelId {
                self.tenantChannelId = UInt32(channelId)
                print("[MumbleService] Tenant channel ID: \(channelId)")
            }

            // Store credentials for auto-reconnect
            lastCredentials = creds
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

        } catch let error as APIError {
            print("[MumbleService] API error: \(error)")
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

    func connect(host: String, port: Int, username: String, password: String, certificatePath: String? = nil) {
        print("[MumbleService] Direct connect not supported - use connectWithStoredCredentials()")
    }

    /// Disconnect from server (user-initiated). Will NOT auto-reconnect.
    func disconnect() {
        print("[MumbleService] Disconnecting (user-initiated)")
        userDisconnected = true  // Prevent auto-reconnect
        cancelReconnect()
        stopTransmitting()
        stopAudioPlayback()
        mumbleConnection.disconnect()
    }

    /// Disconnect for manual reconnect via UI. Does NOT set userDisconnected - allows auto-reconnect.
    func disconnectForReconnect() {
        print("[MumbleService] Disconnecting for reconnect (manual)")
        cancelReconnect()
        reconnectAttempts = 0  // Reset counter for fresh start
        stopTransmitting()
        stopAudioPlayback()
        mumbleConnection.disconnect()
    }

    func reconnect() async {
        disconnectForReconnect()
        try? await Task.sleep(nanoseconds: 500_000_000)
        await connectWithStoredCredentials()
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

    // MARK: - MumbleConnectionDelegate

    func connectionStateChanged(_ state: ConnectionState) {
        let previousState = connectionState

        DispatchQueue.main.async {
            self.connectionState = state

            // Handle state transitions for auto-reconnect
            if state == .synchronized {
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

        // Small delay to ensure connection is fully ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            self.joinChannel(self.tenantChannelId)
        }
    }

    func channelsUpdated(_ channelList: [Channel]) {
        DispatchQueue.main.async {
            let filteredChannels = self.applyChannelFiltering(channelList)
            self.channels = filteredChannels
        }
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
        print("[MumbleService] updateChannelUserCounts: channels.count=\(channels.count), users.count=\(users.count)")

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

        print("[MumbleService] updateChannelUserCounts: updatedChannels.count=\(updatedChannels.count)")
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

        // If user is viewing a channel that doesn't match server state
        if let viewed = viewedChannel, viewed != newChannelId {
            print("[MumbleService] Channel mismatch: viewing \(viewed) but server says \(newChannelId)")

            if newChannelId == 0 || newChannelId == tenantChannelId {
                // User was moved to root/tenant channel - navigate back to list
                print("[MumbleService] User moved to tenant/root channel - navigating back to list")
                navigateBackToList = true
            } else {
                // User is in a different channel - navigate to correct one
                print("[MumbleService] User in different channel - navigating to \(newChannelId)")
                navigateToChannel = newChannelId
            }
        } else if viewedChannel == nil && newChannelId != 0 && newChannelId != tenantChannelId {
            // User is in a channel but viewing list - navigate to channel
            print("[MumbleService] User in channel \(newChannelId) but viewing list - navigating")
            navigateToChannel = newChannelId
        }
    }

    func serverInfoReceived(_ info: ServerInfo) {
        DispatchQueue.main.async {
            self.serverInfo = info
        }
    }

    func connectionRejected(reason: MumbleRejectReason, message: String) {
        DispatchQueue.main.async {
            self.errorMessage = message.isEmpty ? reason.localizedDescription : message
            self.connectionState = .failed
        }
    }

    func connectionError(_ message: String) {
        DispatchQueue.main.async {
            self.errorMessage = message
            self.connectionState = .failed
        }
    }

    func permissionQueryReceived(channelId: UInt32, permissions: Int, flush: Bool) {
        print("[MumbleService] Permission update: channel=\(channelId), permissions=0x\(String(permissions, radix: 16)), flush=\(flush)")
    }

    func audioReceived(session: UInt32, pcmData: UnsafePointer<Int16>, frames: Int, sequence: Int64) {
        // Pass decoded audio to C++ engine for per-user buffering, float mixing, and crossfade
        NSLog("[MumbleService] audioReceived: session=%u, frames=%d, seq=%lld", session, frames, sequence)
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
}

