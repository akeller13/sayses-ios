import Foundation
import SwiftData

/// Repository for alarm data persistence operations
@MainActor
class AlarmRepository: ObservableObject {

    private let modelContext: ModelContext

    /// Shared instance using app's ModelContainer
    private static var _shared: AlarmRepository?
    private static var _sharedContainer: ModelContainer?

    static func shared(container: ModelContainer? = nil) -> AlarmRepository {
        print("[AlarmRepository] shared() called, container=\(container != nil ? "PROVIDED" : "nil"), _shared=\(_shared != nil ? "EXISTS" : "nil"), _sharedContainer=\(_sharedContainer != nil ? "EXISTS" : "nil")")

        if let container = container {
            _sharedContainer = container
            print("[AlarmRepository] Container set from parameter")
        }

        if let existing = _shared {
            print("[AlarmRepository] Returning existing instance")
            return existing
        }

        // Create with provided container or create new one
        if let container = _sharedContainer {
            print("[AlarmRepository] Creating new instance with existing container")
            let repo = AlarmRepository(context: container.mainContext)
            _shared = repo
            return repo
        } else {
            // Fallback: create own container (should be avoided)
            print("[AlarmRepository] WARNING: Creating FALLBACK container - this may cause data isolation!")
            do {
                let schema = Schema([AlarmEntity.self])
                let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
                let container = try ModelContainer(for: schema, configurations: [config])
                _sharedContainer = container
                let repo = AlarmRepository(context: container.mainContext)
                _shared = repo
                return repo
            } catch {
                fatalError("Failed to create AlarmRepository: \(error)")
            }
        }
    }

    // MARK: - Initialization

    init(context: ModelContext) {
        self.modelContext = context
    }

    // MARK: - Create

    /// Insert a new alarm from a START_ALARM message
    func insertAlarm(from message: StartAlarmMessage) -> AlarmEntity {
        let alarm = AlarmEntity(from: message)
        modelContext.insert(alarm)

        do {
            try modelContext.save()
            print("[AlarmRepository] Inserted alarm: \(alarm.alarmId)")
        } catch {
            print("[AlarmRepository] Failed to save alarm: \(error)")
        }

        return alarm
    }

    /// Insert a new alarm entity
    func insertAlarm(_ alarm: AlarmEntity) {
        modelContext.insert(alarm)

        do {
            try modelContext.save()
            print("[AlarmRepository] Inserted alarm: \(alarm.alarmId)")
        } catch {
            print("[AlarmRepository] Failed to save alarm: \(error)")
        }
    }

    // MARK: - Read

    /// Get all open alarms (sorted by most recent)
    func getOpenAlarms() -> [AlarmEntity] {
        let predicate = AlarmEntity.openAlarmsPredicate
        let sortDescriptor = AlarmEntity.recentFirstSort

        let descriptor = FetchDescriptor<AlarmEntity>(
            predicate: predicate,
            sortBy: [sortDescriptor]
        )

        do {
            let results = try modelContext.fetch(descriptor)
            print("[AlarmRepository] getOpenAlarms: found \(results.count) open alarms")
            for alarm in results {
                print("[AlarmRepository]   - \(alarm.alarmId): closedAt=\(alarm.closedAt?.description ?? "nil"), from=\(alarm.triggeredByUsername)")
            }
            return results
        } catch {
            print("[AlarmRepository] Failed to fetch open alarms: \(error)")
            return []
        }
    }

    /// Delete ALL alarms from database
    func deleteAllAlarms() {
        print("[AlarmRepository] deleteAllAlarms called")
        let descriptor = FetchDescriptor<AlarmEntity>()

        do {
            let allAlarms = try modelContext.fetch(descriptor)
            print("[AlarmRepository] Deleting \(allAlarms.count) alarms from database")
            for alarm in allAlarms {
                modelContext.delete(alarm)
            }
            try modelContext.save()
            print("[AlarmRepository] All alarms deleted successfully")
        } catch {
            print("[AlarmRepository] Failed to delete all alarms: \(error)")
        }
    }

    /// Get all alarms (sorted by most recent)
    func getAllAlarms() -> [AlarmEntity] {
        let descriptor = FetchDescriptor<AlarmEntity>(
            sortBy: [AlarmEntity.recentFirstSort]
        )

        do {
            return try modelContext.fetch(descriptor)
        } catch {
            print("[AlarmRepository] Failed to fetch all alarms: \(error)")
            return []
        }
    }

    /// Get alarm by alarmId
    func getAlarm(byAlarmId alarmId: String) -> AlarmEntity? {
        let predicate = #Predicate<AlarmEntity> { alarm in
            alarm.alarmId == alarmId
        }

        let descriptor = FetchDescriptor<AlarmEntity>(predicate: predicate)

        do {
            return try modelContext.fetch(descriptor).first
        } catch {
            print("[AlarmRepository] Failed to fetch alarm: \(error)")
            return nil
        }
    }

    /// Get alarm by backend alarm ID
    func getAlarm(byBackendId backendId: String) -> AlarmEntity? {
        let predicate = #Predicate<AlarmEntity> { alarm in
            alarm.backendAlarmId == backendId
        }

        let descriptor = FetchDescriptor<AlarmEntity>(predicate: predicate)

        do {
            return try modelContext.fetch(descriptor).first
        } catch {
            print("[AlarmRepository] Failed to fetch alarm: \(error)")
            return nil
        }
    }

    /// Check if an alarm exists
    func alarmExists(alarmId: String) -> Bool {
        getAlarm(byAlarmId: alarmId) != nil
    }

    // MARK: - Update

    /// Update backend alarm ID
    func updateBackendAlarmId(alarmId: String, backendAlarmId: String) {
        guard let alarm = getAlarm(byAlarmId: alarmId) else {
            print("[AlarmRepository] Alarm not found: \(alarmId)")
            return
        }

        alarm.backendAlarmId = backendAlarmId
        save()
        print("[AlarmRepository] Updated backend ID for \(alarmId): \(backendAlarmId)")
    }

    /// Update alarm location
    func updateLocation(alarmId: String, latitude: Double, longitude: Double, locationType: String) {
        guard let alarm = getAlarm(byAlarmId: alarmId) else {
            print("[AlarmRepository] Alarm not found: \(alarmId)")
            return
        }

        alarm.latitude = latitude
        alarm.longitude = longitude
        alarm.locationType = locationType
        alarm.locationUpdatedAt = Date()
        save()
        print("[AlarmRepository] Updated location for \(alarmId)")
    }

    /// Update voice message path
    func updateVoiceMessagePath(alarmId: String, path: String) {
        guard let alarm = getAlarm(byAlarmId: alarmId) else {
            print("[AlarmRepository] Alarm not found: \(alarmId)")
            return
        }

        alarm.voiceMessagePath = path
        save()
        print("[AlarmRepository] Updated voice path for \(alarmId)")
    }

    /// Mark voice message as uploaded
    func markVoiceMessageUploaded(alarmId: String) {
        guard let alarm = getAlarm(byAlarmId: alarmId) else {
            print("[AlarmRepository] Alarm not found: \(alarmId)")
            return
        }

        alarm.voiceMessageUploaded = true
        save()
        print("[AlarmRepository] Marked voice uploaded for \(alarmId)")
    }

    /// Update hasRemoteVoiceMessage flag
    func updateHasRemoteVoiceMessage(alarmId: String, hasRemote: Bool) {
        guard let alarm = getAlarm(byAlarmId: alarmId) else {
            print("[AlarmRepository] Alarm not found: \(alarmId)")
            return
        }

        alarm.hasRemoteVoiceMessage = hasRemote
        save()
    }

    /// Update alarm from backend sync data (like Android's updateFromBackend)
    func updateFromBackend(
        alarmId: String,
        latitude: Double?,
        longitude: Double?,
        locationType: String?,
        locationUpdatedAt: Date?,
        hasRemoteVoiceMessage: Bool
    ) {
        guard let alarm = getAlarm(byAlarmId: alarmId) else {
            print("[AlarmRepository] Alarm not found for backend update: \(alarmId)")
            return
        }

        alarm.latitude = latitude
        alarm.longitude = longitude
        alarm.locationType = locationType
        alarm.locationUpdatedAt = locationUpdatedAt
        alarm.hasRemoteVoiceMessage = hasRemoteVoiceMessage
        save()
        print("[AlarmRepository] Updated alarm \(alarmId) from backend: lat=\(latitude ?? 0), lon=\(longitude ?? 0), updatedAt=\(locationUpdatedAt?.description ?? "nil")")
    }

    /// Update only the location timestamp (when position unchanged but we have new backend timestamp)
    func updateLocationTimestamp(alarmId: String, timestamp: Date) {
        guard let alarm = getAlarm(byAlarmId: alarmId) else {
            print("[AlarmRepository] Alarm not found for timestamp update: \(alarmId)")
            return
        }

        alarm.locationUpdatedAt = timestamp
        save()
    }

    /// Close alarm by alarmId (deletes from database to ensure it's removed from open alarms)
    func closeAlarm(alarmId: String, closedAt: Date = Date()) {
        print("[AlarmRepository] closeAlarm called with alarmId: \(alarmId)")

        guard let alarm = getAlarm(byAlarmId: alarmId) else {
            print("[AlarmRepository] Alarm not found: \(alarmId) - may already be deleted")
            return
        }

        print("[AlarmRepository] Deleting alarm: \(alarm.alarmId)")
        modelContext.delete(alarm)
        save()
        print("[AlarmRepository] Alarm deleted: \(alarmId)")

        // Verify deletion
        let verifyAlarm = getAlarm(byAlarmId: alarmId)
        if verifyAlarm == nil {
            print("[AlarmRepository] Verified: alarm no longer exists")
        } else {
            print("[AlarmRepository] ERROR: Alarm still exists after delete!")
        }
    }

    /// Close alarm from END_ALARM message
    func closeAlarm(from message: EndAlarmMessage) {
        let closedAt = Date(timeIntervalSince1970: Double(message.closedAt) / 1000)
        closeAlarm(alarmId: message.id, closedAt: closedAt)
    }

    /// Apply UPDATE_ALARM message
    func applyUpdate(_ message: UpdateAlarmMessage) {
        print("[AlarmRepository] applyUpdate called for alarm: \(message.id)")
        print("[AlarmRepository]   hasVoiceMessage in message: \(message.hasVoiceMessage?.description ?? "nil")")
        print("[AlarmRepository]   backendAlarmId in message: \(message.backendAlarmId ?? "nil")")

        guard let alarm = getAlarm(byAlarmId: message.id) else {
            print("[AlarmRepository] Alarm not found for update: \(message.id)")
            return
        }

        print("[AlarmRepository]   BEFORE: alarm.hasRemoteVoiceMessage=\(alarm.hasRemoteVoiceMessage), backendAlarmId=\(alarm.backendAlarmId ?? "nil")")

        if let lat = message.latitude, let lon = message.longitude {
            alarm.latitude = lat
            alarm.longitude = lon
            alarm.locationType = message.locationType
            alarm.locationUpdatedAt = Date()
        }

        if let hasVoice = message.hasVoiceMessage {
            // Only set to true, never reset from true to false
            // (Backend sync is the source of truth for hasRemoteVoiceMessage)
            if hasVoice && !alarm.hasRemoteVoiceMessage {
                print("[AlarmRepository]   Setting hasRemoteVoiceMessage to true")
                alarm.hasRemoteVoiceMessage = true
            } else if !hasVoice && alarm.hasRemoteVoiceMessage {
                print("[AlarmRepository]   Ignoring hasVoiceMessage=false (already true from backend)")
            }
        }

        if let backendId = message.backendAlarmId {
            alarm.backendAlarmId = backendId
        }

        save()
        print("[AlarmRepository]   AFTER: alarm.hasRemoteVoiceMessage=\(alarm.hasRemoteVoiceMessage), backendAlarmId=\(alarm.backendAlarmId ?? "nil")")
        print("[AlarmRepository] Applied update for \(message.id)")
    }

    // MARK: - Delete

    /// Delete alarm by alarmId
    func deleteAlarm(alarmId: String) {
        guard let alarm = getAlarm(byAlarmId: alarmId) else {
            return
        }

        modelContext.delete(alarm)
        save()
        print("[AlarmRepository] Deleted alarm: \(alarmId)")
    }

    /// Delete all closed alarms older than specified date
    func deleteOldClosedAlarms(olderThan date: Date) {
        let predicate = #Predicate<AlarmEntity> { alarm in
            alarm.closedAt != nil && alarm.receivedAt < date
        }

        let descriptor = FetchDescriptor<AlarmEntity>(predicate: predicate)

        do {
            let oldAlarms = try modelContext.fetch(descriptor)
            for alarm in oldAlarms {
                modelContext.delete(alarm)
            }
            save()
            print("[AlarmRepository] Deleted \(oldAlarms.count) old alarms")
        } catch {
            print("[AlarmRepository] Failed to delete old alarms: \(error)")
        }
    }

    // MARK: - Helpers

    private func save() {
        do {
            try modelContext.save()
        } catch {
            print("[AlarmRepository] Save failed: \(error)")
        }
    }
}
