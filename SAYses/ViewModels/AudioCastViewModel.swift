//
//  AudioCastViewModel.swift
//  SAYses
//
//  ViewModel for AudioCast playback feature
//

import Foundation

@Observable
class AudioCastViewModel {
    let channelId: UInt32
    private let mumbleService: MumbleService
    private let apiClient = SemparaAPIClient()

    // UI State
    var isLoading = true
    var errorMessage: String?
    var audioCasts: [AudioCastItem] = []
    var selectedIds: Set<String> = []
    var playbackStatus: PlaybackStatus?
    var isPlaying = false
    var isPaused = false
    var currentPlaybackId: String?

    // Polling
    private var pollingTask: Task<Void, Never>?

    init(channelId: UInt32, mumbleService: MumbleService) {
        self.channelId = channelId
        self.mumbleService = mumbleService
    }

    deinit {
        stopStatusPolling()
    }

    // MARK: - Public Methods

    /// Load AudioCast list from server
    func loadAudioCasts() async {
        isLoading = true
        errorMessage = nil

        guard let subdomain = mumbleService.tenantSubdomain,
              let certificateHash = mumbleService.credentials?.certificateHash else {
            await MainActor.run {
                self.isLoading = false
                self.errorMessage = "Nicht authentifiziert"
            }
            return
        }

        do {
            let response = try await apiClient.getAudioCastList(
                subdomain: subdomain,
                certificateHash: certificateHash,
                channelId: Int(channelId)
            )

            await MainActor.run {
                self.isLoading = false
                self.audioCasts = response.audiocasts.sorted { $0.position < $1.position }
                self.playbackStatus = response.playbackStatus
                self.isPlaying = response.playbackStatus.isPlaying
                self.isPaused = response.playbackStatus.isPaused
                self.currentPlaybackId = response.playbackStatus.playbackId

                // Start polling if playback is active
                if response.playbackStatus.isPlaying || response.playbackStatus.isPaused {
                    self.startStatusPolling()
                }
            }

            print("[AudioCastViewModel] Loaded \(response.audiocasts.count) AudioCasts")
        } catch {
            print("[AudioCastViewModel] Failed to load AudioCasts: \(error)")
            await MainActor.run {
                self.isLoading = false
                self.errorMessage = "Fehler beim Laden: \(error.localizedDescription)"
            }
        }
    }

    /// Toggle selection of an AudioCast
    func toggleSelection(_ audioCastId: String) {
        if selectedIds.contains(audioCastId) {
            selectedIds.remove(audioCastId)
        } else {
            selectedIds.insert(audioCastId)
        }
    }

    /// Start playback of selected AudioCasts
    func play() async {
        let selectedList = selectedIds.sorted()
        guard !selectedList.isEmpty else { return }

        isLoading = true
        errorMessage = nil

        guard let subdomain = mumbleService.tenantSubdomain,
              let certificateHash = mumbleService.credentials?.certificateHash else {
            await MainActor.run {
                self.isLoading = false
                self.errorMessage = "Nicht authentifiziert"
            }
            return
        }

        // Sort selected IDs by position
        let sortedIds = audioCasts
            .filter { selectedIds.contains($0.id) }
            .sorted { $0.position < $1.position }
            .map { $0.id }

        let request = AudioCastPlayRequest(
            channelId: Int(channelId),
            audiocastIds: sortedIds
        )

        do {
            let response = try await apiClient.playAudioCast(
                subdomain: subdomain,
                certificateHash: certificateHash,
                request: request
            )

            await MainActor.run {
                self.isLoading = false

                if response.success {
                    print("[AudioCastViewModel] Playback started: \(response.playbackId ?? "nil")")
                    self.isPlaying = true
                    self.isPaused = false
                    self.currentPlaybackId = response.playbackId
                    self.startStatusPolling()
                } else {
                    // Handle error
                    let errorMsg = self.parsePlayError(response)
                    self.errorMessage = errorMsg
                }
            }
        } catch {
            print("[AudioCastViewModel] Play failed: \(error)")
            await MainActor.run {
                self.isLoading = false
                self.errorMessage = "Fehler: \(error.localizedDescription)"
            }
        }
    }

    /// Pause or resume playback
    func togglePause() async {
        guard let playbackId = currentPlaybackId else { return }

        guard let subdomain = mumbleService.tenantSubdomain,
              let certificateHash = mumbleService.credentials?.certificateHash else {
            return
        }

        let request = AudioCastPauseRequest(
            channelId: Int(channelId),
            playbackId: playbackId
        )

        do {
            let response = try await apiClient.pauseAudioCast(
                subdomain: subdomain,
                certificateHash: certificateHash,
                request: request
            )

            await MainActor.run {
                if response.success {
                    if let status = response.playbackStatus {
                        self.isPlaying = status.isPlaying
                        self.isPaused = status.isPaused
                        self.playbackStatus = status
                    }
                    print("[AudioCastViewModel] Pause toggled: playing=\(self.isPlaying), paused=\(self.isPaused)")
                } else if response.error == "no_active_playback" {
                    // Playback ended on server - reset state
                    print("[AudioCastViewModel] No active playback, resetting state")
                    self.resetPlaybackState()
                } else {
                    self.errorMessage = response.message
                }
            }
        } catch {
            print("[AudioCastViewModel] Pause failed: \(error)")
            await MainActor.run {
                self.errorMessage = "Fehler: \(error.localizedDescription)"
            }
        }
    }

    /// Stop playback
    func stop() async {
        guard let playbackId = currentPlaybackId else { return }

        guard let subdomain = mumbleService.tenantSubdomain,
              let certificateHash = mumbleService.credentials?.certificateHash else {
            return
        }

        let request = AudioCastStopRequest(
            channelId: Int(channelId),
            playbackId: playbackId
        )

        do {
            let response = try await apiClient.stopAudioCast(
                subdomain: subdomain,
                certificateHash: certificateHash,
                request: request
            )

            await MainActor.run {
                if response.success || response.error == "no_active_playback" {
                    print("[AudioCastViewModel] Playback stopped")
                    self.resetPlaybackState()
                } else {
                    self.errorMessage = response.message
                }
            }
        } catch {
            print("[AudioCastViewModel] Stop failed: \(error)")
            await MainActor.run {
                self.errorMessage = "Fehler: \(error.localizedDescription)"
            }
        }
    }

    /// Clear error message
    func clearError() {
        errorMessage = nil
    }

    // MARK: - Private Methods

    private func startStatusPolling() {
        stopStatusPolling()

        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds

                guard let self = self else { break }
                guard self.isPlaying || self.isPaused else { break }

                await self.refreshPlaybackStatus()
            }
        }
    }

    private func stopStatusPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func refreshPlaybackStatus() async {
        guard let subdomain = mumbleService.tenantSubdomain,
              let certificateHash = mumbleService.credentials?.certificateHash else {
            return
        }

        do {
            let response = try await apiClient.getAudioCastList(
                subdomain: subdomain,
                certificateHash: certificateHash,
                channelId: Int(channelId)
            )

            await MainActor.run {
                let status = response.playbackStatus
                self.playbackStatus = status
                self.isPlaying = status.isPlaying
                self.isPaused = status.isPaused
                self.currentPlaybackId = status.playbackId

                print("[AudioCastViewModel] Status poll: playing=\(status.isPlaying), paused=\(status.isPaused)")

                // Stop polling if playback ended
                if !status.isPlaying && !status.isPaused {
                    self.stopStatusPolling()
                }
            }
        } catch {
            print("[AudioCastViewModel] Status poll failed: \(error)")
        }
    }

    private func resetPlaybackState() {
        stopStatusPolling()
        isPlaying = false
        isPaused = false
        currentPlaybackId = nil
        playbackStatus = nil
    }

    private func parsePlayError(_ response: AudioCastPlayResponse) -> String {
        switch response.error {
        case "bot_busy":
            return "Im Kanal läuft bereits eine Wiedergabe"
        case "permission_denied":
            return "Keine Berechtigung"
        case "bot_error":
            return response.message.isEmpty ? "Bot-Fehler" : response.message
        default:
            return response.message.isEmpty ? "Unbekannter Fehler" : response.message
        }
    }
}
