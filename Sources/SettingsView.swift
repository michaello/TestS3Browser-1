import SwiftUI

struct SettingsView: View {
    @Binding var config: S3Config
    @State private var isTesting = false
    @State private var testStatus = ""
    @AppStorage("autoPreviewNewPhotos") private var autoPreviewNewPhotos = false
    @State private var starStore = StarStore.shared
    @State private var tagStore = TagStore.shared
    @State private var diskCacheBytes: Int64 = 0
    @State private var confirmClearCache = false
    @State private var confirmClearStars = false
    @State private var confirmClearTags = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Behavior") {
                    Toggle("Auto-preview new photos", isOn: $autoPreviewNewPhotos)

                    Text("Automatically open new photos when returning to the app")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("S3 Bucket") {
                    TextField("Bucket Name", text: $config.bucketName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("Region", text: $config.region)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("Prefix (optional)", text: $config.prefix)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Text("Example: clarityvoice-logs/")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("AWS Credentials") {
                    TextField("Access Key", text: $config.accessKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.username)

                    SecureField("Secret Key", text: $config.secretKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.password)

                    Text("IAM credentials with S3 read permissions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("Test Connection") {
                        testConnection()
                    }
                    .disabled(isTesting || !isConfigValid)

                    if isTesting {
                        HStack {
                            ProgressView()
                            Text("Testing...")
                        }
                    }

                    if !testStatus.isEmpty {
                        Text(testStatus)
                            .font(.caption)
                            .foregroundStyle(testStatus.hasPrefix("✓") ? .green : .red)
                    }
                }

                Section("Storage & Cache") {
                    HStack {
                        Label("Image Cache", systemImage: "photo.on.rectangle")
                        Spacer()
                        Text(formattedBytes(diskCacheBytes))
                            .foregroundStyle(.secondary)
                        Button("Clear") { confirmClearCache = true }
                            .buttonStyle(.bordered)
                            .disabled(diskCacheBytes == 0)
                    }

                    HStack {
                        Label("Starred Files", systemImage: "star")
                        Spacer()
                        Text("\(starStore.starredKeys.count)")
                            .foregroundStyle(.secondary)
                        Button("Clear") { confirmClearStars = true }
                            .buttonStyle(.bordered)
                            .disabled(starStore.starredKeys.isEmpty)
                    }

                    HStack {
                        Label("Tagged Files", systemImage: "tag")
                        Spacer()
                        Text("\(tagStore.tags.count)")
                            .foregroundStyle(.secondary)
                        Button("Clear") { confirmClearTags = true }
                            .buttonStyle(.bordered)
                            .disabled(tagStore.tags.isEmpty)
                    }
                }
            }
            .navigationTitle("Settings")
            .task { await loadCacheSize() }
            .confirmationDialog("Clear image cache?", isPresented: $confirmClearCache, titleVisibility: .visible) {
                Button("Clear Cache", role: .destructive) {
                    Task {
                        await ImageCacheActor.shared.clearCache()
                        await loadCacheSize()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Thumbnails will be re-downloaded as you browse.")
            }
            .confirmationDialog("Remove all stars?", isPresented: $confirmClearStars, titleVisibility: .visible) {
                Button("Remove All Stars", role: .destructive) {
                    starStore.clearAll()
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Remove all tags?", isPresented: $confirmClearTags, titleVisibility: .visible) {
                Button("Remove All Tags", role: .destructive) {
                    tagStore.clearAll()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private var isConfigValid: Bool {
        !config.bucketName.isEmpty && !config.accessKey.isEmpty && !config.secretKey.isEmpty && !config.region.isEmpty
    }

    private func loadCacheSize() async {
        let bytes = await ImageCacheActor.shared.diskCacheSize()
        await MainActor.run { diskCacheBytes = bytes }
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        if bytes == 0 { return "Empty" }
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024
        return String(format: "%.1f MB", mb)
    }

    private func testConnection() {
        isTesting = true
        testStatus = "Testing connection..."

        Task {
            do {
                let service = S3Service(config: config)
                try await service.updateConfig(config)
                try await service.listObjects()
                testStatus = "✓ Connection successful"
            } catch {
                testStatus = "✗ Failed: \(error.localizedDescription)"
            }
            isTesting = false
        }
    }
}

#Preview {
    SettingsView(config: .constant(S3Config.default))
}
