import SwiftUI

struct ProfileView: View {
    @ObservedObject var mumbleService: MumbleService
    @Environment(\.dismiss) private var dismiss

    @State private var showImagePicker = false
    @State private var showCropView = false
    @State private var pickedImage: UIImage?
    @State private var profileImage: UIImage?
    @State private var isUploading = false
    @State private var isLoadingImage = true

    private let apiClient = SemparaAPIClient()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Spacer()
                        avatarView
                            .onTapGesture {
                                showImagePicker = true
                            }
                        Spacer()
                    }
                }
                .listRowBackground(Color.clear)

                Section("Name") {
                    if let firstName = mumbleService.credentials?.firstName,
                       !firstName.isEmpty {
                        LabeledContent("Vorname", value: firstName)
                    }
                    if let lastName = mumbleService.credentials?.lastName,
                       !lastName.isEmpty {
                        LabeledContent("Nachname", value: lastName)
                    }
                }

                Section("Konto") {
                    LabeledContent("Benutzername",
                        value: mumbleService.credentials?.username ?? "–")
                }
            }
            .navigationTitle("Profil")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .sheet(isPresented: $showImagePicker) {
                ImagePicker(isPresented: $showImagePicker) { image in
                    pickedImage = image
                    showCropView = true
                }
            }
            .fullScreenCover(isPresented: $showCropView) {
                if let pickedImage {
                    ImageCropView(sourceImage: pickedImage) { croppedImage in
                        profileImage = croppedImage
                        uploadImage(croppedImage)
                    }
                }
            }
            .task {
                await loadProfileImage()
            }
        }
    }

    @ViewBuilder
    private var avatarView: some View {
        ZStack {
            if let profileImage {
                Image(uiImage: profileImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 80, height: 80)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color.semparaPrimary.opacity(0.2))
                    .frame(width: 80, height: 80)
                    .overlay {
                        if isLoadingImage {
                            ProgressView()
                        } else {
                            Text(initials)
                                .font(.title)
                                .foregroundStyle(Color.semparaPrimary)
                        }
                    }
            }

            if isUploading {
                Circle()
                    .fill(.black.opacity(0.4))
                    .frame(width: 80, height: 80)
                    .overlay {
                        ProgressView()
                            .tint(.white)
                    }
            }

            // Camera badge
            if !isUploading {
                Circle()
                    .fill(Color.semparaPrimary)
                    .frame(width: 24, height: 24)
                    .overlay {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.white)
                    }
                    .offset(x: 28, y: 28)
            }
        }
    }

    private var initials: String {
        let first = mumbleService.credentials?.firstName?.prefix(1) ?? ""
        let last = mumbleService.credentials?.lastName?.prefix(1) ?? ""
        let result = "\(first)\(last)"
        return result.isEmpty
            ? String(mumbleService.credentials?.username.prefix(1) ?? "?")
            : result
    }

    private func loadProfileImage() async {
        guard let subdomain = mumbleService.tenantSubdomain,
              let certificateHash = mumbleService.credentials?.certificateHash,
              let username = mumbleService.credentials?.username else {
            isLoadingImage = false
            return
        }

        // Try loading from local cache first
        if let cached = loadCachedImage(username: username) {
            profileImage = cached
            isLoadingImage = false
        }

        // Then fetch from backend (image + metadata)
        do {
            let response = try await apiClient.fetchUserProfile(
                subdomain: subdomain,
                certificateHash: certificateHash,
                username: username
            )
            if let data = response.imageData, let image = UIImage(data: data) {
                profileImage = image
                saveCachedImage(data: data, username: username)
            }
            // Update current user profile with latest metadata from backend
            mumbleService.updateCurrentUserProfile(
                firstName: response.firstName,
                lastName: response.lastName,
                jobFunction: response.jobFunction
            )
        } catch {
            print("[Profile] Failed to load profile: \(error)")
        }
        isLoadingImage = false
    }

    private func uploadImage(_ image: UIImage) {
        guard let subdomain = mumbleService.tenantSubdomain,
              let certificateHash = mumbleService.credentials?.certificateHash,
              let username = mumbleService.credentials?.username else { return }

        guard let imageData = image.jpegData(compressionQuality: 0.85) else { return }

        isUploading = true

        // Cache locally
        saveCachedImage(data: imageData, username: username)

        Task {
            do {
                try await apiClient.uploadProfileImage(
                    subdomain: subdomain,
                    certificateHash: certificateHash,
                    imageData: imageData
                )
                print("[Profile] Profile image uploaded successfully")
            } catch {
                print("[Profile] Failed to upload profile image: \(error)")
            }
            isUploading = false
        }
    }

    // MARK: - Local Cache

    private func cacheURL(username: String) -> URL {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return cacheDir.appendingPathComponent("profile_\(username).jpg")
    }

    private func loadCachedImage(username: String) -> UIImage? {
        let url = cacheURL(username: username)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    private func saveCachedImage(data: Data, username: String) {
        let url = cacheURL(username: username)
        try? data.write(to: url)
    }
}
