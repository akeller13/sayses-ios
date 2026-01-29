import SwiftUI

/// Dialog shown during Phase 2 of alarm triggering
/// Shows countdown, recording indicator, cancel button, and "trigger now" button
struct AlarmCountdownDialog: View {
    let countdownDuration: Int
    let onCancel: () -> Void
    let onTriggerNow: (Int) -> Void  // Trigger alarm immediately, passes elapsed seconds
    let onComplete: () -> Void

    @State private var startTime: Date = Date()
    @State private var micPulse: Bool = false
    @State private var completed: Bool = false  // Prevents double-firing of onComplete/onTriggerNow

    init(countdownDuration: Int, onCancel: @escaping () -> Void, onTriggerNow: @escaping (Int) -> Void, onComplete: @escaping () -> Void) {
        self.countdownDuration = countdownDuration
        self.onCancel = onCancel
        self.onTriggerNow = onTriggerNow
        self.onComplete = onComplete
    }

    /// Calculate remaining seconds from system time
    private func calculateRemainingSeconds(at date: Date) -> Int {
        let elapsed = Int(date.timeIntervalSince(startTime))
        return max(0, countdownDuration - elapsed)
    }

    var body: some View {
        TimelineView(.periodic(from: startTime, by: 1.0)) { context in
            let remaining = calculateRemainingSeconds(at: context.date)

            ZStack {
                // Semi-transparent background
                Color.black.opacity(0.7)
                    .ignoresSafeArea()

                VStack(spacing: 30) {
                    // Warning icon
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(.yellow)

                    // Title
                    Text("Alarm wird ausgelöst")
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)

                    // Countdown number
                    Text("\(remaining)")
                        .font(.system(size: 80, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.alarmRed)
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.3), value: remaining)

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

                    // Trigger now button
                    Button(action: {
                        guard !completed else { return }
                        completed = true
                        let elapsed = countdownDuration - remaining
                        onTriggerNow(elapsed)
                    }) {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text("Alarm jetzt")
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

                    // Cancel button
                    Button(action: {
                        guard !completed else { return }
                        completed = true
                        onCancel()
                    }) {
                        HStack {
                            Image(systemName: "xmark.circle.fill")
                            Text("Abbrechen")
                        }
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.vertical, 16)
                        .padding(.horizontal, 40)
                        .background(
                            Capsule()
                                .fill(Color.gray.opacity(0.5))
                        )
                    }
                }
                .padding(40)
            }
            .task(id: remaining) {
                // Auto-complete when countdown reaches 0
                if remaining == 0 && !completed {
                    completed = true
                    onComplete()
                }
            }
        }
        .onAppear {
            startTime = Date()
            micPulse = true
        }
    }
}

// MARK: - Alarm State for View Model

/// State machine for alarm triggering workflow
enum AlarmTriggerState: Equatable {
    case idle
    case holding(progress: Double)
    case countdown(remaining: Int)
    case triggering
    case triggered(alarmId: String)
    case failed(error: String)
    case cancelled
}

// MARK: - Preview

#Preview {
    AlarmCountdownDialog(
        countdownDuration: 5,
        onCancel: { print("Cancelled") },
        onTriggerNow: { elapsed in print("Trigger now! Elapsed: \(elapsed)s") },
        onComplete: { print("Complete") }
    )
}
