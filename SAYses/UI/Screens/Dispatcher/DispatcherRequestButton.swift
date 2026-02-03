import SwiftUI

/// Hold-to-trigger button for dispatcher requests
/// Similar to AlarmTriggerButton but with orange color and no countdown
struct DispatcherRequestButton: View {
    /// Called when hold starts - start GPS warm-up
    let onHoldStart: () -> Void
    /// Called when hold duration reached - trigger request immediately
    let onHoldComplete: () -> Void
    /// Called when user releases before hold completes - cancel warm-up
    let onHoldCancel: () -> Void
    /// The duration in seconds the button must be held (from backend settings)
    let holdDuration: Double
    /// The dispatcher alias to display
    let dispatcherAlias: String

    // @GestureState auto-resets to false when the gesture ends OR is cancelled
    // (e.g., when a fullScreenCover appears and cancels the gesture).
    // This avoids the stuck-state problem that @State had.
    @GestureState private var isFingerDown = false
    @State private var holdProgress: CGFloat = 0
    @State private var holdTask: Task<Void, Never>?
    @State private var didComplete = false

    // Orange color from Android: sayses_secondary_dark = #F57C00
    private let orangeColor = Color(red: 0xF5/255.0, green: 0x7C/255.0, blue: 0x00/255.0)
    private let orangeDarkColor = Color(red: 0xD5/255.0, green: 0x6C/255.0, blue: 0x00/255.0)

    init(
        holdDuration: Double = 0.5,
        dispatcherAlias: String = "Zentrale",
        onHoldStart: @escaping () -> Void = {},
        onHoldComplete: @escaping () -> Void,
        onHoldCancel: @escaping () -> Void = {}
    ) {
        self.holdDuration = holdDuration
        self.dispatcherAlias = dispatcherAlias
        self.onHoldStart = onHoldStart
        self.onHoldComplete = onHoldComplete
        self.onHoldCancel = onHoldCancel
    }

    var body: some View {
        GeometryReader { geometry in
            let buttonSize = geometry.size.width * 0.75

            ZStack {
                // Background
                RoundedRectangle(cornerRadius: 16)
                    .fill(isFingerDown ? orangeDarkColor : orangeColor)
                    .frame(width: buttonSize, height: buttonSize)

                // Progress ring (visible when holding)
                Circle()
                    .trim(from: 0, to: holdProgress)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .frame(width: buttonSize - 30, height: buttonSize - 30)
                    .rotationEffect(.degrees(-90))
                    .opacity(holdProgress > 0 ? 1 : 0)

                // Text content
                VStack(spacing: 4) {
                    Text("Meldung an")
                    Text(dispatcherAlias)
                    Text("senden")
                }
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
                .offset(y: -10)

                Text("Button für 1 Sekunde drücken")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: buttonSize, alignment: .bottom)
                    .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity)
            .shadow(color: isFingerDown ? orangeColor.opacity(0.5) : .clear, radius: 10)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isFingerDown) { _, state, _ in
                        state = true
                    }
            )
            .onChange(of: isFingerDown) { oldValue, newValue in
                if newValue && !oldValue {
                    // Finger touched down - new gesture started
                    didComplete = false
                    startHold()
                } else if !newValue && oldValue {
                    // Finger lifted or gesture cancelled (e.g., fullScreenCover appeared)
                    cancelHold()
                }
            }
            .sensoryFeedback(.impact(weight: .medium), trigger: isFingerDown)
        }
        .frame(height: UIScreen.main.bounds.width * 0.75 + 16)
    }

    private func startHold() {
        holdProgress = 0
        onHoldStart()

        holdTask = Task {
            let startTime = Date()

            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(startTime)
                let progress = min(elapsed / holdDuration, 1.0)

                await MainActor.run {
                    holdProgress = CGFloat(progress)
                }

                if progress >= 1.0 {
                    // Provide haptic feedback on completion
                    await MainActor.run {
                        let generator = UINotificationFeedbackGenerator()
                        generator.notificationOccurred(.success)

                        didComplete = true
                        holdProgress = 0
                        onHoldComplete()
                    }
                    break
                }

                try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
            }
        }
    }

    private func cancelHold() {
        holdTask?.cancel()
        holdTask = nil

        // Only call cancel if we didn't complete
        if !didComplete {
            onHoldCancel()
        }

        withAnimation(.easeOut(duration: 0.2)) {
            holdProgress = 0
        }
    }
}

#Preview {
    VStack {
        Spacer()
        DispatcherRequestButton(
            holdDuration: 0.5,
            dispatcherAlias: "Zentrale",
            onHoldStart: { print("Hold started - warming up GPS") },
            onHoldComplete: { print("Hold complete - send request!") },
            onHoldCancel: { print("Hold cancelled") }
        )
        .padding()
        Spacer()
    }
}
