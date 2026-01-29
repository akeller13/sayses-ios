import Foundation

// MARK: - Alarm Message Types

/// Base protocol for all alarm messages
protocol AlarmMessageProtocol: Codable {
    var type: String { get }
    var id: String { get }
}

// MARK: - START_ALARM

/// Message sent when a user triggers an alarm
/// Sent via Tree Message to tenant channel and to backend API
struct StartAlarmMessage: AlarmMessageProtocol, Codable {
    let type: String
    let id: String
    let userId: UInt32
    let userName: String
    let displayName: String
    let channelId: UInt32
    let channelName: String
    let timestamp: Int64
    let latitude: Double?
    let longitude: Double?
    let locationType: String?

    init(
        id: String = UUID().uuidString,
        userId: UInt32,
        userName: String,
        displayName: String,
        channelId: UInt32,
        channelName: String,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        latitude: Double? = nil,
        longitude: Double? = nil,
        locationType: String? = nil
    ) {
        self.type = "START_ALARM"
        self.id = id
        self.userId = userId
        self.userName = userName
        self.displayName = displayName
        self.channelId = channelId
        self.channelName = channelName
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.locationType = locationType
    }
}

// MARK: - UPDATE_ALARM

/// Message sent to update alarm position or status
/// Sent via Tree Message every 10 seconds during active tracking
struct UpdateAlarmMessage: AlarmMessageProtocol, Codable {
    let type: String
    let id: String
    let latitude: Double?
    let longitude: Double?
    let locationType: String?
    let hasVoiceMessage: Bool?
    let backendAlarmId: String?

    init(
        id: String,
        latitude: Double? = nil,
        longitude: Double? = nil,
        locationType: String? = nil,
        hasVoiceMessage: Bool? = nil,
        backendAlarmId: String? = nil
    ) {
        self.type = "UPDATE_ALARM"
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.locationType = locationType
        self.hasVoiceMessage = hasVoiceMessage
        self.backendAlarmId = backendAlarmId
    }
}

// MARK: - END_ALARM

/// Message sent when an alarm is closed/ended
/// Sent via Tree Message and to backend API
struct EndAlarmMessage: AlarmMessageProtocol, Codable, Equatable {
    let type: String
    let id: String
    let userId: UInt32
    let userName: String
    let displayName: String
    let triggeredByDisplayName: String?
    let closedAt: Int64

    init(
        id: String,
        userId: UInt32,
        userName: String,
        displayName: String,
        triggeredByDisplayName: String? = nil,
        closedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        self.type = "END_ALARM"
        self.id = id
        self.userId = userId
        self.userName = userName
        self.displayName = displayName
        self.triggeredByDisplayName = triggeredByDisplayName
        self.closedAt = closedAt
    }
}

// MARK: - Alarm Message Parser

/// Parser for incoming alarm messages from Tree Messages
enum AlarmMessageParser {

    enum ParsedMessage {
        case startAlarm(StartAlarmMessage)
        case updateAlarm(UpdateAlarmMessage)
        case endAlarm(EndAlarmMessage)
        case unknown(String)
    }

    /// Parse a JSON string into the appropriate alarm message type
    static func parse(_ jsonString: String) -> ParsedMessage? {
        guard let data = jsonString.data(using: .utf8) else {
            return nil
        }

        // First, decode just the type field
        struct TypeWrapper: Codable {
            let type: String
        }

        guard let typeWrapper = try? JSONDecoder().decode(TypeWrapper.self, from: data) else {
            return nil
        }

        let decoder = JSONDecoder()

        switch typeWrapper.type {
        case "START_ALARM":
            if let message = try? decoder.decode(StartAlarmMessage.self, from: data) {
                return .startAlarm(message)
            }
        case "UPDATE_ALARM":
            if let message = try? decoder.decode(UpdateAlarmMessage.self, from: data) {
                return .updateAlarm(message)
            }
        case "END_ALARM":
            if let message = try? decoder.decode(EndAlarmMessage.self, from: data) {
                return .endAlarm(message)
            }
        default:
            return .unknown(typeWrapper.type)
        }

        return nil
    }
}

// MARK: - Location Type

/// Type of location fix
enum LocationType: String, Codable {
    case gps = "gps"
    case network = "network"
    case unknown = "unknown"
}

// MARK: - Position Data (for tracking)

/// Position data point for batch upload to backend
struct PositionData: Codable {
    let latitude: Double
    let longitude: Double
    let accuracy: Float?
    let altitude: Double?
    let speed: Float?
    let bearing: Float?
    let batteryLevel: Int?
    let batteryCharging: Bool?
    let recordedAt: Int64

    enum CodingKeys: String, CodingKey {
        case latitude
        case longitude
        case accuracy
        case altitude
        case speed
        case bearing
        case batteryLevel = "battery_level"
        case batteryCharging = "battery_charging"
        case recordedAt = "recorded_at"
    }
}

/// Request for batch position upload
struct PositionBatchRequest: Codable {
    let positions: [PositionData]
}
