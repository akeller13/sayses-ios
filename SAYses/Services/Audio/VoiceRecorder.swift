import Foundation
import AVFoundation
import Combine

/// Voice recorder for alarm voice messages
/// Records AAC audio in M4A container (44.1kHz, 128kbps)
class VoiceRecorder: NSObject, ObservableObject {

    // MARK: - Published Properties

    @Published private(set) var isRecording: Bool = false
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var recordingError: String?

    // MARK: - Private Properties

    private var audioRecorder: AVAudioRecorder?
    private var recordingTimer: Timer?
    private var currentFilePath: URL?
    private var lastCompletedFilePath: URL?  // Preserved after recording stops

    /// Maximum recording duration (from backend settings, default 20 seconds)
    var maxDuration: TimeInterval = 20

    /// Recording settings (AAC, 44.1kHz, 128kbps)
    private let recordingSettings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 44100,
        AVNumberOfChannelsKey: 1,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        AVEncoderBitRateKey: 128000
    ]

    // MARK: - Initialization

    override init() {
        super.init()
    }

    // MARK: - Recording Control

    /// Start recording a voice message
    /// - Returns: Path to the recording file, or nil if failed
    @discardableResult
    func startRecording() -> URL? {
        print("[VoiceRecorder] startRecording() called")
        print("[VoiceRecorder]   maxDuration = \(maxDuration)")
        print("[VoiceRecorder]   isRecording = \(isRecording)")

        guard !isRecording else {
            print("[VoiceRecorder] Already recording - returning currentFilePath")
            return currentFilePath
        }

        // Clear any previous completed file path
        lastCompletedFilePath = nil

        // NOTE: Audio session is already configured and active via AppDelegate (.playAndRecord, .voiceChat).
        // Do NOT reconfigure or deactivate it here — it would kill Mumble audio.

        // Create file path in cache directory
        let fileName = "alarm_voice_\(UUID().uuidString).m4a"
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let filePath = cacheDir.appendingPathComponent(fileName)
        currentFilePath = filePath

        print("[VoiceRecorder]   filePath = \(filePath.lastPathComponent)")

        // Create recorder
        do {
            audioRecorder = try AVAudioRecorder(url: filePath, settings: recordingSettings)
            audioRecorder?.delegate = self
            audioRecorder?.isMeteringEnabled = true

            print("[VoiceRecorder]   AVAudioRecorder created")

            guard audioRecorder?.prepareToRecord() == true else {
                print("[VoiceRecorder] Failed to prepare recorder")
                recordingError = "Aufnahme konnte nicht vorbereitet werden"
                return nil
            }

            print("[VoiceRecorder]   prepareToRecord() succeeded")

            guard audioRecorder?.record() == true else {
                print("[VoiceRecorder] Failed to start recording")
                recordingError = "Aufnahme konnte nicht gestartet werden"
                return nil
            }

            print("[VoiceRecorder]   record() succeeded")

            isRecording = true
            recordingDuration = 0
            recordingError = nil

            print("[VoiceRecorder] Started recording to: \(filePath.lastPathComponent)")

            // Start timer to track duration and enforce max duration
            startTimer()
            print("[VoiceRecorder]   Timer started")

            return filePath

        } catch {
            print("[VoiceRecorder] Failed to create recorder: \(error)")
            recordingError = "Aufnahme konnte nicht gestartet werden: \(error.localizedDescription)"
            return nil
        }
    }

    /// Stop recording and return the file path
    /// - Returns: Path to the completed recording, or nil if no recording exists
    @discardableResult
    func stopRecording() -> URL? {
        // If still recording, stop it
        if isRecording, let recorder = audioRecorder {
            stopTimer()
            recorder.stop()
            isRecording = false

            // Save as last completed file before clearing
            lastCompletedFilePath = currentFilePath

            print("[VoiceRecorder] Stopped recording. Duration: \(recordingDuration)s, Path: \(currentFilePath?.lastPathComponent ?? "nil")")

            // NOTE: Do NOT deactivate audio session — Mumble audio needs it active.

            let filePath = currentFilePath
            currentFilePath = nil
            return filePath
        } else {
            // Not actively recording - return last completed file (from auto-stop due to max duration)
            print("[VoiceRecorder] Not actively recording, returning last completed file: \(lastCompletedFilePath?.lastPathComponent ?? "nil")")
            let filePath = lastCompletedFilePath
            lastCompletedFilePath = nil  // Clear after returning
            return filePath
        }
    }

    /// Cancel recording and delete the file
    func cancelRecording() {
        guard isRecording else { return }

        stopTimer()
        audioRecorder?.stop()
        isRecording = false

        // Delete the file
        if let filePath = currentFilePath {
            try? FileManager.default.removeItem(at: filePath)
            print("[VoiceRecorder] Cancelled and deleted: \(filePath.lastPathComponent)")
        }

        currentFilePath = nil
        lastCompletedFilePath = nil  // Also clear last completed
        recordingDuration = 0

        // NOTE: Do NOT deactivate audio session — Mumble audio needs it active.
    }

    // MARK: - Timer

    private func startTimer() {
        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.updateDuration()
        }
    }

    private func stopTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }

    private func updateDuration() {
        guard let recorder = audioRecorder, isRecording else {
            print("[VoiceRecorder] updateDuration: guard failed - recorder=\(audioRecorder != nil), isRecording=\(isRecording)")
            return
        }

        let prevDuration = recordingDuration
        recordingDuration = recorder.currentTime

        // Log first few updates to see what's happening
        if prevDuration == 0 || recordingDuration < 1.0 {
            print("[VoiceRecorder] updateDuration: \(recordingDuration)s / \(maxDuration)s")
        }

        // Enforce max duration
        if recordingDuration >= maxDuration {
            print("[VoiceRecorder] Max duration reached (\(maxDuration)s), stopping")
            stopRecording()
        }
    }

    // MARK: - File Management

    /// Delete a voice message file
    func deleteFile(at path: URL) {
        do {
            try FileManager.default.removeItem(at: path)
            print("[VoiceRecorder] Deleted file: \(path.lastPathComponent)")
        } catch {
            print("[VoiceRecorder] Failed to delete file: \(error)")
        }
    }

    /// Get file size in bytes
    func getFileSize(at path: URL) -> Int64? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
            return attributes[.size] as? Int64
        } catch {
            return nil
        }
    }

    /// Check if a voice file exists
    func fileExists(at path: URL) -> Bool {
        FileManager.default.fileExists(atPath: path.path)
    }
}

// MARK: - AVAudioRecorderDelegate

extension VoiceRecorder: AVAudioRecorderDelegate {

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        print("[VoiceRecorder] Recording finished. Success: \(flag)")

        if !flag {
            recordingError = "Aufnahme wurde unterbrochen"
            // Delete incomplete file
            if let filePath = currentFilePath {
                try? FileManager.default.removeItem(at: filePath)
            }
            currentFilePath = nil
        }

        isRecording = false
        stopTimer()
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        print("[VoiceRecorder] Encoding error: \(error?.localizedDescription ?? "unknown")")
        recordingError = "Aufnahme-Fehler: \(error?.localizedDescription ?? "Unbekannt")"
        isRecording = false
        stopTimer()
    }
}

// MARK: - Voice Playback

/// Simple voice message player
class VoicePlayer: NSObject, ObservableObject {

    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    private var audioPlayer: AVAudioPlayer?
    private var playbackTimer: Timer?

    /// Play a voice message from file
    func play(from url: URL) {
        stop()

        do {
            print("[VoicePlayer] Attempting to play: \(url.path)")
            print("[VoicePlayer] File exists: \(FileManager.default.fileExists(atPath: url.path))")

            // Check file size
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int64 {
                print("[VoicePlayer] File size: \(size) bytes")
            }

            // NOTE: Audio session is already configured and active via AppDelegate.
            // Do NOT reconfigure category or deactivate — it would kill Mumble audio.
            // But we DO need to switch from .voiceChat mode to .default mode temporarily,
            // because .voiceChat mode routes audio to receiver (earpiece) for telephony.
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setMode(.default)
                print("[VoicePlayer] Audio mode set to .default")

                // Check if headset is connected - if not, force speaker output
                // (setMode(.voiceChat) may have set route to receiver)
                let outputs = session.currentRoute.outputs
                let hasExternalOutput = outputs.contains { port in
                    port.portType == .headphones ||
                    port.portType == .bluetoothA2DP ||
                    port.portType == .bluetoothHFP ||
                    port.portType == .bluetoothLE ||
                    port.portType == .carAudio ||
                    port.portType == .airPlay
                }

                if !hasExternalOutput {
                    try session.overrideOutputAudioPort(.speaker)
                    print("[VoicePlayer] No headset detected, routing to speaker")
                } else {
                    print("[VoicePlayer] External output detected, using current route")
                }
            } catch {
                print("[VoicePlayer] Failed to configure audio for playback: \(error)")
            }

            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.delegate = self
            duration = audioPlayer?.duration ?? 0

            print("[VoicePlayer] Duration: \(duration) seconds")
            print("[VoicePlayer] Format: \(audioPlayer?.format.description ?? "unknown")")

            let success = audioPlayer?.play() ?? false
            print("[VoicePlayer] play() returned: \(success)")
            isPlaying = true

            startTimer()
            print("[VoicePlayer] Playing: \(url.lastPathComponent)")

        } catch {
            print("[VoicePlayer] Failed to play: \(error)")
        }
    }

    /// Stop playback
    func stop() {
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        currentTime = 0
        stopTimer()

        // Restore .voiceChat mode for Mumble audio
        restoreVoiceChatMode()
    }

    /// Restore audio session to .voiceChat mode for Mumble
    private func restoreVoiceChatMode() {
        do {
            try AVAudioSession.sharedInstance().setMode(.voiceChat)
            print("[VoicePlayer] Audio mode restored to .voiceChat")
        } catch {
            print("[VoicePlayer] Failed to restore audio mode: \(error)")
        }
    }

    /// Toggle play/stop
    func toggle(url: URL) {
        if isPlaying {
            stop()
        } else {
            play(from: url)
        }
    }

    private func startTimer() {
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.currentTime = self?.audioPlayer?.currentTime ?? 0
        }
    }

    private func stopTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }
}

extension VoicePlayer: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        print("[VoicePlayer] audioPlayerDidFinishPlaying - successfully: \(flag)")
        isPlaying = false
        currentTime = 0
        stopTimer()

        // Restore .voiceChat mode for Mumble audio
        restoreVoiceChatMode()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        print("[VoicePlayer] audioPlayerDecodeErrorDidOccur: \(error?.localizedDescription ?? "unknown")")
        isPlaying = false
        currentTime = 0
        stopTimer()
    }
}
