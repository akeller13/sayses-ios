import Foundation
import Combine

/// Service that provides audio capture and playback using native C++ AudioEngine
class AudioService: ObservableObject {
    @Published private(set) var isCapturing = false
    @Published private(set) var isPlaying = false
    @Published private(set) var isVoiceDetected = false
    @Published private(set) var inputLevel: Float = 0

    // C++ Audio Engine Bridge
    private var audioEngine: AudioEngineBridge?

    // Audio format settings (matching Opus requirements)
    private let sampleRate: Int32 = 48000
    private let channels: Int32 = 1
    private let frameSize: Int32 = 480  // 10ms at 48kHz

    // Callbacks
    private var captureCallback: ((UnsafePointer<Int16>, Int) -> Void)?
    private var captureCallbackInvocations: Int = 0
    private var playbackCallback: ((UnsafeMutablePointer<Int16>, Int) -> Int)?

    // Level monitoring task
    private var levelMonitorTask: Task<Void, Never>?

    init() {
        setupAudioEngine()
        setupInterruptionHandler()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        stopCapture()
        stopPlayback()
        levelMonitorTask?.cancel()
    }

    private func setupInterruptionHandler() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioInterruptionEnded),
            name: .audioSessionInterruptionEnded,
            object: nil
        )
    }

    @objc private func handleAudioInterruptionEnded() {
        NSLog("[AudioService] Audio interruption ended - restarting audio engine")

        // Ensure all work happens on main thread for thread safety
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Recreate the audio engine (Audio Units need to be restarted after interruption)
            let wasCapturing = self.isCapturing
            let wasPlaying = self.isPlaying
            let savedCaptureCallback = self.captureCallback

            // Stop everything first
            if wasCapturing {
                self.audioEngine?.stopCapture()
            }
            if wasPlaying {
                self.audioEngine?.stopPlayback()
            }

            // Recreate the audio engine
            self.audioEngine = nil
            self.setupAudioEngine()

            // Restart capture if it was running
            if wasCapturing, let callback = savedCaptureCallback {
                NSLog("[AudioService] Restarting capture after interruption")
                self.isCapturing = false  // Reset state so startCapture works
                self.captureCallback = callback
                self.restartCaptureInternal()
            }

            // Restart playback if it was running
            if wasPlaying {
                NSLog("[AudioService] Restarting playback after interruption")
                self.isPlaying = false  // Reset state so startPlayback works
                _ = self.startMixedPlayback()
            }
        }
    }

    private func restartCaptureInternal() {
        guard let engine = audioEngine, let callback = captureCallback else {
            NSLog("[AudioService] Cannot restart capture - no engine or callback")
            return
        }

        let success = engine.startCapture { [weak self] data, frames in
            guard let self = self else { return }
            self.captureCallback?(data, frames)
        }

        if success {
            self.isCapturing = true
            startLevelMonitoring()
            NSLog("[AudioService] Capture restarted successfully")
        } else {
            NSLog("[AudioService] Failed to restart capture")
        }
    }

    private func setupAudioEngine() {
        audioEngine = AudioEngineBridge(
            sampleRate: sampleRate,
            channels: channels,
            framesPerBuffer: frameSize
        )

        if audioEngine == nil {
            NSLog("[AudioService] ERROR: Failed to create AudioEngineBridge")
        } else {
            NSLog("[AudioService] AudioEngineBridge created successfully")
        }
    }

    // MARK: - Capture

    func startCapture(callback: @escaping (UnsafePointer<Int16>, Int) -> Void) {
        NSLog("[AudioService] startCapture called, isCapturing=\(isCapturing)")

        // Store the callback - this is called for each audio buffer
        captureCallback = callback

        // If already capturing, just update the callback (it will be used by existing capture)
        if isCapturing {
            NSLog("[AudioService] Already capturing - callback updated")
            return
        }

        guard let engine = audioEngine else {
            NSLog("[AudioService] ERROR: No audio engine available")
            return
        }

        let success = engine.startCapture { [weak self] data, frames in
            guard let self = self else { return }
            // Call the current callback (may be updated later)
            if self.captureCallback != nil {
                self.captureCallbackInvocations += 1
                if self.captureCallbackInvocations % 500 == 1 {
                    NSLog("[AudioService] C++ callback → captureCallback (invocation #%d, frames=%d)", self.captureCallbackInvocations, frames)
                }
                self.captureCallback?(data, frames)
            } else {
                // Log occasionally when callback is nil (PTT not pressed)
                self.captureCallbackInvocations += 1
                if self.captureCallbackInvocations % 5000 == 1 {
                    NSLog("[AudioService] C++ callback fired but captureCallback is nil (invocation #%d)", self.captureCallbackInvocations)
                }
            }
        }

        if success {
            DispatchQueue.main.async {
                self.isCapturing = true
            }
            startLevelMonitoring()
            NSLog("[AudioService] C++ capture started")
        } else {
            NSLog("[AudioService] Failed to start C++ capture")
        }
    }

    func stopCapture() {
        // Clear the callback but keep the C++ engine running for level monitoring
        // IMPORTANT: isCapturing stays true so next startCapture() just updates the callback
        // The C++ engine closure reads self.captureCallback dynamically, so updating
        // captureCallback is sufficient - no need to restart the C++ engine
        captureCallback = nil
        NSLog("[AudioService] Capture callback cleared (C++ engine continues for levels)")
    }

    /// Fully stop capture including level monitoring
    func stopCaptureCompletely() {
        guard isCapturing else { return }

        audioEngine?.stopCapture()
        stopLevelMonitoring()

        DispatchQueue.main.async {
            self.isCapturing = false
            self.inputLevel = 0
            self.isVoiceDetected = false
        }
        captureCallback = nil
        NSLog("[AudioService] Capture stopped completely")
    }

    // MARK: - Playback

    func startPlayback(callback: @escaping (UnsafeMutablePointer<Int16>, Int) -> Int) {
        guard !isPlaying else { return }

        guard let engine = audioEngine else {
            NSLog("[AudioService] ERROR: No audio engine for playback")
            return
        }

        playbackCallback = callback

        let success = engine.startPlayback { [weak self] data, frames -> Int in
            guard let self = self else { return 0 }
            return callback(data, frames)
        }

        if success {
            DispatchQueue.main.async {
                self.isPlaying = true
            }
            NSLog("[AudioService] C++ playback started")
        } else {
            NSLog("[AudioService] Failed to start C++ playback")
        }
    }

    func stopPlayback() {
        guard isPlaying else { return }

        audioEngine?.stopPlayback()

        DispatchQueue.main.async {
            self.isPlaying = false
        }
        playbackCallback = nil
        NSLog("[AudioService] Playback stopped")
    }

    // MARK: - VAD

    func setVadEnabled(_ enabled: Bool) {
        audioEngine?.setVadEnabled(enabled)
        NSLog("[AudioService] VAD enabled: \(enabled)")
    }

    func setVadThreshold(_ threshold: Float) {
        audioEngine?.setVadThreshold(threshold)
        NSLog("[AudioService] VAD threshold: \(threshold)")
    }

    // MARK: - User Audio Management (C++ Engine)

    /// Add decoded audio for a user (uses C++ per-user buffers with float mixing)
    func addUserAudio(userId: UInt32, samples: UnsafePointer<Int16>, frames: Int, sequence: Int64) {
        audioEngine?.addUserAudio(userId, samples: samples, frames: frames, sequence: sequence)
    }

    /// Remove user's audio buffer
    func removeUser(_ userId: UInt32) {
        audioEngine?.removeUser(userId)
        NSLog("[AudioService] Removed user \(userId)")
    }

    /// Notify that user stopped talking (triggers crossfade)
    func notifyUserTalkingEnded(_ userId: UInt32) {
        audioEngine?.notifyUserTalkingEnded(userId)
    }

    /// Start playback using internal C++ user mixing
    func startMixedPlayback() -> Bool {
        guard let engine = audioEngine else {
            NSLog("[AudioService] ERROR: No audio engine for mixed playback")
            return false
        }

        let success = engine.startMixedPlayback()
        if success {
            DispatchQueue.main.async {
                self.isPlaying = true
            }
            NSLog("[AudioService] C++ mixed playback started")
        } else {
            NSLog("[AudioService] Failed to start C++ mixed playback")
        }
        return success
    }

    // MARK: - Level Monitoring

    private func startLevelMonitoring() {
        levelMonitorTask?.cancel()
        levelMonitorTask = Task { [weak self] in
            var lastLevel: Float = -1
            var lastVoiceDetected: Bool? = nil

            while !Task.isCancelled {
                guard let self = self, let engine = self.audioEngine else { return }

                let level = engine.inputLevel
                let voiceDetected = engine.isVoiceDetected

                // Only update UI when values change significantly (reduces main thread load)
                let levelChanged = abs(level - lastLevel) > 0.02  // 2% threshold
                let voiceChanged = lastVoiceDetected != voiceDetected

                if levelChanged || voiceChanged {
                    lastLevel = level
                    lastVoiceDetected = voiceDetected

                    await MainActor.run {
                        self.inputLevel = level
                        self.isVoiceDetected = voiceDetected
                    }
                }

                // 100ms interval (reduced from 50ms - still responsive but less CPU load)
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func stopLevelMonitoring() {
        levelMonitorTask?.cancel()
        levelMonitorTask = nil
    }
}
