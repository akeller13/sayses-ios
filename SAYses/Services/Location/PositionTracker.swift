import Foundation
import CoreLocation
import UIKit
import Combine

/// Tracking-Modus mit Frequenz-Einstellungen
enum TrackingMode: Equatable {
    case idle                           // GPS aus
    case background                     // Geschwindigkeitsbasiert (5min - 30sek)
    case active(frequencySeconds: Int)  // Feste Frequenz (z.B. 10s für Alarm)

    var description: String {
        switch self {
        case .idle: return "idle"
        case .background: return "background"
        case .active(let freq): return "active(\(freq)s)"
        }
    }
}

/// State Machine Zustand
enum TrackerState: Equatable {
    case idle
    case tracking
    case sending
    case retrying
}

/// Konfiguration für geschwindigkeitsbasierte Frequenz
struct SpeedBasedFrequency {
    /// Stillstand (< 5 km/h): alle 5 Minuten
    static let standingFrequency: TimeInterval = 300

    /// Langsam/Gehen (5-15 km/h): jede Minute
    static let walkingFrequency: TimeInterval = 60

    /// Schnell/Fahren (> 15 km/h): alle 30 Sekunden
    static let drivingFrequency: TimeInterval = 30

    /// Schwellwerte in m/s
    static let walkingThreshold: Double = 5.0 / 3.6   // 5 km/h
    static let drivingThreshold: Double = 15.0 / 3.6  // 15 km/h

    /// Frequenz basierend auf Geschwindigkeit berechnen
    static func frequency(forSpeed speed: Double) -> TimeInterval {
        if speed < 0 || speed < walkingThreshold {
            return standingFrequency
        } else if speed < drivingThreshold {
            return walkingFrequency
        } else {
            return drivingFrequency
        }
    }
}

/// Konfiguration für PositionTracker
struct PositionTrackerConfig {
    var minDistance: Double? = nil          // Meter (optional)
    var minAngleChange: Double? = nil       // Grad (optional)
    var batchSize: Int = 5                  // Positionen pro Upload
    var retryDelay: TimeInterval = 30       // Sekunden bei Fehler
    var maxRetries: Int = 10                // Max Retry-Versuche
}

/// Einheitlicher GPS-Tracker für Alarme, Dispatcher und allgemeines Tracking
class PositionTracker: ObservableObject {

    // MARK: - Published State

    @Published private(set) var state: TrackerState = .idle
    @Published private(set) var mode: TrackingMode = .idle
    @Published private(set) var pendingCount: Int = 0
    @Published private(set) var lastSendTime: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var currentSpeed: Double = 0  // m/s
    @Published private(set) var effectiveFrequency: TimeInterval = 300

    // MARK: - Dependencies

    private let locationService: LocationService
    private let apiClient: SemparaAPIClient
    private let buffer = PositionBuffer.shared

    // MARK: - Configuration

    private var config = PositionTrackerConfig()
    private var baseMode: TrackingMode = .idle          // User-Einstellung
    private var boostMode: TrackingMode? = nil          // Alarm/Dispatcher Override
    private var activeSessionId: String?
    private var subdomain: String?
    private var certificateHash: String?

    // MARK: - Tracking State

    private var lastPosition: CLLocation?
    private var lastPositionTime: Date?
    private var lastSentPosition: CLLocation?
    private var sendTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var frequencyCheckTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?

    /// Callback for location updates (for UPDATE_ALARM tree messages, local DB updates, etc.)
    /// Called on the main thread when a position passes all filters and is buffered
    private var onLocationUpdate: ((CLLocation, String) -> Void)?

    // MARK: - Init

    init(locationService: LocationService, apiClient: SemparaAPIClient = SemparaAPIClient()) {
        self.locationService = locationService
        self.apiClient = apiClient

        // Clear any stale buffer data from previous app sessions
        Task {
            await clearStaleBufferData()
        }
    }

    /// Clear all buffer data from previous sessions to prevent position floods
    private func clearStaleBufferData() async {
        await buffer.clearAllSessions()
        NSLog("[PositionTracker] Cleared stale buffer data on init")
    }

    // MARK: - Effective Mode

    /// Aktueller effektiver Modus (Boost hat Priorität)
    var effectiveMode: TrackingMode {
        boostMode ?? baseMode
    }

    // MARK: - User Settings

    /// User aktiviert/deaktiviert Standortfreigabe
    func setEnabled(_ enabled: Bool, subdomain: String, certificateHash: String) {
        self.subdomain = subdomain
        self.certificateHash = certificateHash

        if enabled {
            baseMode = .background
            if boostMode == nil {
                startTracking(sessionId: "tracking_\(certificateHash.prefix(8))")
            }
            print("[PositionTracker] Background tracking enabled")
        } else {
            baseMode = .idle
            if boostMode == nil {
                stopTracking()
            }
            print("[PositionTracker] Background tracking disabled")
        }
    }

    /// Prüfen ob Hintergrund-Tracking aktiv ist
    var isBackgroundEnabled: Bool {
        baseMode == .background
    }

    // MARK: - Boost (Alarm/Dispatcher)

    /// Alarm oder Dispatcher aktiviert Boost mit hoher Frequenz
    /// - Parameters:
    ///   - sessionId: Session-ID für GPS-Upload (z.B. "alarm_123" oder "dispatcher_456")
    ///   - frequencySeconds: Tracking-Frequenz in Sekunden (Standard: 10)
    ///   - subdomain: Tenant-Subdomain
    ///   - certificateHash: Benutzer-Zertifikat-Hash
    ///   - onUpdate: Optional callback für jede akzeptierte Position (für UPDATE_ALARM, lokale DB, etc.)
    func boost(sessionId: String, frequencySeconds: Int = 10, subdomain: String, certificateHash: String, onUpdate: ((CLLocation, String) -> Void)? = nil) {
        self.subdomain = subdomain
        self.certificateHash = certificateHash
        self.onLocationUpdate = onUpdate

        // Cancel any pending flush from previous boost to prevent concurrent sends
        flushTask?.cancel()

        let previousBoost = boostMode
        let previousSessionId = activeSessionId
        boostMode = .active(frequencySeconds: frequencySeconds)
        activeSessionId = sessionId

        NSLog("[PositionTracker] Boost activated: session=%@, frequency=%ds, subdomain=%@, previousSession=%@", sessionId, frequencySeconds, subdomain, previousSessionId ?? "nil")
        print("[PositionTracker] Boost activated: session=\(sessionId), frequency=\(frequencySeconds)s")

        // Falls noch nicht tracking, starten
        if state == .idle {
            startTracking(sessionId: sessionId)
        } else if previousBoost == nil {
            // Switching from background to boost - session ID already set above
            // Send current position immediately
            if let location = lastPosition {
                Task {
                    await bufferPosition(location)
                }
            }
        } else if previousSessionId != sessionId {
            // Switching between boost sessions (different alarm) - clear old session buffer
            NSLog("[PositionTracker] Switching boost session from %@ to %@", previousSessionId ?? "nil", sessionId)
            if let oldSession = previousSessionId {
                Task {
                    await buffer.clearAll(sessionId: oldSession)
                    NSLog("[PositionTracker] Cleared old session buffer: %@", oldSession)
                }
            }
            // Send current position for new session
            if let location = lastPosition {
                Task {
                    await bufferPosition(location)
                }
            }
        }

        updateEffectiveFrequency()
    }

    /// Boost beenden (Alarm/Dispatcher abgeschlossen)
    func endBoost() {
        guard boostMode != nil else { return }

        let previousSessionId = activeSessionId
        boostMode = nil
        onLocationUpdate = nil  // Clear callback when boost ends

        // Cancel any previous flush task to prevent concurrent flushes
        flushTask?.cancel()

        NSLog("[PositionTracker] Boost ended, previousSession=%@, baseMode=%@", previousSessionId ?? "nil", baseMode.description)
        print("[PositionTracker] Boost ended")

        // Try to flush remaining positions for the ending boost session
        // Use a tracked task so it can be cancelled if a new boost starts
        if let sessionId = previousSessionId {
            flushTask = Task {
                await flushBuffer(sessionId: sessionId)
            }
        }

        // Zurück zu baseMode
        if baseMode == .background {
            activeSessionId = "tracking_\(certificateHash?.prefix(8) ?? "unknown")"
            updateEffectiveFrequency()
            print("[PositionTracker] Returning to background mode")
        } else {
            stopTracking()
        }
    }

    // MARK: - Internal Tracking Control

    private func startTracking(sessionId: String) {
        guard state == .idle else {
            print("[PositionTracker] Already tracking")
            return
        }

        activeSessionId = sessionId
        state = .tracking
        mode = effectiveMode

        print("[PositionTracker] Starting tracking: session=\(sessionId), mode=\(mode.description)")

        // Location-Updates starten
        locationService.startTracking { [weak self] location in
            self?.handleLocationUpdate(location)
        }

        // Send-Loop starten
        startSendLoop()

        // Frequenz-Check für Background-Mode starten
        if case .background = effectiveMode {
            startFrequencyCheck()
        }

        updateEffectiveFrequency()
    }

    private func stopTracking() {
        guard state != .idle else { return }

        NSLog("[PositionTracker] Stopping tracking, state=%@", String(describing: state))
        print("[PositionTracker] Stopping tracking")

        locationService.stopTracking()
        sendTask?.cancel()
        retryTask?.cancel()
        frequencyCheckTask?.cancel()
        flushTask?.cancel()

        state = .idle
        mode = .idle
        activeSessionId = nil
        lastPosition = nil
        lastPositionTime = nil
        lastSentPosition = nil
    }

    // MARK: - Location Handling

    private func handleLocationUpdate(_ location: CLLocation) {
        guard state == .tracking else { return }

        // Geschwindigkeit aktualisieren
        if location.speed >= 0 {
            currentSpeed = location.speed
        }

        // Frequenz für Background-Modus aktualisieren
        if case .background = effectiveMode {
            updateEffectiveFrequency()
        }

        // Filter: Zeitintervall
        let frequency = currentFrequency()
        if let lastTime = lastPositionTime,
           Date().timeIntervalSince(lastTime) < frequency {
            return
        }

        // Filter: Mindestdistanz (optional)
        if let minDistance = config.minDistance,
           let lastLoc = lastSentPosition,
           location.distance(from: lastLoc) < minDistance {
            return
        }

        // Filter: Mindest-Richtungsänderung (optional)
        if let minAngle = config.minAngleChange,
           let lastLoc = lastSentPosition,
           lastLoc.course >= 0 && location.course >= 0 {
            var angleDiff = abs(location.course - lastLoc.course)
            if angleDiff > 180 {
                angleDiff = 360 - angleDiff
            }
            if angleDiff < minAngle {
                return
            }
        }

        // Position akzeptiert
        lastPosition = location
        lastPositionTime = Date()

        // Callback für externe Nutzung (UPDATE_ALARM, lokale DB, etc.)
        if let callback = onLocationUpdate, let sessionId = activeSessionId {
            DispatchQueue.main.async {
                callback(location, sessionId)
            }
        }

        Task {
            await bufferPosition(location)
        }
    }

    private func bufferPosition(_ location: CLLocation) async {
        guard let sessionId = activeSessionId else { return }

        let positionData = location.toPositionData(
            batteryLevel: getBatteryLevel(),
            batteryCharging: isBatteryCharging()
        )

        await buffer.save(sessionId: sessionId, position: positionData)
        await updatePendingCount()

        NSLog("[PositionTracker] Position buffered: lat=%f, lon=%f, session=%@", location.coordinate.latitude, location.coordinate.longitude, sessionId)
        print("[PositionTracker] Position buffered: \(location.coordinate.latitude), \(location.coordinate.longitude) (speed: \(String(format: "%.1f", location.speed * 3.6)) km/h)")
    }

    // MARK: - Frequency Management

    private func currentFrequency() -> TimeInterval {
        switch effectiveMode {
        case .idle:
            return .infinity
        case .background:
            return SpeedBasedFrequency.frequency(forSpeed: currentSpeed)
        case .active(let seconds):
            return TimeInterval(seconds)
        }
    }

    private func updateEffectiveFrequency() {
        effectiveFrequency = currentFrequency()
    }

    private func startFrequencyCheck() {
        frequencyCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 Sekunden
                guard let self = self, !Task.isCancelled else { break }

                if case .background = self.effectiveMode {
                    await MainActor.run {
                        self.updateEffectiveFrequency()
                    }
                }
            }
        }
    }

    // MARK: - Send Loop

    private func startSendLoop() {
        sendTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self, self.state == .tracking || self.state == .sending else { break }

                await self.sendBatch()

                // Dynamische Wartezeit basierend auf Frequenz
                let waitTime = min(self.currentFrequency(), 30) // Max 30 Sekunden warten
                try? await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
            }
        }
    }

    private func sendBatch() async {
        guard let sessionId = activeSessionId,
              let subdomain = subdomain,
              let certificateHash = certificateHash else {
            NSLog("[PositionTracker] sendBatch: missing params - sessionId=%@, subdomain=%@, certHash=%@",
                  activeSessionId ?? "nil", self.subdomain ?? "nil", self.certificateHash?.prefix(8).description ?? "nil")
            return
        }

        // Positionen aus Buffer holen
        let buffered = await buffer.fetch(sessionId: sessionId, limit: config.batchSize)
        guard !buffered.isEmpty else {
            NSLog("[PositionTracker] sendBatch: buffer empty for session %@", sessionId)
            return
        }

        let positions = buffered.map { $0.toPositionData() }

        await MainActor.run {
            self.state = .sending
        }

        NSLog("[PositionTracker] Sending batch of %d positions for %@", positions.count, sessionId)
        print("[PositionTracker] Sending batch of \(positions.count) positions for \(sessionId)")

        do {
            try await apiClient.uploadGPSPositions(
                subdomain: subdomain,
                certificateHash: certificateHash,
                sessionId: sessionId,
                positions: positions
            )

            // Erfolg: Positionen löschen
            await buffer.delete(buffered)
            await updatePendingCount()

            // Letzte gesendete Position merken
            if let lastBuffered = buffered.last {
                lastSentPosition = CLLocation(
                    latitude: lastBuffered.latitude,
                    longitude: lastBuffered.longitude
                )
            }

            await MainActor.run {
                self.lastSendTime = Date()
                self.lastError = nil
                self.state = .tracking
            }

            NSLog("[PositionTracker] Batch sent successfully")
            print("[PositionTracker] Batch sent successfully")

        } catch {
            NSLog("[PositionTracker] Send failed: %@", error.localizedDescription)
            print("[PositionTracker] Send failed: \(error)")

            await MainActor.run {
                self.lastError = error.localizedDescription
            }

            // Retry nach Verzögerung
            await scheduleRetry()
        }
    }

    private func scheduleRetry() async {
        await MainActor.run {
            self.state = .retrying
        }

        print("[PositionTracker] Retrying in \(config.retryDelay)s")

        retryTask = Task { [weak self] in
            guard let self = self else { return }

            try? await Task.sleep(nanoseconds: UInt64(self.config.retryDelay * 1_000_000_000))

            guard !Task.isCancelled else { return }

            await MainActor.run {
                if self.state == .retrying {
                    self.state = .tracking
                }
            }
        }
    }

    private func flushBuffer(sessionId: String) async {
        // Check for early cancellation
        guard !Task.isCancelled else {
            NSLog("[PositionTracker] flushBuffer: cancelled before start, clearing buffer for %@", sessionId)
            await buffer.clearAll(sessionId: sessionId)
            return
        }

        guard let subdomain = subdomain,
              let certificateHash = certificateHash else {
            NSLog("[PositionTracker] flushBuffer: missing credentials, clearing buffer")
            await buffer.clearAll(sessionId: sessionId)
            return
        }

        var attempts = 0
        while attempts < 3 && !Task.isCancelled {
            let buffered = await buffer.fetch(sessionId: sessionId, limit: config.batchSize)
            if buffered.isEmpty { break }

            let positions = buffered.map { $0.toPositionData() }

            NSLog("[PositionTracker] flushBuffer: sending %d positions for %@", positions.count, sessionId)

            do {
                try await apiClient.uploadGPSPositions(
                    subdomain: subdomain,
                    certificateHash: certificateHash,
                    sessionId: sessionId,
                    positions: positions
                )

                await buffer.delete(buffered)
                NSLog("[PositionTracker] flushBuffer: batch sent successfully")

            } catch {
                NSLog("[PositionTracker] flushBuffer: send failed - %@", error.localizedDescription)
                attempts += 1
                if attempts < 3 && !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000_000) // 5s warten
                }
            }
        }

        // Clear remaining positions (either couldn't send or task was cancelled)
        let remaining = await buffer.count(sessionId: sessionId)
        if remaining > 0 {
            NSLog("[PositionTracker] flushBuffer: clearing %d remaining positions for %@", remaining, sessionId)
            await buffer.clearAll(sessionId: sessionId)
        }
    }

    // MARK: - Helpers

    private func updatePendingCount() async {
        guard let sessionId = activeSessionId else { return }
        let count = await buffer.count(sessionId: sessionId)
        await MainActor.run {
            self.pendingCount = count
        }
    }

    private func getBatteryLevel() -> Int? {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        return level >= 0 ? Int(level * 100) : nil
    }

    private func isBatteryCharging() -> Bool? {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let state = UIDevice.current.batteryState
        return state == .charging || state == .full
    }
}
