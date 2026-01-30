import SwiftUI
import UIKit

struct ChannelView: View {
    let channel: Channel
    @ObservedObject var mumbleService: MumbleService
    @State private var viewModel: ChannelViewModel
    @State private var showMembers = false
    @State private var showTransmissionMode = false
    @State private var showLeaveConfirmation = false
    @State private var showAudioCast = false
    @State private var lastPttTapTime: Date?  // Time of last quick tap RELEASE
    @State private var pttPressStartTime: Date?  // When current press started
    @State private var alarmTextVisible = true
    @State private var showOpenAlarms = false
    @AppStorage("doubleClickToggleMode") private var doubleClickToggleMode = false
    @AppStorage("keepAwake") private var keepAwake = true
    @AppStorage("transmissionMode") private var transmissionModeRaw = TransmissionMode.pushToTalk.rawValue
    @Environment(\.dismiss) private var dismiss

    init(channel: Channel, mumbleService: MumbleService) {
        self.channel = channel
        self.mumbleService = mumbleService
        self._viewModel = State(initialValue: ChannelViewModel(channel: channel, mumbleService: mumbleService))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                // Channel header
                channelHeader

                // Bluetooth device indicator (if connected)
                if let deviceName = viewModel.connectedBluetoothDevice {
                    bluetoothIndicator(deviceName: deviceName)
                }

                // Speaker mute toggle
                muteToggle

                // PTT Button or Listen-Only indicator - centered in remaining space
                Spacer()

                if viewModel.canSpeak {
                    PttButton(
                        isTransmitting: viewModel.isTransmitting,
                        audioLevel: viewModel.audioLevel,
                        onPressed: {
                            let now = Date()
                            pttPressStartTime = now

                            // Check for double-tap if enabled (two quick taps in succession)
                            if doubleClickToggleMode {
                                if let lastTap = lastPttTapTime,
                                   now.timeIntervalSince(lastTap) < 0.4 {
                                    // Double-tap detected - toggle mode
                                    viewModel.toggleTransmissionMode()
                                    lastPttTapTime = nil
                                    pttPressStartTime = nil
                                    return
                                }
                            }
                            viewModel.startTransmitting()
                        },
                        onReleased: {
                            viewModel.stopTransmitting()

                            // Only record as a "tap" if it was a quick press (< 0.3s)
                            if doubleClickToggleMode,
                               let pressStart = pttPressStartTime,
                               Date().timeIntervalSince(pressStart) < 0.3 {
                                lastPttTapTime = Date()
                            } else {
                                // Long press - reset tap detection
                                lastPttTapTime = nil
                            }
                            pttPressStartTime = nil
                        }
                    )
                    // Allow touch in PTT mode, and also in Continuous mode if double-click toggle is enabled
                    .allowsHitTesting(viewModel.transmissionMode == .pushToTalk || (doubleClickToggleMode && viewModel.transmissionMode == .continuous))
                } else {
                    listenOnlyIndicator
                }

                Spacer()
            }

            // Offline status banner at bottom
            OfflineStatusBanner(secondsUntilRetry: mumbleService.reconnectCountdown)
                .allowsHitTesting(false)
        }
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showLeaveConfirmation = true
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.title2)
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                if !mumbleService.openAlarms.isEmpty {
                    Button(action: { showOpenAlarms = true }) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "bell.fill")
                                .font(.body)
                                .foregroundStyle(Color.alarmRed)

                            Text("\(mumbleService.openAlarms.count)")
                                .font(.caption2)
                                .fontWeight(.bold)
                                .foregroundStyle(.white)
                                .padding(4)
                                .background(Color.alarmRed)
                                .clipShape(Circle())
                                .offset(x: 8, y: -8)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showMembers) {
            MembersSheet(channel: channel, members: viewModel.members)
        }
        .sheet(isPresented: $showTransmissionMode) {
            TransmissionModeSheet()
        }
        .sheet(isPresented: $showOpenAlarms) {
            OpenAlarmsScreen(mumbleService: mumbleService)
        }
        .sheet(isPresented: $showAudioCast) {
            AudioCastScreen(channel: channel, mumbleService: mumbleService)
        }
        .task {
            await viewModel.joinChannel()
        }
        .onAppear {
            if keepAwake {
                UIApplication.shared.isIdleTimerDisabled = true
            }
        }
        .onDisappear {
            viewModel.stopTransmitting()
            // Only disable idle timer if keepAwake setting is off
            if !keepAwake {
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
        // React to transmission mode changes from menu (matches Android's LaunchedEffect pattern)
        .onChange(of: transmissionModeRaw) { oldValue, newValue in
            let oldMode = TransmissionMode(rawValue: oldValue) ?? .pushToTalk
            let newMode = TransmissionMode(rawValue: newValue) ?? .pushToTalk
            viewModel.handleTransmissionModeChange(from: oldMode, to: newMode)
        }
        .alert("Kanal verlassen?", isPresented: $showLeaveConfirmation) {
            Button("Bleiben", role: .cancel) {}
            Button("Verlassen", role: .destructive) {
                viewModel.leaveChannel()
                dismiss()
            }
        } message: {
            Text("Möchtest du den Kanal wirklich verlassen?")
        }
        // Blink animation for ALARM text
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            if !mumbleService.openAlarms.isEmpty {
                withAnimation(.easeInOut(duration: 0.25)) {
                    alarmTextVisible.toggle()
                }
            } else {
                alarmTextVisible = true
            }
        }
    }

    // MARK: - Subviews

    private var channelHeader: some View {
        HStack(spacing: 12) {
            Button(action: { showMembers = true }) {
                Image(systemName: "person.3.fill")
                    .font(.title)
            }

            Text(channel.name)
                .font(.title2)
                .fontWeight(.semibold)

            if viewModel.isFavorite {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
            }

            Spacer()

            Menu {
                Button(action: { viewModel.toggleFavorite() }) {
                    Label(
                        viewModel.isFavorite ? "Aus Favoriten entfernen" : "Zu Favoriten hinzufügen",
                        systemImage: viewModel.isFavorite ? "star" : "star.fill"
                    )
                }
                Button(action: { showTransmissionMode = true }) {
                    Label("Übertragungsmodus", systemImage: "mic")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.title2)
            }
        }
        .padding()
    }

    private func bluetoothIndicator(deviceName: String) -> some View {
        HStack {
            Image(systemName: "bluetooth")
                .foregroundStyle(.blue)
            Text(deviceName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    private var muteToggle: some View {
        HStack {
            Button(action: { viewModel.toggleMute() }) {
                Image(systemName: viewModel.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.title)
                    .foregroundStyle(viewModel.isMuted ? .gray : .primary)
            }

            // AudioCast button (only shown if user has permission)
            if mumbleService.userPermissions.canManageAudiocast ||
               mumbleService.userPermissions.canPlayAudiocast {
                Button(action: { showAudioCast = true }) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.title)
                }
            }

            Spacer()
        }
        .padding(.horizontal)
    }

    private var listenOnlyIndicator: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.gray)
                    .frame(width: 264, height: 264)

                Image(systemName: "ear.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.white)
            }

            Text("In diesem Kanal nur Hören")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    NavigationStack {
        ChannelView(
            channel: Channel(id: 1, name: "Test Channel", userCount: 3),
            mumbleService: MumbleService()
        )
    }
}
