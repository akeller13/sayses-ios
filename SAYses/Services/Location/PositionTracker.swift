import Foundation
import CoreLocation
import UIKit
import Combine

/// Explizite GPS-Tracking-Modi
enum TrackingMode: Equatable {
    case idle                              // GPS aus
    case normal                            // Geschwindigkeitsbasiert (Hintergrund-Tracking)
    case dispatcher(frequencySeconds: Int)  // Dispatcher-Request aktiv
    case alarm(frequencySeconds: Int)       // Alarm aktiv

    var description: String {
        switch self {
        case .idle: return "idle"
        case .normal: return "normal"
        case .dispatcher(let freq): return "dispatcher(\(freq)s)"
        case .alarm(let freq): return "alarm(\(freq)s)"
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
    /// Basis-Intervall aus Settings (Standard: 30s)
    /// Stehend = 1x, Gehen = 0.5x, Fahren = 0.25x (min 20s)
    let baseInterval: TimeInterval

    /// Minimum-Intervall in Sekunden
    static let minimumInterval: TimeInterval = 20

    /// Schwellwerte in m/s
    static let walkingThreshold: Double = 5.0 / 3.6   // 5 km/h
    static let drivingThreshold: Double = 15.0 / 3.6  // 15 km/h

    init(baseInterval: TimeInterval = 30) {
        self.baseInterval = baseInterval
    }

    /// Frequenz basierend auf Geschwindigkeit berechnen
    func frequency(forSpeed speed: Double) -> TimeInterval {
        let interval: TimeInterval
        if speed < 0 || speed < SpeedBasedFrequency.walkingThreshold {
            interval = baseInterval * 1.0   // Stillstand: 1x Basis
        } else if speed < SpeedBasedFrequency.drivingThreshold {
            interval = baseInterval * 0.5   // Gehen: 0.5x Basis
        } else {
            interval = baseInterval * 0.25  // Fahren: 0.25x Basis
        }
        return max(interval, SpeedBasedFrequency.minimumInterval)
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
    private var speedFrequency = SpeedBasedFrequency()
    private(set) var backgroundEnabled: Bool = false
    private var activeSessionId: String?
    private var subdomain: String?
    private var certificateHash: String?

    // MARK: - Tracking State

    private var lastPosition: CLLocation?
    private var lastPositionTime: Date?
    private var lastBufferedTime: Date?
    private var lastSentPosition: CLLocation?
    private var sendTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?

    /// Callback for location updates (for UPDATE_ALARM tree messages, local DB updates, etc.)
    private var onLocationUpdate: ((CLLocation, String) -> Void)?

    // MARK: - Init

    init(locationService: LocationService, apiClient: SemparaAPIClient = SemparaAPIClient()) {
        self.locationService = locationService
        self.apiClient = apiClient

        Task {
            await clearStaleBufferData()
        }
    }

    private func clearStaleBufferData() async {
        await buffer.clearAllSessions()
        NSLog("[PositionTracker] Cleared stale buffer data on init")
    }

    // MARK: - Public API

    /// Hintergrund-Tracking aktivieren/deaktivieren (Fleet Tracking)
    /// Aufrufer muss danach reevaluateGPSPriority() aufrufen.
    func setBackgroundEnabled(_ enabled: Bool, subdomain: String, certificateHash: String) {
        self.subdomain = subdomain
        self.certificateHash = certificateHash
        backgroundEnabled = enabled
        NSLog("[PositionTracker] backgroundEnabled = %@", enabled ? "true" : "false")
    }

    /// Basis-Intervall für geschwindigkeitsbasiertes Tracking aktualisieren
    func updateBaseInterval(_ interval: Int) {
        speedFrequency = SpeedBasedFrequency(baseInterval: TimeInterval(interval))
        NSLog("[PositionTracker] Updated base interval to %ds", interval)
    }

    /// Für Abwärtskompatibilität
    var isBackgroundEnabled: Bool {
        backgroundEnabled
    }

    // MARK: - Mode Setters

    /// Alarm-Modus aktivieren (höchste Priorität)
    func setAlarmMode(sessionId: String, frequencySeconds: Int, subdomain: String, certificateHash: String, onUpdate: ((CLLocation, String) -> Void)? = nil) {
        self.subdomain = subdomain
        self.certificateHash = certificateHash
        transitionTo(newMode: .alarm(frequencySeconds: frequencySeconds), sessionId: sessionId, onUpdate: onUpdate)
    }

    /// Dispatcher-Modus aktivieren (mittlere Priorität)
    func setDispatcherMode(sessionId: String, frequencySeconds: Int, subdomain: String, certificateHash: String) {
        self.subdomain = subdomain
        self.certificateHash = certificateHash
        transitionTo(newMode: .dispatcher(frequencySeconds: frequencySeconds), sessionId: sessionId)
    }

    /// Normal-Modus aktivieren (Hintergrund-Tracking, niedrigste Priorität)
    func setNormalMode() {
        guard let hash = certificateHash else {
            NSLog("[PositionTracker] setNormalMode: no certificateHash stored")
            return
        }
        let sessionId = "tracking_\(hash.prefix(8))"
        transitionTo(newMode: .normal, sessionId: sessionId)
    }

    /// Tracking komplett stoppen
    func stopTracking() {
        guard state != .idle else { return }

        NSLog("[PositionTracker] stopTracking: mode=%@, state=%@, session=%@",
              mode.description, String(describing: state), activeSessionId ?? "nil")

        // Flush remaining positions for current session
        let previousSessionId = activeSessionId
        sendTask?.cancel()
        sendTask = nil
        retryTask?.cancel()
        flushTask?.cancel()

        if let sessionId = previousSessionId {
            flushTask = Task { await self.flushBuffer(sessionId: sessionId) }
        }

        locationService.stopContinuousTracking()

        state = .idle
        mode = .idle
        activeSessionId = nil
        onLocationUpdate = nil
        lastPosition = nil
        lastPositionTime = nil
        lastBufferedTime = nil
        lastSentPosition = nil

        NSLog("[PositionTracker] GPS tracking STOPPED")
    }

    // MARK: - Mode Transition

    private func transitionTo(newMode: TrackingMode, sessionId: String, onUpdate: ((CLLocation, String) -> Void)? = nil) {
        // Same mode and same session → no-op (update callback if provided)
        if mode == newMode && activeSessionId == sessionId {
            if let callback = onUpdate {
                self.onLocationUpdate = callback
            }
            return
        }

        let previousMode = mode
        let previousSessionId = activeSessionId

        NSLog("[PositionTracker] Transition: %@ (%@) → %@ (%@)",
              previousMode.description, previousSessionId ?? "nil",
              newMode.description, sessionId)

        // Cancel current send operations
        sendTask?.cancel()
        sendTask = nil
        retryTask?.cancel()
        retryTask = nil

        // Flush remaining positions for old session (if different session)
        if let oldSession = previousSessionId, oldSession != sessionId {
            flushTask?.cancel()
            flushTask = Task { await self.flushBuffer(sessionId: oldSession) }
        }

        // Update mode and session
        mode = newMode
        activeSessionId = sessionId
        lastBufferedTime = nil  // Allow immediate first position for new mode

        // Update callback: use provided callback, or keep existing if same session
        if let callback = onUpdate {
            self.onLocationUpdate = callback
        } else if previousSessionId != sessionId {
            self.onLocationUpdate = nil
        }

        // Start location tracking if not running
        if state == .idle {
            state = .tracking
            locationService.startContinuousTracking { [weak self] location in
                self?.handleLocationUpdate(location)
            }
        } else {
            state = .tracking
        }

        // Start send loop for new session
        startSendLoop()
        updateEffectiveFrequency()
    }

    // MARK: - Continuous Location Updates (iOS Background-compatible)

    private func handleLocationUpdate(_ location: CLLocation) {
        guard state != .idle else { return }

        // Geschwindigkeit aktualisieren für Frequenz-Berechnung (nur bei signifikanter Änderung)
        if location.speed >= 0 {
            let speedDelta = abs(location.speed - currentSpeed)
            if speedDelta > 0.28 {
                DispatchQueue.main.async {
                    self.currentSpeed = location.speed
                    self.updateEffectiveFrequency()
                }
            }
        }

        // Zeit-basiertes Filtern: Nur puffern wenn genug Zeit vergangen ist
        let interval = currentFrequency()
        if let lastTime = lastBufferedTime {
            let elapsed = Date().timeIntervalSince(lastTime)
            if elapsed < interval {
                return
            }
        }

        // Position verarbeiten
        NSLog("[PositionTracker] Processing position: %.6f, %.6f (accuracy: %.1fm, speed: %.1f km/h, mode: %@, interval: %.0fs)",
              location.coordinate.latitude,
              location.coordinate.longitude,
              location.horizontalAccuracy,
              location.speed >= 0 ? location.speed * 3.6 : -1,
              mode.description,
              interval)

        lastPosition = location
        lastPositionTime = Date()
        lastBufferedTime = Date()

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

        NSLog("[PositionTracker] Position buffered: session=%@, mode=%@", sessionId, mode.description)
    }

    // MARK: - Frequency Management

    private func currentFrequency() -> TimeInterval {
        switch mode {
        case .idle:
            return .infinity
        case .normal:
            return speedFrequency.frequency(forSpeed: currentSpeed)
        case .dispatcher(let seconds):
            return TimeInterval(seconds)
        case .alarm(let seconds):
            return TimeInterval(seconds)
        }
    }

    private func updateEffectiveFrequency() {
        effectiveFrequency = currentFrequency()
    }

    // MARK: - Send Loop

    private var sendLoopIteration: Int = 0

    private func startSendLoop() {
        NSLog("[PositionTracker] startSendLoop: mode=%@, state=%@, session=%@",
              mode.description, String(describing: state), activeSessionId ?? "nil")
        sendLoopIteration = 0
        sendTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { break }

                self.sendLoopIteration += 1
                if self.sendLoopIteration % 10 == 1 {
                    let pending = await self.buffer.count(sessionId: self.activeSessionId ?? "")
                    NSLog("[PositionTracker] Send loop heartbeat #%d — mode=%@, session=%@, state=%@, pending=%d, freq=%.0fs",
                          self.sendLoopIteration, self.mode.description,
                          self.activeSessionId ?? "nil", String(describing: self.state),
                          pending, self.currentFrequency())
                }

                await self.sendBatch()

                let waitTime = min(self.currentFrequency(), 30)
                try? await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
            }
            NSLog("[PositionTracker] Send loop EXITED (cancelled=%@)", Task.isCancelled ? "YES" : "NO")
        }
    }

    private func sendBatch() async {
        guard let sessionId = activeSessionId,
              let subdomain = subdomain,
              let certificateHash = certificateHash else {
            return
        }

        let buffered = await buffer.fetch(sessionId: sessionId, limit: config.batchSize)
        guard !buffered.isEmpty else { return }

        let positions = buffered.map { $0.toPositionData() }

        // Check cancellation BEFORE API call (mode transition may have cancelled our task)
        guard !Task.isCancelled else {
            NSLog("[PositionTracker] sendBatch: cancelled, releasing %d positions for flushBuffer", buffered.count)
            await buffer.resetSendingFlag(buffered)
            return
        }

        await MainActor.run {
            self.state = .sending
        }

        NSLog("[PositionTracker] Sending %d positions for %@ (mode=%@)", positions.count, sessionId, mode.description)

        do {
            try await apiClient.uploadGPSPositions(
                subdomain: subdomain,
                certificateHash: certificateHash,
                sessionId: sessionId,
                positions: positions
            )

            await buffer.delete(buffered)
            await updatePendingCount()

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

        } catch {
            // CRITICAL: If our task was cancelled (mode transition), do NOT scheduleRetry!
            // scheduleRetry would set state = .retrying, which kills the NEW send loop.
            if Task.isCancelled {
                NSLog("[PositionTracker] sendBatch: API call cancelled (mode transition), releasing %d positions", buffered.count)
                await buffer.resetSendingFlag(buffered)
                return
            }

            NSLog("[PositionTracker] Send failed: %@", error.localizedDescription)

            // HTTP 404 = session no longer exists on backend → discard positions, don't retry
            if case APIError.httpError(statusCode: 404) = error {
                NSLog("[PositionTracker] 404 — session gone, discarding %d positions", buffered.count)
                await buffer.delete(buffered)
                await MainActor.run {
                    self.lastError = nil
                    self.state = .tracking
                }
                return
            }

            // Transient error → reset flag for retry
            await buffer.resetSendingFlag(buffered)

            await MainActor.run {
                self.lastError = error.localizedDescription
            }

            await scheduleRetry()
        }
    }

    private func scheduleRetry() async {
        // Don't schedule retry if task is cancelled (mode transition happened)
        guard !Task.isCancelled else {
            NSLog("[PositionTracker] scheduleRetry: skipped (task cancelled)")
            return
        }

        await MainActor.run {
            self.state = .retrying
        }

        NSLog("[PositionTracker] scheduleRetry: will retry in %.0fs, session=%@",
              config.retryDelay, activeSessionId ?? "nil")

        retryTask = Task { [weak self] in
            guard let self = self else { return }

            try? await Task.sleep(nanoseconds: UInt64(self.config.retryDelay * 1_000_000_000))

            guard !Task.isCancelled else {
                NSLog("[PositionTracker] scheduleRetry: cancelled during wait")
                return
            }

            await MainActor.run {
                if self.state == .retrying {
                    NSLog("[PositionTracker] scheduleRetry: restarting send loop")
                    self.state = .tracking
                    self.startSendLoop()
                }
            }
        }
    }

    private func flushBuffer(sessionId: String) async {
        guard !Task.isCancelled else {
            NSLog("[PositionTracker] flushBuffer: cancelled, clearing buffer for %@", sessionId)
            await buffer.clearAll(sessionId: sessionId)
            return
        }

        guard let subdomain = subdomain,
              let certificateHash = certificateHash else {
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

                if case APIError.httpError(statusCode: 404) = error {
                    NSLog("[PositionTracker] flushBuffer: 404 — session gone, discarding")
                    await buffer.delete(buffered)
                    break
                }

                await buffer.resetSendingFlag(buffered)
                attempts += 1
                if attempts < 3 && !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
        }

        let remaining = await buffer.count(sessionId: sessionId)
        if remaining > 0 {
            NSLog("[PositionTracker] flushBuffer: clearing %d remaining for %@", remaining, sessionId)
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
