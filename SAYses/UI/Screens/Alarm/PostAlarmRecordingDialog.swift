import SwiftUI

/// Dialog shown after alarm is triggered to allow continued voice recording
/// Shows remaining recording time and allows early submission
struct PostAlarmRecordingDialog: View {
    let initialRemainingSeconds: Int
    let onSubmit: () -> Void

    @State private var startTime: Date = Date()
    @State private var submitted: Bool = false
    @State private var micPulse: Bool = false

    init(remainingSeconds: Int, onSubmit: @escaping () -> Void) {
        self.initialRemainingSeconds = remainingSeconds
        self.onSubmit = onSubmit
    }

    /// Calculate remaining seconds from system time (not dependent on state updates)
    private func calculateRemainingSeconds(at date: Date) -> Int {
        let elapsed = Int(date.timeIntervalSince(startTime))
        return max(0, initialRemainingSeconds - elapsed)
    }

    var body: some View {
        // TimelineView updates every second based on system clock
        // This is the most reliable way to implement a countdown in SwiftUI
        TimelineView(.periodic(from: startTime, by: 1.0)) { context in
            let remaining = calculateRemainingSeconds(at: context.date)

            ZStack {
                // Semi-transparent background
                Color.black.opacity(0.7)
                    .ignoresSafeArea()

                VStack(spacing: 30) {
                    // Checkmark icon (alarm was triggered)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(.green)

                    // Title
                    Text("Alarm ausgelöst")
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)

                    // Subtitle
                    Text("Aufnahme läuft noch für")
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.8))

                    // Countdown number
                    Text("\(remaining)")
                        .font(.system(size: 80, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.alarmRed)
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.3), value: remaining)

                    Text("Sekunden")
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.8))

                    // Recording indicator
                    HStack(spacing: 12) {
                        Image(systemName: "mic.fill")
                            .font(.title2)
                            .foregroundStyle(.red)
                            .scaleEffect(micPulse ? 1.2 : 1.0)
                            .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: micPulse)

                        Text("Sprachnachricht wird aufgenommen...")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.1))
                    )

                    Spacer()
                        .frame(height: 20)

                    // Submit button
                    Button(action: {
                        guard !submitted else { return }
                        print("[PostAlarmRecordingDialog] User tapped submit button")
                        submitted = true
                        onSubmit()
                    }) {
                        HStack {
                            Image(systemName: "paperplane.fill")
                            Text("Aufzeichnung senden")
                        }
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.vertical, 16)
                        .padding(.horizontal, 40)
                        .background(
                            Capsule()
                                .fill(Color.alarmRed)
                        )
                    }
                }
                .padding(40)
            }
            .task(id: remaining) {
                // Auto-submit when countdown reaches 0
                // .task(id:) runs whenever the id value changes
                if remaining == 0 && !submitted {
                    print("[PostAlarmRecordingDialog] Countdown complete - calling onSubmit()")
                    submitted = true
                    onSubmit()
                }
            }
        }
        .onAppear {
            print("[PostAlarmRecordingDialog] onAppear - countdown from \(initialRemainingSeconds) seconds")
            startTime = Date()  // Reset start time when view appears
            micPulse = true
        }
    }
}

// MARK: - Preview

#Preview {
    PostAlarmRecordingDialog(
        remainingSeconds: 25,
        onSubmit: { print("Submit recording") }
    )
}
