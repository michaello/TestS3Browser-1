import SwiftUI

struct SettingsView: View {
    @Binding var config: S3Config
    @State private var isTesting = false
    @State private var testStatus = ""
    @AppStorage("autoPreviewNewPhotos") private var autoPreviewNewPhotos = false

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
            }
            .navigationTitle("Settings")
        }
    }

    private var isConfigValid: Bool {
        !config.bucketName.isEmpty && !config.accessKey.isEmpty && !config.secretKey.isEmpty && !config.region.isEmpty
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
