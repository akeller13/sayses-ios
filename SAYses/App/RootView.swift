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
    }
}

struct SplashView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image("MicCircle")
                .resizable()
                .scaledToFit()
                .frame(width: 100, height: 100)

            Text("SAYses")
                .font(.largeTitle)
                .fontWeight(.bold)

            ProgressView()
                .scaleEffect(1.2)
        }
    }
}

struct MainTabView: View {
    var body: some View {
        NavigationStack {
            ChannelListView()
        }
    }
}

#Preview {
    RootView()
        .environment(AuthViewModel())
}
