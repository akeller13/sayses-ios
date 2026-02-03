import SwiftUI

/// Dialog shown after dispatcher request is triggered to allow voice recording
/// Shows remaining recording time and allows early submission
struct DispatcherRecordingDialog: View {
    let initialRemainingSeconds: Int
    let dispatcherAlias: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

    // WICHTIG: startTime wird erst in onAppear gesetzt, nicht bei View-Erstellung!
    // Sonst kann es passieren, dass die Zeit bereits abgelaufen ist wenn die View erscheint.
    @State private var startTime: Date? = nil
    @State private var submitted: Bool = false
    @State private var micPulse: Bool = false

    // Orange color from Android: sayses_secondary_dark = #F57C00
    private let orangeColor = Color(red: 0xF5/255.0, green: 0x7C/255.0, blue: 0x00/255.0)

    init(remainingSeconds: Int, dispatcherAlias: String, onSubmit: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.initialRemainingSeconds = remainingSeconds
        self.dispatcherAlias = dispatcherAlias
        self.onSubmit = onSubmit
        self.onCancel = onCancel
    }

    /// Calculate remaining seconds from system time
    /// Returns initialRemainingSeconds if startTime is not yet set
    private func calculateRemainingSeconds(at date: Date) -> Int {
        guard let startTime = startTime else {
            // View not yet appeared - show full time
            return initialRemainingSeconds
        }
        let elapsed = Int(date.timeIntervalSince(startTime))
        return max(0, initialRemainingSeconds - elapsed)
    }

    var body: some View {
        // Verwende aktuelles Datum für TimelineView - die Berechnung verwendet startTime
        TimelineView(.periodic(from: Date(), by: 1.0)) { context in
            let remaining = calculateRemainingSeconds(at: context.date)

            ZStack {
                // Semi-transparent background
                Color.black.opacity(0.7)
                    .ignoresSafeArea()

                VStack(spacing: 30) {
                    // Title
                    Text("Meldung an \(dispatcherAlias)")
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
                        .foregroundStyle(orangeColor)
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.3), value: remaining)

                    Text("Sekunden")
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.8))

                    // Recording indicator
                    HStack(spacing: 12) {
                        Image(systemName: "mic.fill")
                            .font(.title2)
                            .foregroundStyle(orangeColor)
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
                        print("[DispatcherRecordingDialog] User tapped submit button")
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
                                .fill(orangeColor)
                        )
                    }

                    // Cancel button
                    Button(action: {
                        guard !submitted else { return }
                        print("[DispatcherRecordingDialog] User tapped cancel button")
                        submitted = true
                        onCancel()
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "xmark")
                                .font(.title2)
                                .fontWeight(.bold)
                            Text("Abbrechen")
                        }
                        .font(.title3)
                        .foregroundStyle(.red)
                    }
                    .padding(.top, 10)
                }
                .padding(40)
            }
            .task(id: remaining) {
                // Auto-submit when countdown reaches 0
                // Nur wenn startTime gesetzt ist (View ist erschienen)
                if remaining == 0 && !submitted && startTime != nil {
                    print("[DispatcherRecordingDialog] Countdown complete - calling onSubmit()")
                    submitted = true
                    onSubmit()
                }
            }
        }
        .onAppear {
            print("[DispatcherRecordingDialog] onAppear - countdown from \(initialRemainingSeconds) seconds")
            // WICHTIG: startTime erst hier setzen, nicht bei View-Erstellung!
            startTime = Date()
            micPulse = true
        }
    }
}

// MARK: - Preview

#Preview {
    DispatcherRecordingDialog(
        remainingSeconds: 20,
        dispatcherAlias: "Zentrale",
        onSubmit: { print("Submit recording") },
        onCancel: { print("Cancel recording") }
    )
}
