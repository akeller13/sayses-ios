import Foundation
import SwiftData

/// Gepufferte GPS-Position für Offline-Speicherung
@Model
final class BufferedPosition {
    var id: UUID
    var sessionId: String
    var latitude: Double
    var longitude: Double
    var accuracy: Float?
    var altitude: Double?
    var speed: Float?
    var bearing: Float?
    var batteryLevel: Int?
    var batteryCharging: Bool?
    var recordedAt: Int64
    var createdAt: Date
    var retryCount: Int

    init(sessionId: String, position: PositionData) {
        self.id = UUID()
        self.sessionId = sessionId
        self.latitude = position.latitude
        self.longitude = position.longitude
        self.accuracy = position.accuracy
        self.altitude = position.altitude
        self.speed = position.speed
        self.bearing = position.bearing
        self.batteryLevel = position.batteryLevel
        self.batteryCharging = position.batteryCharging
        self.recordedAt = position.recordedAt
        self.createdAt = Date()
        self.retryCount = 0
    }

    func toPositionData() -> PositionData {
        PositionData(
            latitude: latitude,
            longitude: longitude,
            accuracy: accuracy,
            altitude: altitude,
            speed: speed,
            bearing: bearing,
            batteryLevel: batteryLevel,
            batteryCharging: batteryCharging,
            recordedAt: recordedAt
        )
    }
}
