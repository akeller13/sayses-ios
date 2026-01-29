import SwiftUI

struct SettingsView: View {
    @AppStorage("keepAwake") private var keepAwake = true
    @AppStorage("speechOutput") private var speechOutput = false
    @AppStorage("transmissionMode") private var transmissionMode = TransmissionMode.pushToTalk.rawValue
    @AppStorage("doubleClickToggleMode") private var doubleClickToggleMode = false
    @Environment(\.dismiss) private var dismiss
    @Environment(AuthViewModel.self) private var authViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Allgemein") {
                    Toggle("Wach bleiben", isOn: $keepAwake)
                    Toggle("Sprachausgabe", isOn: $speechOutput)
                }

                Section("Übertragung") {
                    Picker("Übertragungsmodus", selection: $transmissionMode) {
                        ForEach(TransmissionMode.allCases, id: \.rawValue) { mode in
                            Text(mode.displayName).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.inline)

                    Toggle("Doppelklick: PTT ↔ Ständig", isOn: $doubleClickToggleMode)
                }

                Section("Alarm") {
                    AlarmSoundSettingRow()
                }

                Section("Info") {
                    LabeledContent("Version", value: "1.0.0")
                    LabeledContent("Build", value: "1")
                }

                Section {
                    Button(role: .destructive, action: logout) {
                        HStack {
                            Spacer()
                            Text("Abmelden")
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fertig") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private func logout() {
        authViewModel.logout()
        dismiss()
    }
}

#Preview {
    SettingsView()
        .environment(AuthViewModel())
}
