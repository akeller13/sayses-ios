import SwiftUI

struct AlarmTriggerButton: View {
    /// Called when hold starts (Phase 1 start) - start GPS warm-up
    let onHoldStart: () -> Void
    /// Called when hold duration reached (Phase 1 complete) - start voice recording
    let onHoldComplete: () -> Void
    /// Called when user releases before hold completes - cancel warm-up
    let onHoldCancel: () -> Void
    /// The duration in seconds the button must be held (from backend settings)
    let holdDuration: Double

    @State private var isPressed = false
    @State private var holdProgress: CGFloat = 0
    @State private var holdTask: Task<Void, Never>?

    init(
        holdDuration: Double = 3.0,
        onHoldStart: @escaping () -> Void = {},
        onHoldComplete: @escaping () -> Void,
        onHoldCancel: @escaping () -> Void = {}
    ) {
        self.holdDuration = holdDuration
        self.onHoldStart = onHoldStart
        self.onHoldComplete = onHoldComplete
        self.onHoldCancel = onHoldCancel
    }

    var body: some View {
        ZStack {
            // Background
            RoundedRectangle(cornerRadius: 12)
                .fill(isPressed ? Color.alarmRedDark : Color.alarmRed)

            // Progress indicator (always present but invisible when not active)
            HStack {
                ZStack {
                    // Background circle
                    Circle()
                        .stroke(Color.white.opacity(0.3), lineWidth: 4)
                        .frame(width: 40, height: 40)

                    // Progress circle
                    Circle()
                        .trim(from: 0, to: holdProgress)
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .frame(width: 40, height: 40)
                        .rotationEffect(.degrees(-90))
                }
                .opacity(holdProgress > 0 ? 1 : 0)
                .padding(.leading, 24)

                Spacer()
            }

            // Text (no animation)
            HStack(spacing: 12) {
                if isPressed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title2)
                }

                Text("ALARM")
                    .font(.title)
                    .fontWeight(.bold)
            }
            .foregroundStyle(.white)
        }
        .frame(height: 100)
        .shadow(color: isPressed ? Color.alarmRed.opacity(0.5) : .clear, radius: 10)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !isPressed else { return }
                    isPressed = true
                    startHold()
                }
                .onEnded { _ in
                    isPressed = false
                    cancelHold()
                }
        )
        .sensoryFeedback(.impact(weight: .heavy), trigger: isPressed)
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
                        generator.notificationOccurred(.warning)

                        onHoldComplete()
                        holdProgress = 0
                        isPressed = false
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
        if holdProgress < 1.0 {
            onHoldCancel()
        }

        withAnimation(.easeOut(duration: 0.2)) {
            holdProgress = 0
        }
    }
}

// MARK: - Legacy initializer for compatibility

extension AlarmTriggerButton {
    /// Legacy initializer for backward compatibility
    init(onTrigger: @escaping () -> Void) {
        self.init(
            holdDuration: 3.0,
            onHoldStart: {},
            onHoldComplete: onTrigger,
            onHoldCancel: {}
        )
    }
}

#Preview {
    VStack {
        Spacer()
        AlarmTriggerButton(
            holdDuration: 3.0,
            onHoldStart: { print("Hold started - warming up GPS") },
            onHoldComplete: { print("Hold complete - show countdown!") },
            onHoldCancel: { print("Hold cancelled") }
        )
        .padding()
    }
}
