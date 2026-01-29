import SwiftUI
import SwiftData
import MapKit

/// Screen showing all open/active alarms
struct OpenAlarmsScreen: View {
    @ObservedObject var mumbleService: MumbleService
    @Environment(\.dismiss) private var dismiss

    // Alert state for showing alerts on this screen
    @State private var showAlarmAlert = false
    @State private var showEndAlarmAlert = false

    var body: some View {
        NavigationStack {
            Group {
                if mumbleService.openAlarms.isEmpty {
                    emptyStateView
                } else {
                    alarmListView
                }
            }
            .navigationTitle("Offene Alarme")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fertig") {
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            Task { @MainActor in
                mumbleService.refreshOpenAlarms()
            }
            // Sync alert state on appear
            showAlarmAlert = mumbleService.receivedAlarmForAlert != nil
            showEndAlarmAlert = mumbleService.receivedEndAlarmForAlert != nil
        }
        // Alarm alert (new alarm received)
        .fullScreenCover(isPresented: $showAlarmAlert) {
            if let alarm = mumbleService.receivedAlarmForAlert {
                AlarmAlertDialog(
                    alarm: alarm,
                    onDismiss: {
                        mumbleService.dismissReceivedAlarm()
                        showAlarmAlert = false
                    }
                )
            }
        }
        .onChange(of: mumbleService.receivedAlarmForAlert) { oldValue, newValue in
            showAlarmAlert = newValue != nil
        }
        // End alarm alert (alarm ended)
        .fullScreenCover(isPresented: $showEndAlarmAlert) {
            if let endAlarm = mumbleService.receivedEndAlarmForAlert {
                EndAlarmAlertDialog(
                    endAlarm: endAlarm,
                    onDismiss: {
                        mumbleService.dismissEndAlarmAlert()
                        showEndAlarmAlert = false
                    }
                )
            }
        }
        .onChange(of: mumbleService.receivedEndAlarmForAlert) { oldValue, newValue in
            showEndAlarmAlert = newValue != nil
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green)

            Text("Keine offenen Alarme")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Alle Alarme wurden bearbeitet.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var alarmListView: some View {
        List {
            ForEach(mumbleService.openAlarms, id: \.alarmId) { alarm in
                AlarmRowView(
                    alarm: alarm,
                    canEndAlarm: mumbleService.userPermissions.canEndAlarm,
                    onEndAlarm: {
                        Task {
                            await mumbleService.endAlarm(alarmId: alarm.alarmId)
                        }
                    },
                    onDownloadVoiceMessage: { backendAlarmId in
                        await mumbleService.downloadVoiceMessage(backendAlarmId: backendAlarmId)
                    }
                )
                // Dynamic ID forces re-render when location or voice message updates
                .id("\(alarm.alarmId)-\(alarm.hasRemoteVoiceMessage)")
                .onAppear {
                    print("[OpenAlarmsScreen] Alarm row appearing: \(alarm.alarmId)")
                    print("[OpenAlarmsScreen]   hasVoiceMessage=\(alarm.hasVoiceMessage)")
                    print("[OpenAlarmsScreen]   hasRemoteVoiceMessage=\(alarm.hasRemoteVoiceMessage)")
                    print("[OpenAlarmsScreen]   voiceMessagePath=\(alarm.voiceMessagePath ?? "nil")")
                    print("[OpenAlarmsScreen]   backendAlarmId=\(alarm.backendAlarmId ?? "nil")")
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            mumbleService.refreshOpenAlarms()
        }
    }
}

// MARK: - Alarm Row View

struct AlarmRowView: View {
    @Bindable var alarm: AlarmEntity
    let canEndAlarm: Bool
    let onEndAlarm: () -> Void
    let onDownloadVoiceMessage: ((String) async -> URL?)?

    @StateObject private var voicePlayer = VoicePlayer()
    @State private var showEndConfirmation = false
    @State private var isDownloading = false
    @State private var localVoicePath: URL?

    private var formattedReceivedAt: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy HH:mm:ss"
        formatter.locale = Locale(identifier: "de_DE")
        return formatter.string(from: alarm.receivedAt)
    }

    private var formattedLocationUpdatedAt: String? {
        guard let date = alarm.locationUpdatedAt else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy HH:mm:ss"
        formatter.locale = Locale(identifier: "de_DE")
        return formatter.string(from: date)
    }

    private var formattedLocationDate: String? {
        guard let date = alarm.locationUpdatedAt else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy"
        formatter.locale = Locale(identifier: "de_DE")
        return formatter.string(from: date)
    }

    private var formattedLocationTime: String? {
        guard let date = alarm.locationUpdatedAt else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.locale = Locale(identifier: "de_DE")
        return formatter.string(from: date)
    }

    private var locationTypeText: String? {
        guard let locationType = alarm.locationType else { return nil }
        return locationType == "gps" ? "GPS" : "Netzwerk"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header with end button (like Android)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    // User name (bold, dark red)
                    Text(alarm.effectiveName)
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(Color(red: 0.72, green: 0.11, blue: 0.11)) // Dark red like Android

                    // Channel name
                    Text("Kanal: \(alarm.channelName)")
                        .font(.subheadline)

                    // Received timestamp
                    Text("Empfangen: \(formattedReceivedAt)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

            }

            // Location section
            if alarm.hasLocation, let lat = alarm.latitude, let lon = alarm.longitude {
                locationSection(latitude: lat, longitude: lon)
                    .padding(.top, 4)
            }

            // Voice message section
            if alarm.hasVoiceMessage {
                voiceMessageSection
                    .padding(.top, 4)
            }

            // End alarm button (bottom row)
            if canEndAlarm {
                Button(action: {
                    showEndConfirmation = true
                }) {
                    Text("Alarm schließen")
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .foregroundStyle(Color(red: 0.72, green: 0.11, blue: 0.11))
                }
                .buttonStyle(.borderless)
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 8)
        .confirmationDialog(
            "Alarm beenden?",
            isPresented: $showEndConfirmation,
            titleVisibility: .visible
        ) {
            Button("Alarm beenden", role: .destructive) {
                onEndAlarm()
            }
            Button("Abbrechen", role: .cancel) { }
        } message: {
            Text("Der Alarm von \(alarm.effectiveName) wird für alle Benutzer geschlossen.")
        }
    }

    private func locationSection(latitude: Double, longitude: Double) -> some View {
        HStack(alignment: .top) {
            // Clickable location link (left column)
            Button(action: {
                openInMaps(latitude: latitude, longitude: longitude)
            }) {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "location.fill")
                        .font(.subheadline)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Standort öffnen")
                            .font(.subheadline)

                        if let typeText = locationTypeText {
                            Text("(\(typeText))")
                                .font(.subheadline)
                        }
                    }
                }
                .foregroundStyle(Color(red: 0.1, green: 0.46, blue: 0.82)) // Blue like Android
            }
            .buttonStyle(.borderless)

            Spacer()

            // Location update timestamp (right column)
            if let date = formattedLocationDate, let time = formattedLocationTime {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(time)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var voiceMessageSection: some View {
        Button(action: {
            handleVoiceMessageTap()
        }) {
            HStack(spacing: 4) {
                if isDownloading {
                    ProgressView()
                        .scaleEffect(0.8)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: voicePlayer.isPlaying ? "stop.fill" : "play.fill")
                        .font(.subheadline)
                }

                Text(voiceMessageButtonText)
                    .font(.subheadline)
            }
            .foregroundStyle(voicePlayer.isPlaying
                ? Color(red: 0.83, green: 0.18, blue: 0.18) // Red when playing
                : Color(red: 0.1, green: 0.46, blue: 0.82)) // Blue like Android
        }
        .buttonStyle(.borderless)
        .disabled(isDownloading)
    }

    private var voiceMessageButtonText: String {
        if isDownloading {
            return "Laden..."
        } else if voicePlayer.isPlaying {
            return "Stoppen"
        } else {
            return "Sprachnachricht abspielen"
        }
    }

    private func handleVoiceMessageTap() {
        print("[AlarmRowView] handleVoiceMessageTap called")
        print("[AlarmRowView]   voicePlayer.isPlaying=\(voicePlayer.isPlaying)")
        print("[AlarmRowView]   localVoicePath=\(localVoicePath?.path ?? "nil")")
        print("[AlarmRowView]   alarm.voiceMessagePath=\(alarm.voiceMessagePath ?? "nil")")
        print("[AlarmRowView]   alarm.hasRemoteVoiceMessage=\(alarm.hasRemoteVoiceMessage)")
        print("[AlarmRowView]   alarm.backendAlarmId=\(alarm.backendAlarmId ?? "nil")")

        if voicePlayer.isPlaying {
            // Stop playback
            print("[AlarmRowView] Stopping playback")
            voicePlayer.stop()
            return
        }

        // Check if we have a local path (either from alarm or from previous download)
        if let path = localVoicePath, FileManager.default.fileExists(atPath: path.path) {
            // Play local file
            print("[AlarmRowView] Playing from localVoicePath: \(path)")
            voicePlayer.play(from: path)
            return
        }

        // Check if there's a local path stored in the alarm
        if let pathString = alarm.voiceMessagePath {
            let url = URL(fileURLWithPath: pathString)
            if FileManager.default.fileExists(atPath: url.path) {
                print("[AlarmRowView] Playing from alarm.voiceMessagePath: \(url)")
                localVoicePath = url
                voicePlayer.play(from: url)
                return
            } else {
                print("[AlarmRowView] File doesn't exist at alarm.voiceMessagePath")
            }
        }

        // Need to download from backend
        if alarm.hasRemoteVoiceMessage, let backendAlarmId = alarm.backendAlarmId {
            print("[AlarmRowView] Downloading from backend with alarmId: \(backendAlarmId)")
            Task {
                await downloadAndPlayVoiceMessage(backendAlarmId: backendAlarmId)
            }
        } else {
            print("[AlarmRowView] Cannot download: hasRemoteVoiceMessage=\(alarm.hasRemoteVoiceMessage), backendAlarmId=\(alarm.backendAlarmId ?? "nil")")
        }
    }

    @MainActor
    private func downloadAndPlayVoiceMessage(backendAlarmId: String) async {
        guard let downloadCallback = onDownloadVoiceMessage else {
            print("[AlarmRowView] No download callback provided")
            return
        }

        print("[AlarmRowView] Starting download for backendAlarmId: \(backendAlarmId)")
        isDownloading = true

        if let downloadedPath = await downloadCallback(backendAlarmId) {
            print("[AlarmRowView] Download complete: \(downloadedPath.path)")
            print("[AlarmRowView] File exists: \(FileManager.default.fileExists(atPath: downloadedPath.path))")
            localVoicePath = downloadedPath
            print("[AlarmRowView] Playing downloaded file...")
            voicePlayer.play(from: downloadedPath)
        } else {
            print("[AlarmRowView] Download failed - callback returned nil")
        }

        isDownloading = false
    }

    private func openInMaps(latitude: Double, longitude: Double) {
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let placemark = MKPlacemark(coordinate: coordinate)
        let mapItem = MKMapItem(placemark: placemark)
        mapItem.name = "Alarm: \(alarm.effectiveName)"
        mapItem.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving
        ])
    }
}

// MARK: - Preview

#Preview {
    OpenAlarmsScreen(mumbleService: MumbleService())
}
