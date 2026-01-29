import SwiftUI

/// Picker view for selecting alarm sound
struct AlarmSoundPicker: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var soundPlayer = AlarmSoundPlayer.shared
    @State private var selectedSound: AlarmSound

    init(selectedSound: AlarmSound = UserDefaults.standard.selectedAlarmSound) {
        _selectedSound = State(initialValue: selectedSound)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(AlarmSound.allCases) { sound in
                        soundRow(sound)
                    }
                } header: {
                    Text("Wählen Sie einen Alarmton")
                } footer: {
                    Text("Tippen Sie auf einen Ton, um ihn anzuhören. Der ausgewählte Ton wird bei einem Alarm abgespielt.")
                }
            }
            .navigationTitle("Alarmton")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Abbrechen") {
                        soundPlayer.stopPreview()
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Speichern") {
                        saveSelection()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onDisappear {
                soundPlayer.stopPreview()
            }
        }
    }

    private func soundRow(_ sound: AlarmSound) -> some View {
        Button(action: {
            selectAndPreview(sound)
        }) {
            HStack {
                // Sound icon
                Image(systemName: soundPlayer.isPlaying && soundPlayer.currentSound == sound
                      ? "speaker.wave.3.fill"
                      : "speaker.wave.2")
                    .foregroundStyle(selectedSound == sound ? Color.semparaPrimary : .secondary)
                    .frame(width: 30)

                // Sound name
                Text(sound.displayName)
                    .foregroundStyle(.primary)

                Spacer()

                // Checkmark for selected
                if selectedSound == sound {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.semparaPrimary)
                        .fontWeight(.semibold)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func selectAndPreview(_ sound: AlarmSound) {
        // Stop any playing preview
        if soundPlayer.isPlaying {
            soundPlayer.stopPreview()

            // If tapping same sound, just stop
            if selectedSound == sound {
                return
            }
        }

        // Select and preview
        selectedSound = sound
        soundPlayer.playPreview(sound: sound)
    }

    private func saveSelection() {
        soundPlayer.stopPreview()
        UserDefaults.standard.selectedAlarmSound = selectedSound
        print("[AlarmSoundPicker] Saved alarm sound: \(selectedSound.displayName)")
        dismiss()
    }
}

// MARK: - Alarm Sound Setting Row (for Settings screen)

/// Row that shows current alarm sound and opens picker
struct AlarmSoundSettingRow: View {
    @State private var showPicker = false
    @State private var currentSound = UserDefaults.standard.selectedAlarmSound

    var body: some View {
        Button(action: { showPicker = true }) {
            HStack {
                Label("Alarmton", systemImage: "bell.badge.waveform")

                Spacer()

                Text(currentSound.displayName)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showPicker) {
            AlarmSoundPicker(selectedSound: currentSound)
        }
        .onChange(of: showPicker) { _, isPresented in
            if !isPresented {
                // Refresh current sound after picker closes
                currentSound = UserDefaults.standard.selectedAlarmSound
            }
        }
    }
}

// MARK: - Preview

#Preview("Picker") {
    AlarmSoundPicker()
}

#Preview("Setting Row") {
    List {
        AlarmSoundSettingRow()
    }
}
