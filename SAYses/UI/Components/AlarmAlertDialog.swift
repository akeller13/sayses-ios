import SwiftUI
import MapKit

/// Full-screen alarm alert dialog displayed when an alarm is received
/// Shows alarm details with red/warning colors for visual impact
struct AlarmAlertDialog: View {
    let alarm: AlarmEntity
    let onDismiss: () -> Void

    @State private var showMapSheet = false

    private var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: alarm.receivedAt)
    }

    private var locationTypeText: String? {
        switch alarm.locationType {
        case "gps": return "GPS"
        case "network": return "Netzwerk"
        default: return nil
        }
    }

    var body: some View {
        ZStack {
            // Semi-transparent background
            Color.black.opacity(0.7)
                .ignoresSafeArea()

            // Alert card
            VStack(spacing: 0) {
                VStack(spacing: 16) {
                    // Warning icon in white circle
                    ZStack {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 80, height: 80)

                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(Color.alarmRed)
                    }

                    // ALARM title
                    Text("ALARM")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(.white)

                    Spacer().frame(height: 8)

                    // Triggered by
                    VStack(spacing: 4) {
                        Text("Ausgelöst von:")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.8))

                        Text(alarm.triggeredByDisplayName ?? alarm.triggeredByUsername)
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                    }

                    // Channel
                    VStack(spacing: 4) {
                        Text("Kanal:")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.8))

                        Text(alarm.channelName)
                            .font(.title3)
                            .fontWeight(.medium)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                    }

                    // Time
                    Text("Zeit: \(timeString)")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))

                    // Location (if available)
                    if alarm.hasLocation, let lat = alarm.latitude, let lon = alarm.longitude {
                        VStack(spacing: 8) {
                            if let locationType = locationTypeText {
                                Text("Standort: \(locationType)")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.7))
                            }

                            Button(action: {
                                showMapSheet = true
                            }) {
                                HStack {
                                    Image(systemName: "location.fill")
                                    Text("Standort öffnen")
                                }
                                .font(.body)
                                .fontWeight(.medium)
                                .foregroundStyle(.white)
                                .padding(.vertical, 12)
                                .padding(.horizontal, 24)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.white, lineWidth: 1)
                                )
                            }
                            .sheet(isPresented: $showMapSheet) {
                                PositionMapSheet(
                                    coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                                    title: alarm.triggeredByDisplayName ?? alarm.triggeredByUsername
                                )
                            }
                        }
                    }

                    Spacer().frame(height: 16)

                    // OK Button
                    Button(action: onDismiss) {
                        Text("OK")
                            .font(.title3)
                            .fontWeight(.bold)
                            .foregroundStyle(Color.alarmRed)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.white)
                            )
                    }
                }
                .padding(24)
            }
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.alarmRed)
            )
            .padding(.horizontal, 24)
        }
    }

}

#Preview {
    AlarmAlertDialog(
        alarm: {
            let alarm = AlarmEntity(
                alarmId: "test-123",
                triggeredByUsername: "max.mustermann@example.com",
                triggeredByDisplayName: "Max Mustermann",
                triggeredByUserId: 1,
                channelId: 1,
                channelName: "Notfall",
                latitude: 52.52,
                longitude: 13.405,
                locationType: "gps"
            )
            return alarm
        }(),
        onDismiss: { print("Dismissed") }
    )
}
