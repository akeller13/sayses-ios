import SwiftUI

struct PttButton: View {
    let isTransmitting: Bool
    let audioLevel: Float
    let onPressed: () -> Void
    let onReleased: () -> Void
    var inactiveColor: Color = .pttInactive

    @State private var isCurrentlyPressed: Bool = false

    private var buttonColor: Color {
        isTransmitting ? .pttActive : inactiveColor
    }

    var body: some View {
        // Fixed size container - gesture will be constrained to this
        Circle()
            .fill(Color.clear)
            .frame(width: 264, height: 264)
            .overlay {
                // TimelineView for efficient continuous animation (doesn't accumulate over time)
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    let phase = computePhase(for: timeline.date)

                    ZStack {
                        // Pulsing glow ring (outer)
                        Circle()
                            .stroke(buttonColor, lineWidth: 3)
                            .scaleEffect(phase.scale)
                            .opacity(phase.opacity)

                        // Static inner glow ring
                        Circle()
                            .stroke(buttonColor, lineWidth: 4)
                            .padding(4)
                            .opacity(isTransmitting ? 0.6 : 0.3)

                        // Main circle
                        Circle()
                            .fill(buttonColor)
                            .padding(8)

                        // Microphone icon
                        Image(systemName: "mic.fill")
                            .font(.system(size: 85))
                            .foregroundStyle(.white)
                    }
                }
            }
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isCurrentlyPressed {
                            isCurrentlyPressed = true
                            onPressed()
                        }
                    }
                    .onEnded { _ in
                        if isCurrentlyPressed {
                            isCurrentlyPressed = false
                            onReleased()
                        }
                    }
            )
            .onDisappear {
                if isCurrentlyPressed {
                    isCurrentlyPressed = false
                    onReleased()
                }
            }
    }

    /// Compute animation phase based on current time - no state accumulation
    private func computePhase(for date: Date) -> (scale: CGFloat, opacity: Double) {
        // Different animation parameters based on state
        let duration = isTransmitting ? 1.0 : 2.0
        let maxScale: CGFloat = isTransmitting ? 1.12 : 1.06
        let minScale: CGFloat = 1.0
        let maxOpacity = isTransmitting ? 0.6 : 0.4
        let minOpacity = isTransmitting ? 0.2 : 0.15

        // Calculate phase using time (0.0 to 1.0, oscillating)
        let timeInterval = date.timeIntervalSinceReferenceDate
        let phase = (sin(timeInterval * .pi / duration) + 1.0) / 2.0  // 0.0 to 1.0

        let scale = minScale + (maxScale - minScale) * phase
        let opacity = maxOpacity - (maxOpacity - minOpacity) * phase

        return (scale, opacity)
    }
}

#Preview {
    VStack(spacing: 40) {
        PttButton(
            isTransmitting: false,
            audioLevel: 0,
            onPressed: {},
            onReleased: {}
        )

        PttButton(
            isTransmitting: true,
            audioLevel: 0.5,
            onPressed: {},
            onReleased: {}
        )
    }
}
