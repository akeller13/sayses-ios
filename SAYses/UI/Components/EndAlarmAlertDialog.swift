import SwiftUI

/// Dialog displayed when an alarm is ended by another user
/// Shows who ended the alarm with blue background and white text
struct EndAlarmAlertDialog: View {
    let endAlarm: EndAlarmMessage
    let onDismiss: () -> Void

    private var messageText: String {
        if let triggeredBy = endAlarm.triggeredByDisplayName {
            return "Der Alarm von \(triggeredBy) wurde von \(endAlarm.displayName) beendet."
        } else {
            return "Der Alarm wurde von \(endAlarm.displayName) beendet."
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
                    // Checkmark icon in white circle
                    ZStack {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 80, height: 80)

                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 50))
                            .foregroundStyle(Color.blue)
                    }

                    // Title
                    Text("Alarm beendet")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)

                    Spacer().frame(height: 8)

                    // Message
                    Text(messageText)
                        .font(.body)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)

                    Spacer().frame(height: 24)

                    // OK Button
                    Button(action: onDismiss) {
                        Text("OK")
                            .font(.title3)
                            .fontWeight(.bold)
                            .foregroundStyle(.blue)
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
                    .fill(Color.blue)
            )
            .padding(.horizontal, 24)
        }
    }
}

#Preview {
    EndAlarmAlertDialog(
        endAlarm: EndAlarmMessage(
            id: "test-123",
            userId: 1,
            userName: "max@example",
            displayName: "Max Mustermann",
            triggeredByDisplayName: "Anna Schmidt"
        ),
        onDismiss: { print("Dismissed") }
    )
}
