import SwiftUI

/// Banner shown at the bottom of the screen when connection is offline.
/// Displays countdown to next reconnection attempt.
struct OfflineStatusBanner: View {
    let secondsUntilRetry: Int

    var body: some View {
        if secondsUntilRetry > 0 {
            HStack {
                Image(systemName: "wifi.slash")
                    .foregroundStyle(.red)

                Text("Verbindung offline. Nächster Versuch: \(timeString)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Color.red.opacity(0.1))
            .overlay(
                Rectangle()
                    .frame(height: 1)
                    .foregroundStyle(.red),
                alignment: .top
            )
        }
    }

    private var timeString: String {
        let minutes = secondsUntilRetry / 60
        let seconds = secondsUntilRetry % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

#Preview {
    VStack {
        Spacer()
        OfflineStatusBanner(secondsUntilRetry: 45)
        OfflineStatusBanner(secondsUntilRetry: 125)
        OfflineStatusBanner(secondsUntilRetry: 0)
    }
}
