import Foundation
import CoreLocation
import Combine

/// Service for GPS location tracking with warm-up support for quick fixes during alarm
class LocationService: NSObject, ObservableObject {

    // MARK: - Published Properties

    @Published private(set) var currentLocation: CLLocation?
    @Published private(set) var locationError: String?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var isWarmingUp: Bool = false
    @Published private(set) var isTracking: Bool = false

    // MARK: - Private Properties

    private let locationManager = CLLocationManager()
    private var warmUpStartTime: Date?
    private var warmUpLocation: CLLocation?
    private var locationContinuation: CheckedContinuation<CLLocation?, Never>?
    private var trackingCallback: ((CLLocation) -> Void)?
    private var lastTrackedLocation: CLLocation?
    private var lastCallbackTime: Date?  // For throttling callbacks

    /// Maximum age for cached warm-up location (30 seconds)
    private let maxWarmUpAge: TimeInterval = 30

    /// Timeout for single location request (5 seconds)
    private let singleLocationTimeout: TimeInterval = 5

    /// Tracking interval (10 seconds for alarm position updates)
    private let trackingInterval: TimeInterval = 10

    // MARK: - Initialization

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = kCLDistanceFilterNone
        authorizationStatus = locationManager.authorizationStatus
    }

    // MARK: - Authorization

    /// Request location authorization
    func requestAuthorization() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            // Request always authorization for background tracking
            locationManager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    /// Check if location services are available
    var isLocationAvailable: Bool {
        CLLocationManager.locationServicesEnabled() &&
        (authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways)
    }

    /// Check if background tracking is available
    var canTrackInBackground: Bool {
        authorizationStatus == .authorizedAlways
    }

    // MARK: - Warm-up (called when user starts holding alarm button)

    /// Start warming up GPS for quick location fix
    /// Call this when user starts holding the alarm button (Phase 1)
    func warmUp() {
        guard isLocationAvailable else {
            print("[LocationService] warmUp: Location not available")
            return
        }

        guard !isWarmingUp else {
            print("[LocationService] warmUp: Already warming up")
            return
        }

        print("[LocationService] Starting GPS warm-up")
        isWarmingUp = true
        warmUpStartTime = Date()
        warmUpLocation = nil

        // Start location updates to get a fresh fix
        locationManager.startUpdatingLocation()
    }

    /// Stop warming up GPS
    func stopWarmUp() {
        guard isWarmingUp else { return }

        print("[LocationService] Stopping GPS warm-up")
        isWarmingUp = false

        if !isTracking {
            locationManager.stopUpdatingLocation()
        }
    }

    // MARK: - Get Current Location

    /// Get current location with priority strategy:
    /// 1. Cached warm-up location (if < 30 seconds old)
    /// 2. Wait for active warm-up (5 second timeout)
    /// 3. Fresh single location request (5 second timeout)
    /// 4. Last known location as fallback
    func getCurrentLocation() async -> CLLocation? {
        // Strategy 1: Use cached warm-up location if fresh
        if let warmUp = warmUpLocation,
           let startTime = warmUpStartTime,
           Date().timeIntervalSince(startTime) < maxWarmUpAge {
            print("[LocationService] Using cached warm-up location")
            return warmUp
        }

        // Strategy 2: Wait for active warm-up
        if isWarmingUp {
            print("[LocationService] Waiting for warm-up to complete...")
            if let location = await waitForLocation(timeout: singleLocationTimeout) {
                return location
            }
        }

        // Strategy 3: Request fresh location
        print("[LocationService] Requesting fresh location...")
        locationManager.startUpdatingLocation()

        let location = await waitForLocation(timeout: singleLocationTimeout)

        if !isTracking && !isWarmingUp {
            locationManager.stopUpdatingLocation()
        }

        if let location = location {
            return location
        }

        // Strategy 4: Last known location as fallback
        print("[LocationService] Using last known location as fallback")
        return locationManager.location
    }

    /// Wait for a location update with timeout
    private func waitForLocation(timeout: TimeInterval) async -> CLLocation? {
        return await withCheckedContinuation { continuation in
            self.locationContinuation = continuation

            // Set timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                if let cont = self?.locationContinuation {
                    self?.locationContinuation = nil
                    cont.resume(returning: self?.currentLocation)
                }
            }
        }
    }

    // MARK: - Continuous Tracking (for alarm position updates)

    /// Start continuous location tracking for alarm updates
    /// - Parameter callback: Called every 10 seconds with current location (works in background)
    func startTracking(callback: @escaping (CLLocation) -> Void) {
        guard isLocationAvailable else {
            print("[LocationService] startTracking: Location not available")
            return
        }

        guard !isTracking else {
            print("[LocationService] startTracking: Already tracking")
            return
        }

        print("[LocationService] Starting continuous tracking (10 second interval, callback-based)")
        isTracking = true
        trackingCallback = callback
        lastTrackedLocation = currentLocation
        lastCallbackTime = nil  // Reset throttle timer

        // Enable background updates if authorized
        if canTrackInBackground {
            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.pausesLocationUpdatesAutomatically = false
            print("[LocationService] Background location updates enabled")
        } else {
            print("[LocationService] WARNING: Background tracking not authorized (only 'When In Use')")
        }

        locationManager.startUpdatingLocation()

        // Send initial position immediately if available
        if let location = currentLocation {
            print("[LocationService] Sending initial position")
            lastCallbackTime = Date()
            DispatchQueue.main.async {
                callback(location)
            }
        }
    }

    /// Stop continuous location tracking
    func stopTracking() {
        guard isTracking else { return }

        print("[LocationService] Stopping continuous tracking")
        isTracking = false
        trackingCallback = nil
        lastTrackedLocation = nil
        lastCallbackTime = nil

        locationManager.allowsBackgroundLocationUpdates = false
        locationManager.pausesLocationUpdatesAutomatically = true

        if !isWarmingUp {
            locationManager.stopUpdatingLocation()
        }
    }

    // MARK: - Helpers

    /// Get location type string for API
    func getLocationType(for location: CLLocation) -> LocationType {
        // GPS has horizontal accuracy < 65m typically
        // Network/WiFi has accuracy 65m - 100m
        // Cell tower has accuracy > 100m
        if location.horizontalAccuracy < 0 {
            return .unknown
        } else if location.horizontalAccuracy <= 65 {
            return .gps
        } else {
            return .network
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationService: CLLocationManagerDelegate {

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        print("[LocationService] Location update: \(location.coordinate.latitude), \(location.coordinate.longitude) (accuracy: \(location.horizontalAccuracy)m)")

        currentLocation = location

        // Update warm-up location
        if isWarmingUp {
            warmUpLocation = location
        }

        // Tracking: call callback with throttling (every 10 seconds)
        // This works in background because didUpdateLocations is called by iOS even in background
        if isTracking, let callback = trackingCallback {
            lastTrackedLocation = location

            let now = Date()
            let shouldSend = lastCallbackTime == nil || now.timeIntervalSince(lastCallbackTime!) >= trackingInterval

            if shouldSend {
                lastCallbackTime = now
                print("[LocationService] Callback: sending position update (throttled)")
                callback(location)
            }
        }

        // Fulfill waiting continuation
        if let continuation = locationContinuation {
            locationContinuation = nil
            continuation.resume(returning: location)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("[LocationService] Location error: \(error.localizedDescription)")
        locationError = error.localizedDescription

        // Fulfill waiting continuation with nil
        if let continuation = locationContinuation {
            locationContinuation = nil
            continuation.resume(returning: nil)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        print("[LocationService] Authorization changed: \(status.rawValue)")
        authorizationStatus = status

        // If just authorized, request better authorization
        if status == .authorizedWhenInUse {
            // Optionally request always authorization for background tracking
            // locationManager.requestAlwaysAuthorization()
        }
    }
}

// MARK: - Location Extensions

extension CLLocation {
    /// Convert to PositionData for API upload
    func toPositionData(batteryLevel: Int? = nil, batteryCharging: Bool? = nil) -> PositionData {
        return PositionData(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            accuracy: Float(horizontalAccuracy),
            altitude: altitude,
            speed: speed >= 0 ? Float(speed) : nil,
            bearing: course >= 0 ? Float(course) : nil,
            batteryLevel: batteryLevel,
            batteryCharging: batteryCharging,
            recordedAt: Int64(timestamp.timeIntervalSince1970 * 1000)
        )
    }
}
