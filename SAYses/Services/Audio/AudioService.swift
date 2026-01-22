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
    private var playbackCallback: ((UnsafeMutablePointer<Int16>, Int) -> Int)?

    // Level update timer
    private var levelUpdateTimer: Timer?

    init() {
        setupAudioEngine()
    }

    deinit {
        stopCapture()
        stopPlayback()
        levelUpdateTimer?.invalidate()
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
            self.captureCallback?(data, frames)
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
        // Just clear the callback - don't stop the actual capture
        // This allows level monitoring to continue
        captureCallback = nil
        NSLog("[AudioService] Capture callback cleared (capture still running for levels)")
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
        levelUpdateTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self, let engine = self.audioEngine else { return }
            DispatchQueue.main.async {
                self.inputLevel = engine.inputLevel
                self.isVoiceDetected = engine.isVoiceDetected
            }
        }
    }

    private func stopLevelMonitoring() {
        levelUpdateTimer?.invalidate()
        levelUpdateTimer = nil
    }
}
