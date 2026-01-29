import Foundation
import SwiftData

/// Persistent storage for alarm data
/// Matches Android AlarmEntity schema for consistency
@Model
final class AlarmEntity {

    // MARK: - IDs

    /// UUID from START_ALARM message (primary identifier)
    @Attribute(.unique)
    var alarmId: String

    /// ID from backend API (for API calls like voice upload)
    var backendAlarmId: String?

    // MARK: - Timestamps

    /// When the alarm was received locally
    var receivedAt: Date

    /// When the alarm was closed (nil = still open)
    var closedAt: Date?

    // MARK: - User Info

    /// Username of the person who triggered the alarm
    var triggeredByUsername: String

    /// Display name of the person who triggered the alarm
    var triggeredByDisplayName: String?

    /// User ID (session) of the person who triggered the alarm
    var triggeredByUserId: UInt32

    // MARK: - Channel Info

    /// Channel ID where the alarm was triggered
    var channelId: UInt32

    /// Channel name where the alarm was triggered
    var channelName: String

    // MARK: - Location

    /// Latitude of the alarm location
    var latitude: Double?

    /// Longitude of the alarm location
    var longitude: Double?

    /// Type of location fix: "gps", "network", or "unknown"
    var locationType: String?

    /// When the location was last updated
    var locationUpdatedAt: Date?

    // MARK: - Voice Message

    /// Local path to voice message file
    var voiceMessagePath: String?

    /// Whether the voice message has been uploaded to backend
    var voiceMessageUploaded: Bool

    /// Whether a voice message exists on the backend (for received alarms)
    var hasRemoteVoiceMessage: Bool

    // MARK: - Computed Properties

    /// Whether the alarm is still open
    var isOpen: Bool {
        closedAt == nil
    }

    /// Effective display name (display name or username)
    var effectiveName: String {
        triggeredByDisplayName ?? triggeredByUsername
    }

    /// Whether location data is available
    var hasLocation: Bool {
        latitude != nil && longitude != nil
    }

    /// Whether any voice message is available (local or remote)
    var hasVoiceMessage: Bool {
        voiceMessagePath != nil || hasRemoteVoiceMessage
    }

    // MARK: - Initialization

    init(
        alarmId: String,
        backendAlarmId: String? = nil,
        receivedAt: Date = Date(),
        closedAt: Date? = nil,
        triggeredByUsername: String,
        triggeredByDisplayName: String? = nil,
        triggeredByUserId: UInt32,
        channelId: UInt32,
        channelName: String,
        latitude: Double? = nil,
        longitude: Double? = nil,
        locationType: String? = nil,
        locationUpdatedAt: Date? = nil,
        voiceMessagePath: String? = nil,
        voiceMessageUploaded: Bool = false,
        hasRemoteVoiceMessage: Bool = false
    ) {
        self.alarmId = alarmId
        self.backendAlarmId = backendAlarmId
        self.receivedAt = receivedAt
        self.closedAt = closedAt
        self.triggeredByUsername = triggeredByUsername
        self.triggeredByDisplayName = triggeredByDisplayName
        self.triggeredByUserId = triggeredByUserId
        self.channelId = channelId
        self.channelName = channelName
        self.latitude = latitude
        self.longitude = longitude
        self.locationType = locationType
        self.locationUpdatedAt = locationUpdatedAt
        self.voiceMessagePath = voiceMessagePath
        self.voiceMessageUploaded = voiceMessageUploaded
        self.hasRemoteVoiceMessage = hasRemoteVoiceMessage
    }

    /// Create from START_ALARM message
    convenience init(from message: StartAlarmMessage) {
        self.init(
            alarmId: message.id,
            triggeredByUsername: message.userName,
            triggeredByDisplayName: message.displayName,
            triggeredByUserId: message.userId,
            channelId: message.channelId,
            channelName: message.channelName,
            latitude: message.latitude,
            longitude: message.longitude,
            locationType: message.locationType,
            locationUpdatedAt: message.latitude != nil ? Date() : nil
        )
    }
}

// MARK: - Query Helpers

extension AlarmEntity {

    /// Predicate for open alarms
    static var openAlarmsPredicate: Predicate<AlarmEntity> {
        #Predicate<AlarmEntity> { alarm in
            alarm.closedAt == nil
        }
    }

    /// Sort descriptor for most recent first
    static var recentFirstSort: SortDescriptor<AlarmEntity> {
        SortDescriptor(\.receivedAt, order: .reverse)
    }
}
