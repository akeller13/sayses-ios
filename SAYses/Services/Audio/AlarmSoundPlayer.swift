import Foundation
import AVFoundation
import AudioToolbox

// MARK: - Alarm Sound Enum

/// Available alarm sounds (matches Android implementation)
enum AlarmSound: String, CaseIterable, Identifiable, Codable {
    case alarm1 = "alarm_1"
    case alarm2 = "alarm_2"
    case alarm3 = "alarm_3"
    case alarm4 = "alarm_4"
    case alarm5 = "alarm_5"
    case alarm6 = "alarm_6"
    case alarm7 = "alarm_7"
    case alarm8 = "alarm_8"
    case alarm9 = "alarm_9"
    case alarm10 = "alarm_10"
    case alarm11 = "alarm_11"
    case alarm12 = "alarm_12"

    var id: String { rawValue }

    /// Display name for UI
    var displayName: String {
        switch self {
        case .alarm1: return "Alarm 1 - Sirene"
        case .alarm2: return "Alarm 2 - Dringend"
        case .alarm3: return "Alarm 3 - Warnung"
        case .alarm4: return "Alarm 4 - Notfall"
        case .alarm5: return "Alarm 5 - Klassisch"
        case .alarm6: return "Alarm 6 - Modern"
        case .alarm7: return "Alarm 7 - Dezent"
        case .alarm8: return "Alarm 8 - Laut"
        case .alarm9: return "Alarm 9 - Schnell"
        case .alarm10: return "Alarm 10 - Langsam"
        case .alarm11: return "Alarm 11 - Digital"
        case .alarm12: return "Alarm 12 - Analog"
        }
    }

    /// File name in bundle (without extension)
    var fileName: String {
        rawValue
    }

    /// System sound ID for fallback (if custom sound not available)
    var systemSoundID: SystemSoundID {
        switch self {
        case .alarm1: return 1005  // SMS Received
        case .alarm2: return 1007  // SMS Received 2
        case .alarm3: return 1023  // New Mail
        case .alarm4: return 1304  // Alarm
        case .alarm5: return 1306  // Anticipate
        case .alarm6: return 1307  // Bloom
        case .alarm7: return 1308  // Calypso
        case .alarm8: return 1309  // Choo Choo
        case .alarm9: return 1310  // Descent
        case .alarm10: return 1311 // Fanfare
        case .alarm11: return 1312 // Ladder
        case .alarm12: return 1313 // Minuet
        }
    }

    /// Default alarm sound
    static let defaultSound: AlarmSound = .alarm1
}

// MARK: - Alarm Sound Player

/// Plays alarm sounds with the specified pattern:
/// - 8 seconds sound, 8 seconds pause
/// - Repeat 4 times
/// - Then 60 seconds pause before repeating the whole cycle
class AlarmSoundPlayer: ObservableObject {

    // MARK: - Constants

    /// Duration of alarm sound in seconds
    private let soundDuration: TimeInterval = 8.0

    /// Duration of pause between sounds in seconds
    private let pauseDuration: TimeInterval = 8.0

    /// Number of repetitions before long pause
    private let repetitionsBeforeLongPause: Int = 4

    /// Duration of long pause in seconds
    private let longPauseDuration: TimeInterval = 60.0

    // MARK: - Published Properties

    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var currentSound: AlarmSound?

    // MARK: - Private Properties

    private var audioPlayer: AVAudioPlayer?
    private var playbackTask: Task<Void, Never>?
    private var repetitionCount: Int = 0
    private var isPreviewMode: Bool = false

    // MARK: - Singleton

    static let shared = AlarmSoundPlayer()

    private init() {}

    // MARK: - Public Methods

    /// Start playing alarm sound with pattern
    func startAlarm(sound: AlarmSound = .defaultSound) {
        guard !isPlaying else { return }

        print("[AlarmSoundPlayer] Starting alarm: \(sound.displayName)")

        currentSound = sound
        isPlaying = true
        isPreviewMode = false
        repetitionCount = 0

        // Configure audio session for alarm
        configureAudioSession()

        // Start playback loop
        playbackTask = Task { [weak self] in
            await self?.playbackLoop(sound: sound)
        }
    }

    /// Stop alarm sound
    func stopAlarm() {
        guard isPlaying else { return }

        print("[AlarmSoundPlayer] Stopping alarm")

        playbackTask?.cancel()
        playbackTask = nil
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        currentSound = nil
        repetitionCount = 0

        // Restore audio session (without duckOthers, keep .playAndRecord)
        restoreAudioSession()
    }

    /// Play sound once for preview (in settings)
    func playPreview(sound: AlarmSound) {
        // Stop any existing playback
        stopAlarm()

        print("[AlarmSoundPlayer] Playing preview: \(sound.displayName)")

        currentSound = sound
        isPlaying = true
        isPreviewMode = true

        configureAudioSession()
        playSound(sound)

        // Auto-stop after sound duration
        playbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(self?.soundDuration ?? 8.0) * 1_000_000_000)
            await MainActor.run {
                if self?.isPreviewMode == true {
                    self?.stopAlarm()
                }
            }
        }
    }

    /// Stop preview if playing
    func stopPreview() {
        if isPreviewMode {
            stopAlarm()
        }
    }

    // MARK: - Private Methods

    private func playbackLoop(sound: AlarmSound) async {
        while !Task.isCancelled && isPlaying {
            // Play sound
            await MainActor.run {
                playSound(sound)
            }

            // Wait for sound duration
            try? await Task.sleep(nanoseconds: UInt64(soundDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }

            // Stop sound
            await MainActor.run {
                audioPlayer?.stop()
            }

            repetitionCount += 1

            // Check if we need long pause
            if repetitionCount >= repetitionsBeforeLongPause {
                repetitionCount = 0
                print("[AlarmSoundPlayer] Long pause (60s)")
                try? await Task.sleep(nanoseconds: UInt64(longPauseDuration * 1_000_000_000))
            } else {
                // Short pause
                print("[AlarmSoundPlayer] Short pause (8s), repetition \(repetitionCount)/\(repetitionsBeforeLongPause)")
                try? await Task.sleep(nanoseconds: UInt64(pauseDuration * 1_000_000_000))
            }
        }
    }

    private func playSound(_ sound: AlarmSound) {
        // Try to load custom sound from bundle
        if let url = Bundle.main.url(forResource: sound.fileName, withExtension: "mp3") ??
                     Bundle.main.url(forResource: sound.fileName, withExtension: "m4a") ??
                     Bundle.main.url(forResource: sound.fileName, withExtension: "wav") {
            do {
                audioPlayer = try AVAudioPlayer(contentsOf: url)
                audioPlayer?.numberOfLoops = -1  // Loop indefinitely (we control duration)
                audioPlayer?.volume = 1.0
                audioPlayer?.play()
                print("[AlarmSoundPlayer] Playing custom sound: \(url.lastPathComponent)")
                return
            } catch {
                print("[AlarmSoundPlayer] Failed to play custom sound: \(error)")
            }
        }

        // Fallback to system sound
        print("[AlarmSoundPlayer] Using system sound fallback: \(sound.systemSoundID)")
        playSystemSoundLoop(soundID: sound.systemSoundID)
    }

    private var systemSoundTimer: Timer?
    private var systemSoundStartTime: Date?

    private func playSystemSoundLoop(soundID: SystemSoundID) {
        // Play system sound repeatedly for the duration
        systemSoundStartTime = Date()

        // Play immediately
        AudioServicesPlaySystemSound(soundID)

        // Schedule repeated plays
        systemSoundTimer?.invalidate()
        systemSoundTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard let self = self,
                  self.isPlaying,
                  let startTime = self.systemSoundStartTime,
                  Date().timeIntervalSince(startTime) < self.soundDuration else {
                timer.invalidate()
                return
            }
            AudioServicesPlaySystemSound(soundID)
        }
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            // Keep .playAndRecord to not break audio capture — just add .duckOthers
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth, .duckOthers])
            try session.setActive(true)
            // setCategory() resets the output port override — re-apply only if no headset
            try session.enforceSpeakerIfNoExternalOutput()
            print("[AlarmSoundPlayer] Audio session configured (playAndRecord preserved)")
        } catch {
            print("[AlarmSoundPlayer] Failed to configure audio session: \(error)")
        }
    }

    private func restoreAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            // Restore original session without duckOthers
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            // setCategory() resets the output port override — re-apply only if no headset
            try session.enforceSpeakerIfNoExternalOutput()
            print("[AlarmSoundPlayer] Audio session restored")
        } catch {
            print("[AlarmSoundPlayer] Failed to restore audio session: \(error)")
        }
    }
}

// MARK: - User Defaults Extension

extension UserDefaults {
    private static let selectedAlarmSoundKey = "selectedAlarmSound"

    var selectedAlarmSound: AlarmSound {
        get {
            if let rawValue = string(forKey: Self.selectedAlarmSoundKey),
               let sound = AlarmSound(rawValue: rawValue) {
                return sound
            }
            return .defaultSound
        }
        set {
            set(newValue.rawValue, forKey: Self.selectedAlarmSoundKey)
        }
    }
}
