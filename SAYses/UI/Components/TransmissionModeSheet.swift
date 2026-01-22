import SwiftUI

struct TransmissionModeSheet: View {
    @AppStorage("transmissionMode") private var transmissionModeRaw = TransmissionMode.pushToTalk.rawValue
    @Environment(\.dismiss) private var dismiss

    private var currentMode: TransmissionMode {
        TransmissionMode(rawValue: transmissionModeRaw) ?? .pushToTalk
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(TransmissionMode.allCases, id: \.self) { mode in
                    Button(action: {
                        transmissionModeRaw = mode.rawValue
                        dismiss()
                    }) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(mode.displayName)
                                    .font(.body)
                                    .foregroundStyle(.primary)

                                Text(mode.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if mode == currentMode {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.semparaPrimary)
                                    .fontWeight(.semibold)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Übertragungsmodus")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fertig") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

#Preview {
    TransmissionModeSheet()
}
