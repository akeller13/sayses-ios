import SwiftUI

struct RootView: View {
    @Environment(AuthViewModel.self) private var authViewModel

    var body: some View {
        Group {
            if authViewModel.isCheckingAuth {
                // Splash screen while checking authentication
                SplashView()
            } else if authViewModel.isAuthenticated {
                // Main app content
                MainTabView()
            } else {
                // Login flow
                LoginView()
            }
        }
        .task {
            await authViewModel.checkAuthentication()
        }
        .onChange(of: authViewModel.isAuthenticated) { oldValue, newValue in
            print("[RootView] isAuthenticated changed: \(oldValue) -> \(newValue)")
        }
        .onChange(of: authViewModel.isCheckingAuth) { oldValue, newValue in
            print("[RootView] isCheckingAuth changed: \(oldValue) -> \(newValue)")
        }
    }
}

struct SplashView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image("LaunchLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 120, height: 120)

            Text("SAYses")
                .font(.largeTitle)
                .fontWeight(.bold)

            ProgressView()
                .scaleEffect(1.2)
        }
    }
}

struct MainTabView: View {
    @StateObject private var mumbleService = MumbleService()
    @State private var showAlarmAlert = false
    @State private var showEndAlarmAlert = false

    var body: some View {
        ZStack {
            ChannelListView(mumbleService: mumbleService)
        }
        .onDisappear {
            // User logged out - disconnect and clear cache
            print("[MainTabView] onDisappear - disconnecting MumbleService")
            mumbleService.disconnect()
        }
        .fullScreenCover(isPresented: $showAlarmAlert) {
            if let alarm = mumbleService.receivedAlarmForAlert {
                AlarmAlertDialog(
                    alarm: alarm,
                    onDismiss: {
                        mumbleService.dismissReceivedAlarm()
                        showAlarmAlert = false
                    }
                )
            }
        }
        .onChange(of: mumbleService.receivedAlarmForAlert) { oldValue, newValue in
            showAlarmAlert = newValue != nil
        }
        .fullScreenCover(isPresented: $showEndAlarmAlert) {
            if let endAlarm = mumbleService.receivedEndAlarmForAlert {
                EndAlarmAlertDialog(
                    endAlarm: endAlarm,
                    onDismiss: {
                        mumbleService.dismissEndAlarmAlert()
                        showEndAlarmAlert = false
                    }
                )
            }
        }
        .onChange(of: mumbleService.receivedEndAlarmForAlert) { oldValue, newValue in
            showEndAlarmAlert = newValue != nil
        }
    }
}

#Preview {
    RootView()
        .environment(AuthViewModel())
}
