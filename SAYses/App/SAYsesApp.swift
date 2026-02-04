import SwiftUI
import SwiftData

@main
struct SAYsesApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var authViewModel = AuthViewModel()

    let sharedModelContainer: ModelContainer

    init() {
        let appStartTime = CFAbsoluteTimeGetCurrent()
        NSLog("[SAYsesApp] init() starting...")

        let schema = Schema([
            AlarmEntity.self
        ])

        // Schema version key - increment this when schema changes
        let currentSchemaVersion = 2
        let schemaVersionKey = "SAYses_SchemaVersion"

        // Helper function to delete database files
        func deleteDatabase() {
            let fileManager = FileManager.default
            if let appSupportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                let storeURL = appSupportDir.appendingPathComponent("default.store")
                let shmURL = appSupportDir.appendingPathComponent("default.store-shm")
                let walURL = appSupportDir.appendingPathComponent("default.store-wal")

                try? fileManager.removeItem(at: storeURL)
                try? fileManager.removeItem(at: shmURL)
                try? fileManager.removeItem(at: walURL)
                print("[SAYsesApp] Old database files deleted")
            }
        }

        // Check if we need to migrate (schema version changed)
        let savedSchemaVersion = UserDefaults.standard.integer(forKey: schemaVersionKey)
        if savedSchemaVersion < currentSchemaVersion {
            print("[SAYsesApp] Schema version changed (\(savedSchemaVersion) -> \(currentSchemaVersion)), deleting old database...")
            deleteDatabase()
            UserDefaults.standard.set(currentSchemaVersion, forKey: schemaVersionKey)
        }

        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false
        )

        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
            self.sharedModelContainer = container
            NSLog("[SAYsesApp] ModelContainer created successfully (%.0fms)", (CFAbsoluteTimeGetCurrent() - appStartTime) * 1000)
            // Initialize shared AlarmRepository with the container
            let repo = AlarmRepository.shared(container: container)
            print("[SAYsesApp] AlarmRepository initialized: \(repo)")
        } catch {
            // Schema migration failed - delete old database and retry
            print("[SAYsesApp] ModelContainer creation failed: \(error)")
            print("[SAYsesApp] Attempting to delete old database and recreate...")

            deleteDatabase()
            UserDefaults.standard.set(currentSchemaVersion, forKey: schemaVersionKey)

            // Retry with fresh database
            do {
                let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
                self.sharedModelContainer = container
                print("[SAYsesApp] ModelContainer recreated successfully after cleanup")
                let repo = AlarmRepository.shared(container: container)
                print("[SAYsesApp] AlarmRepository initialized: \(repo)")
            } catch {
                fatalError("Could not create ModelContainer even after cleanup: \(error)")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(authViewModel)
                .modelContainer(sharedModelContainer)
        }
    }
}
