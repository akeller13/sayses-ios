import SwiftUI

struct EmailLookupSheet: View {
    @Environment(AuthViewModel.self) private var authViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var emailOrUsername: String = ""
    @FocusState private var isInputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Description
                Text("Melden Sie sich mit Ihrem Benutzernamen oder Ihrer E-Mail-Adresse an")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .padding(.top)

                // Input field
                TextField("Benutzername oder E-Mail", text: $emailOrUsername)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .focused($isInputFocused)
                    .padding(.horizontal)
                    .onSubmit {
                        submitLogin()
                    }

                // Error message
                if let error = authViewModel.errorMessage {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                // Loading indicator
                if authViewModel.isLoading {
                    ProgressView()
                        .scaleEffect(1.2)
                }

                Spacer()
            }
            .navigationTitle("Anmeldung")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") {
                        dismiss()
                    }
                    .disabled(authViewModel.isLoading)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Weiter") {
                        submitLogin()
                    }
                    .fontWeight(.semibold)
                    .disabled(emailOrUsername.trimmingCharacters(in: .whitespaces).isEmpty || authViewModel.isLoading)
                }
            }
            .onAppear {
                // Pre-fill with last used email/username
                emailOrUsername = authViewModel.lastEmail ?? ""
                isInputFocused = true
            }
            .onChange(of: authViewModel.isAuthenticated) { _, isAuthenticated in
                if isAuthenticated {
                    dismiss()
                }
            }
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled(authViewModel.isLoading)
    }

    private func submitLogin() {
        let input = emailOrUsername.trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty else { return }

        Task {
            await authViewModel.lookupAndLogin(emailOrUsername: input)
        }
    }
}

#Preview {
    EmailLookupSheet()
        .environment(AuthViewModel())
}
