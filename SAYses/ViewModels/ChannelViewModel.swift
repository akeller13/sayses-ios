import Foundation
import Observation
import Combine
import SwiftUI

@Observable
class ChannelViewModel: TrackingSSEDelegate {
    let channel: Channel
    private let mumbleService: MumbleService
    private let apiClient = SemparaAPIClient()
    private var cancellables = Set<AnyCancellable>()
    private var blePttManager: BlePttButtonManager?
    private var trackingSSE: TrackingSSE?

    var isTransmitting = false
    var audioLevel: Float = 0
    var isFavorite = false
    var isMuted = false
    var canSpeak = true
    var canTriggerAlarm = true
    var members: [User] = []
    var channelMembers: [ChannelMember] = []
    var canMuteMembers = false
    var canUnmuteMembers = false
    var memberProfileImages: [String: UIImage] = [:]
    var connectedBluetoothDevice: String?
    var currentUserDisplayName: String?
    var currentUserRole: String?

    // Read transmission mode from AppStorage
    var transmissionMode: TransmissionMode {
        let rawValue = UserDefaults.standard.string(forKey: "transmissionMode") ?? TransmissionMode.pushToTalk.rawValue
        return TransmissionMode(rawValue: rawValue) ?? .pushToTalk
    }

    init(channel: Channel, mumbleService: MumbleService) {
        self.channel = channel
        self.mumbleService = mumbleService
        loadSettings()
        observeUsers()
        observeAudioLevel()
        observeVoiceDetection()
        observeChannelPermissions()
    }

    private func observeChannelPermissions() {
        // Observe real-time suppress state changes for the current user.
        // When a moderator mutes/unmutes a user, the backend calls suppress_user()
        // which sends a UserState update via Mumble to all clients.
        mumbleService.$users
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (users: [User]) in
                guard let self = self else { return }
                let localSession = self.mumbleService.localSession
                guard localSession > 0 else { return }
                guard let currentUser = users.first(where: { $0.session == localSession }) else { return }

                let shouldCanSpeak = !currentUser.isSuppressed
                if self.canSpeak != shouldCanSpeak {
                    NSLog("[ChannelViewModel] Suppress state changed: isSuppressed=\(currentUser.isSuppressed) -> canSpeak \(self.canSpeak) -> \(shouldCanSpeak)")
                    self.canSpeak = shouldCanSpeak
                    // Stop transmitting if speak permission was revoked
                    if !shouldCanSpeak && self.isTransmitting {
                        self.isTransmitting = false
                        self.audioLevel = 0
                        self.mumbleService.stopTransmitting()
                        NSLog("[ChannelViewModel] Stopped transmission - user suppressed")
                    }
                }
            }
            .store(in: &cancellables)
    }

    private func observeUsers() {
        // Observe user changes from MumbleService
        mumbleService.$users
            .receive(on: DispatchQueue.main)
            .sink { [weak self] users in
                guard let self = self else { return }
                self.members = users.filter { $0.channelId == self.channel.id }
            }
            .store(in: &cancellables)
    }

    private func observeAudioLevel() {
        // Observe audio input level from MumbleService
        mumbleService.$audioInputLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                guard let self = self else { return }
                // Only update when transmitting AND change is significant (> 0.05)
                // This prevents excessive UI updates that cause performance issues
                if self.isTransmitting && abs(level - self.audioLevel) > 0.05 {
                    self.audioLevel = level
                }
            }
            .store(in: &cancellables)
    }

    private func setupBlePtt() {
        guard blePttManager == nil else { return }

        let manager = BlePttButtonManager()
        blePttManager = manager

        manager.onPttPressed = { [weak self] in
            DispatchQueue.main.async {
                self?.startTransmitting()
            }
        }
        manager.onPttReleased = { [weak self] in
            DispatchQueue.main.async {
                self?.stopTransmitting()
            }
        }
        manager.onDoubleClick = { [weak self] in
            DispatchQueue.main.async {
                self?.toggleTransmissionMode()
            }
        }

        // Observe connected device name
        manager.$connectedDeviceName
            .receive(on: DispatchQueue.main)
            .sink { [weak self] name in
                self?.connectedBluetoothDevice = name
            }
            .store(in: &cancellables)

        manager.initialize()
    }

    private func observeVoiceDetection() {
        // For VAD mode: observe voice detection
        mumbleService.$isVoiceDetected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] detected in
                guard let self = self else { return }
                guard self.transmissionMode == .voiceActivity else { return }
                guard self.canSpeak else { return }

                if detected && !self.isTransmitting {
                    // Voice detected - start transmitting
                    self.isTransmitting = true
                    self.mumbleService.startTransmitting()
                    NSLog("[ChannelViewModel] VAD: Voice detected - starting transmission")
                } else if !detected && self.isTransmitting {
                    // Voice ended - stop transmitting
                    self.isTransmitting = false
                    self.audioLevel = 0
                    self.mumbleService.stopTransmitting()
                    NSLog("[ChannelViewModel] VAD: Voice ended - stopping transmission")
                }
            }
            .store(in: &cancellables)
    }

    func joinChannel() async {
        // Join channel via Mumble
        mumbleService.joinChannel(channel.id)
        // Load initial members
        members = mumbleService.getChannelUsers(channel.id)

        // Auto-start for Continuous mode
        if transmissionMode == .continuous && canSpeak {
            NSLog("[ChannelViewModel] Continuous mode - auto-starting transmission")
            isTransmitting = true
            mumbleService.startTransmitting()
        }

        // Start BLE PTT scanning only when actually in a channel
        setupBlePtt()

        // Load channel members from backend (non-blocking)
        await loadChannelMembers()

        // Start tracking SSE for real-time position updates
        startTrackingSSE()
    }

    private func loadChannelMembers() async {
        guard let subdomain = mumbleService.tenantSubdomain,
              let certificateHash = mumbleService.credentials?.certificateHash else {
            print("[ChannelViewModel] Cannot load channel members: missing credentials")
            return
        }

        do {
            let response = try await apiClient.fetchChannelMembers(
                subdomain: subdomain,
                certificateHash: certificateHash,
                mumbleChannelId: channel.id
            )
            let members = response.members
            self.channelMembers = members
            self.canMuteMembers = response.canMute
            self.canUnmuteMembers = response.canUnmute
            self.canSpeak = response.canSpeak
            print("[ChannelViewModel] Loaded \(members.count) channel members from backend, canMute=\(response.canMute), canUnmute=\(response.canUnmute), canSpeak=\(response.canSpeak)")

            // Find own user and extract display name + role
            if let myUsername = mumbleService.credentials?.username {
                let ownMember = members.first { $0.username.lowercased() == myUsername.lowercased() }
                    ?? members.first { $0.username.components(separatedBy: "@").first?.lowercased() == myUsername.components(separatedBy: "@").first?.lowercased() }
                if let me = ownMember {
                    self.currentUserDisplayName = me.displayName
                    self.currentUserRole = me.roleName
                    print("[ChannelViewModel] Own user: \(me.displayName), role: \(me.roleName ?? "none")")
                }
            }

            // Load profile images for members that have one
            await loadMemberProfileImages(members: members, subdomain: subdomain, certificateHash: certificateHash)
        } catch {
            print("[ChannelViewModel] Failed to load channel members: \(error)")
        }
    }

    private func loadMemberProfileImages(members: [ChannelMember], subdomain: String, certificateHash: String) async {
        await withTaskGroup(of: (String, UIImage?).self) { group in
            for member in members where member.hasProfileImage {
                group.addTask { [apiClient] in
                    do {
                        let response = try await apiClient.fetchUserProfile(
                            subdomain: subdomain,
                            certificateHash: certificateHash,
                            username: member.username
                        )
                        if let data = response.imageData, let image = UIImage(data: data) {
                            return (member.username, image)
                        }
                    } catch {
                        print("[ChannelViewModel] Failed to load profile image for \(member.username): \(error)")
                    }
                    return (member.username, nil)
                }
            }

            for await (username, image) in group {
                if let image = image {
                    self.memberProfileImages[username] = image
                }
            }
        }
        print("[ChannelViewModel] Loaded \(memberProfileImages.count) profile images")
    }

    func leaveChannel() {
        stopTransmittingForce()
        blePttManager?.release()
        trackingSSE?.stop()
        trackingSSE = nil
        // Leave channel and return to tenant channel
        mumbleService.leaveChannel()
    }

    func startTransmitting() {
        NSLog("[ChannelViewModel] startTransmitting called, canSpeak=\(canSpeak), mode=\(transmissionMode.rawValue), isTransmitting=\(isTransmitting)")
        guard canSpeak else {
            NSLog("[ChannelViewModel] Cannot speak - blocked")
            return
        }

        // In continuous mode, transmission is already running
        if transmissionMode == .continuous && isTransmitting {
            NSLog("[ChannelViewModel] Already transmitting in continuous mode")
            return
        }

        // In VAD mode, transmission is controlled by voice detection
        if transmissionMode == .voiceActivity {
            NSLog("[ChannelViewModel] VAD mode - transmission controlled by voice detection")
            return
        }

        isTransmitting = true
        NSLog("[ChannelViewModel] Calling mumbleService.startTransmitting()")
        mumbleService.startTransmitting()
    }

    func stopTransmitting() {
        // In continuous mode, don't stop on button release
        if transmissionMode == .continuous {
            return
        }

        // In VAD mode, transmission is controlled by voice detection
        if transmissionMode == .voiceActivity {
            return
        }

        isTransmitting = false
        audioLevel = 0
        mumbleService.stopTransmitting()
    }

    /// Force stop transmitting (for leaving channel)
    private func stopTransmittingForce() {
        isTransmitting = false
        audioLevel = 0
        mumbleService.stopTransmitting()
    }

    func toggleFavorite() {
        isFavorite.toggle()
        saveFavorite()
    }

    func toggleMute() {
        isMuted.toggle()
        mumbleService.setOutputMuted(isMuted)
    }

    func triggerAlarm() {
        // TODO: Trigger alarm via API
        print("Alarm triggered for channel: \(channel.name)")
    }

    func toggleMuteForMember(_ member: ChannelMember) async {
        guard let subdomain = mumbleService.tenantSubdomain,
              let certificateHash = mumbleService.credentials?.certificateHash else {
            print("[ChannelViewModel] Cannot toggle mute: missing credentials")
            return
        }

        let shouldMute = !member.isMuted

        // Optimistic UI update
        if let index = channelMembers.firstIndex(where: { $0.username == member.username }) {
            channelMembers[index].isMuted = shouldMute
        }

        do {
            if shouldMute {
                try await apiClient.muteChannelUser(
                    subdomain: subdomain,
                    certificateHash: certificateHash,
                    mumbleChannelId: channel.id,
                    username: member.username
                )
            } else {
                try await apiClient.unmuteChannelUser(
                    subdomain: subdomain,
                    certificateHash: certificateHash,
                    mumbleChannelId: channel.id,
                    username: member.username
                )
            }
            print("[ChannelViewModel] Successfully \(shouldMute ? "muted" : "unmuted") \(member.username)")
        } catch {
            // Revert optimistic update on failure
            if let index = channelMembers.firstIndex(where: { $0.username == member.username }) {
                channelMembers[index].isMuted = !shouldMute
            }
            print("[ChannelViewModel] Failed to \(shouldMute ? "mute" : "unmute") \(member.username): \(error)")
        }
    }

    /// Handle transmission mode change from settings/menu
    /// (Matches Android's LaunchedEffect(uiState.transmissionMode) pattern)
    func handleTransmissionModeChange(from oldMode: TransmissionMode, to newMode: TransmissionMode) {
        NSLog("[ChannelViewModel] Mode changed via menu: \(oldMode.rawValue) -> \(newMode.rawValue)")

        if newMode == .continuous && oldMode != .continuous {
            // Switched TO continuous - start transmitting
            if canSpeak && !isTransmitting {
                isTransmitting = true
                mumbleService.startTransmitting()
                NSLog("[ChannelViewModel] Started continuous transmission")
            }
        } else if oldMode == .continuous && newMode != .continuous {
            // Switched FROM continuous - stop transmitting
            if isTransmitting {
                isTransmitting = false
                audioLevel = 0
                mumbleService.stopTransmitting()
                NSLog("[ChannelViewModel] Stopped continuous transmission")
            }
        }
    }

    /// Toggle between PTT and Continuous mode (for double-click feature)
    func toggleTransmissionMode() {
        let currentMode = transmissionMode
        NSLog("[ChannelViewModel] toggleTransmissionMode called, current mode: \(currentMode.rawValue)")

        // Only toggle between PTT and Continuous
        if currentMode == .pushToTalk {
            // Switch to Continuous
            UserDefaults.standard.set(TransmissionMode.continuous.rawValue, forKey: "transmissionMode")
            NSLog("[ChannelViewModel] Switched to Continuous mode")
            // Start transmitting immediately
            if canSpeak && !isTransmitting {
                isTransmitting = true
                mumbleService.startTransmitting()
            }
        } else if currentMode == .continuous {
            // Switch to PTT
            UserDefaults.standard.set(TransmissionMode.pushToTalk.rawValue, forKey: "transmissionMode")
            NSLog("[ChannelViewModel] Switched to PTT mode")
            // Stop transmitting
            if isTransmitting {
                isTransmitting = false
                audioLevel = 0
                mumbleService.stopTransmitting()
            }
        }
        // VAD mode: do nothing
    }

    // MARK: - Tracking SSE

    private func startTrackingSSE() {
        guard let subdomain = mumbleService.tenantSubdomain,
              let certificateHash = mumbleService.credentials?.certificateHash else {
            print("[ChannelViewModel] Cannot start tracking SSE: missing credentials")
            return
        }

        let sse = TrackingSSE(subdomain: subdomain, certificateHash: certificateHash, channelId: channel.id)
        sse.delegate = self
        sse.start()
        trackingSSE = sse
        print("[ChannelViewModel] Tracking SSE started for channel \(channel.id)")
    }

    func positionsUpdated(_ positions: [TrackingPosition]) {
        // Backend sends positions sorted by recorded_at DESC (newest first).
        // Only apply the first (newest) position per user to avoid overwriting with older data.
        var updatedUsernames = Set<String>()
        for position in positions {
            guard !updatedUsernames.contains(position.username) else { continue }

            let index = channelMembers.firstIndex(where: { $0.username == position.username })
                ?? channelMembers.firstIndex(where: {
                    $0.username.components(separatedBy: "@").first == position.username
                })
            if let index {
                channelMembers[index].latitude = position.latitude
                channelMembers[index].longitude = position.longitude
                channelMembers[index].positionTimestamp = position.recordedAt
                updatedUsernames.insert(position.username)
            }
        }
    }

    // MARK: - Private

    private func loadSettings() {
        // Load as [Int] for UserDefaults compatibility (must match ChannelListView)
        let favoriteIds = UserDefaults.standard.array(forKey: "favoriteChannels") as? [Int] ?? []
        isFavorite = favoriteIds.contains(Int(channel.id))
    }

    private func saveFavorite() {
        // Save as [Int] for UserDefaults compatibility (must match ChannelListView)
        var favoriteIds = UserDefaults.standard.array(forKey: "favoriteChannels") as? [Int] ?? []
        let channelIdInt = Int(channel.id)
        if isFavorite {
            if !favoriteIds.contains(channelIdInt) {
                favoriteIds.append(channelIdInt)
            }
        } else {
            favoriteIds.removeAll { $0 == channelIdInt }
        }
        UserDefaults.standard.set(favoriteIds, forKey: "favoriteChannels")
    }
}
