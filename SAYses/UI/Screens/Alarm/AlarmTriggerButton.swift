import SwiftUI

struct AlarmTriggerButton: View {
    let onTrigger: () -> Void

    @State private var isPressed = false
    @State private var holdProgress: CGFloat = 0
    @State private var holdTask: Task<Void, Never>?

    private let holdDuration: Double = 3.0  // seconds

    var body: some View {
        ZStack {
            // Background
            RoundedRectangle(cornerRadius: 12)
                .fill(isPressed ? Color.alarmRedDark : Color.alarmRed)

            // Progress indicator (always present but invisible when not active)
            HStack {
                Circle()
                    .trim(from: 0, to: holdProgress)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 40, height: 40)
                    .rotationEffect(.degrees(-90))
                    .opacity(holdProgress > 0 ? 1 : 0)
                    .padding(.leading, 24)

                Spacer()
            }

            // Text
            Text("ALARM")
                .font(.title)
                .fontWeight(.bold)
                .foregroundStyle(.white)
        }
        .frame(height: 100)
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
    }

    private func startHold() {
        holdProgress = 0
        holdTask = Task {
            let startTime = Date()

            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(startTime)
                let progress = min(elapsed / holdDuration, 1.0)

                await MainActor.run {
                    holdProgress = CGFloat(progress)
                }

                if progress >= 1.0 {
                    await MainActor.run {
                        onTrigger()
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
        withAnimation(.easeOut(duration: 0.2)) {
            holdProgress = 0
        }
    }
}

#Preview {
    VStack {
        Spacer()
        AlarmTriggerButton(onTrigger: { print("Alarm triggered!") })
            .padding()
    }
}
