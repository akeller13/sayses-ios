import SwiftUI

struct LoginView: View {
    @Environment(AuthViewModel.self) private var authViewModel
    @State private var showEmailSheet = false

    var body: some View {
        VStack(spacing: 40) {
            Spacer()

            // Logo and Title
            VStack(spacing: 16) {
                Image("LaunchLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 120, height: 120)

                Text("SAYses")
                    .font(.system(size: 42, weight: .bold))

                Text("Push-to-Talk Kommunikation")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Login Button
            Button {
                print("[LoginView] Anmelden button tapped, isLoading=\(authViewModel.isLoading)")
                showEmailSheet = true
            } label: {
                HStack {
                    Image(systemName: "person.fill")
                    Text("Anmelden")
                }
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background((authViewModel.isLoading || showEmailSheet) ? Color.gray : Color.semparaPrimary)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 32)
            .disabled(authViewModel.isLoading || showEmailSheet)

            // Version info
            Text("SAYses iOS Version 1.0.0")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 20)
        }
        .onAppear {
            print("[LoginView] onAppear - isLoading=\(authViewModel.isLoading), isAuthenticated=\(authViewModel.isAuthenticated)")
        }
        .sheet(isPresented: $showEmailSheet) {
            EmailLookupSheet()
                .environment(authViewModel)
        }
    }
}

#Preview {
    LoginView()
        .environment(AuthViewModel())
}
