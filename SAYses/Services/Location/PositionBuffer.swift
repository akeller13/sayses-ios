import Foundation
import SwiftData

/// Thread-sicherer Persistenz-Layer für GPS-Positionen
actor PositionBuffer {
    static let shared = PositionBuffer()

    private var modelContainer: ModelContainer?

    private init() {
        do {
            // Use a SEPARATE database file to avoid conflicts with main app's AlarmEntity database
            let schema = Schema([BufferedPosition.self])
            let config = ModelConfiguration(
                "PositionBuffer",
                schema: schema,
                isStoredInMemoryOnly: false,
                allowsSave: true
            )
            modelContainer = try ModelContainer(for: schema, configurations: [config])
            print("[PositionBuffer] Initialized successfully with separate database")
        } catch {
            print("[PositionBuffer] Failed to create container: \(error)")
        }
    }

    /// Position in Buffer speichern
    func save(sessionId: String, position: PositionData) async {
        guard let container = modelContainer else {
            print("[PositionBuffer] Container not available")
            return
        }

        let context = ModelContext(container)
        let buffered = BufferedPosition(sessionId: sessionId, position: position)
        context.insert(buffered)

        do {
            try context.save()
            print("[PositionBuffer] Saved position for session \(sessionId)")
        } catch {
            print("[PositionBuffer] Failed to save: \(error)")
        }
    }

    /// Älteste Positionen für Session abrufen (FIFO)
    func fetch(sessionId: String, limit: Int = 10) async -> [BufferedPosition] {
        guard let container = modelContainer else { return [] }

        let context = ModelContext(container)

        var descriptor = FetchDescriptor<BufferedPosition>(
            predicate: #Predicate { $0.sessionId == sessionId },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        descriptor.fetchLimit = limit

        do {
            return try context.fetch(descriptor)
        } catch {
            print("[PositionBuffer] Failed to fetch: \(error)")
            return []
        }
    }

    /// Positionen nach erfolgreichem Upload löschen
    func delete(_ positions: [BufferedPosition]) async {
        guard let container = modelContainer else { return }

        let context = ModelContext(container)
        for position in positions {
            context.delete(position)
        }

        do {
            try context.save()
            print("[PositionBuffer] Deleted \(positions.count) positions")
        } catch {
            print("[PositionBuffer] Failed to delete: \(error)")
        }
    }

    /// Retry-Count erhöhen
    func incrementRetry(_ position: BufferedPosition) async {
        guard let container = modelContainer else { return }

        let context = ModelContext(container)
        position.retryCount += 1

        do {
            try context.save()
        } catch {
            print("[PositionBuffer] Failed to increment retry: \(error)")
        }
    }

    /// Anzahl gepufferter Positionen für Session
    func count(sessionId: String) async -> Int {
        guard let container = modelContainer else { return 0 }

        let context = ModelContext(container)
        let descriptor = FetchDescriptor<BufferedPosition>(
            predicate: #Predicate { $0.sessionId == sessionId }
        )

        do {
            return try context.fetchCount(descriptor)
        } catch {
            print("[PositionBuffer] Failed to count: \(error)")
            return 0
        }
    }

    /// Alle Positionen für Session löschen
    func clearAll(sessionId: String) async {
        guard let container = modelContainer else { return }

        let context = ModelContext(container)
        let descriptor = FetchDescriptor<BufferedPosition>(
            predicate: #Predicate { $0.sessionId == sessionId }
        )

        do {
            let positions = try context.fetch(descriptor)
            for position in positions {
                context.delete(position)
            }
            try context.save()
            print("[PositionBuffer] Cleared all positions for session \(sessionId)")
        } catch {
            print("[PositionBuffer] Failed to clear: \(error)")
        }
    }

    /// Alle gepufferten Positionen löschen (für Cleanup)
    func clearAllSessions() async {
        guard let container = modelContainer else { return }

        let context = ModelContext(container)
        let descriptor = FetchDescriptor<BufferedPosition>()

        do {
            let positions = try context.fetch(descriptor)
            for position in positions {
                context.delete(position)
            }
            try context.save()
            print("[PositionBuffer] Cleared all \(positions.count) positions")
        } catch {
            print("[PositionBuffer] Failed to clear all: \(error)")
        }
    }
}
