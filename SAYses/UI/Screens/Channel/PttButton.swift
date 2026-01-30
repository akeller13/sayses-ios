import SwiftUI

struct PttButton: View {
    let isTransmitting: Bool
    let audioLevel: Float
    let onPressed: () -> Void
    let onReleased: () -> Void

    @State private var isCurrentlyPressed: Bool = false
    @State private var rotation: Double = 0

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
                    // Dashed rotating border
                    DashedCircle(color: buttonColor)
                        .rotationEffect(.degrees(rotation))

                    // Inner circle
                    Circle()
                        .fill(buttonColor)
                        .padding(6)

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
                withAnimation(.linear(duration: 40).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
            .onDisappear {
                if isCurrentlyPressed {
                    isCurrentlyPressed = false
                    onReleased()
                }
            }
    }
}

struct DashedCircle: View {
    let color: Color
    private let dashCount = 8
    private let dashAngle: Double = 35
    private let gapAngle: Double = 10

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - 2

            for i in 0..<dashCount {
                let startAngle = Angle(degrees: Double(i) * (dashAngle + gapAngle))
                let endAngle = Angle(degrees: Double(i) * (dashAngle + gapAngle) + dashAngle)

                var path = Path()
                path.addArc(
                    center: center,
                    radius: radius,
                    startAngle: startAngle,
                    endAngle: endAngle,
                    clockwise: false
                )

                context.stroke(
                    path,
                    with: .color(color),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )
            }
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
