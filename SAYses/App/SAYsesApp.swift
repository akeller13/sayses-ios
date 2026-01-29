import SwiftUI
import SwiftData

@main
struct SAYsesApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var authViewModel = AuthViewModel()

    let sharedModelContainer: ModelContainer

    init() {
        let schema = Schema([
            AlarmEntity.self
        ])
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false
        )

        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
            self.sharedModelContainer = container
            print("[SAYsesApp] ModelContainer created successfully")
            // Initialize shared AlarmRepository with the container
            let repo = AlarmRepository.shared(container: container)
            print("[SAYsesApp] AlarmRepository initialized: \(repo)")
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
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
