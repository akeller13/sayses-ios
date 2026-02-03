import SwiftUI

struct PttButton: View {
    let isTransmitting: Bool
    let audioLevel: Float
    let onPressed: () -> Void
    let onReleased: () -> Void

    @State private var isCurrentlyPressed: Bool = false
    @State private var pulseScale: CGFloat = 1.0
    @State private var pulseOpacity: Double = 0.4

    private var buttonColor: Color {
        isTransmitting ? .pttActive : .pttInactive
    }

    var body: some View {
        // Fixed size container - gesture will be constrained to this
        Circle()
            .fill(Color.clear)
            .frame(width: 264, height: 264)
            .overlay {
                ZStack {
                    // Pulsing glow ring (outer)
                    Circle()
                        .stroke(buttonColor, lineWidth: 3)
                        .scaleEffect(pulseScale)
                        .opacity(pulseOpacity)

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
            .onAppear {
                startPulseAnimation()
            }
            .onChange(of: isTransmitting) { _, _ in
                // Restart animation with new parameters when state changes
                startPulseAnimation()
            }
            .onDisappear {
                if isCurrentlyPressed {
                    isCurrentlyPressed = false
                    onReleased()
                }
            }
    }

    private func startPulseAnimation() {
        // Reset to initial state
        pulseScale = 1.0
        pulseOpacity = isTransmitting ? 0.6 : 0.4

        // Different animation parameters based on state
        let duration = isTransmitting ? 1.0 : 2.0
        let maxScale: CGFloat = isTransmitting ? 1.12 : 1.06
        let minOpacity = isTransmitting ? 0.2 : 0.15

        withAnimation(
            .easeInOut(duration: duration)
            .repeatForever(autoreverses: true)
        ) {
            pulseScale = maxScale
            pulseOpacity = minOpacity
        }
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
