import SwiftUI

@main
struct TestS3BrowserApp: App {
    @AppStorage("s3Config") private var configData = Data()
    @State private var config: S3Config = S3Config.default

    var body: some Scene {
        WindowGroup {
            ContentView(config: $config)
                .task {
                    loadConfig()
                }
                .onChange(of: config) { _, newConfig in
                    saveConfig(newConfig)
                }
        }
    }

    private func loadConfig() {
        guard !configData.isEmpty else { return }
        if let decoded = try? JSONDecoder().decode(S3Config.self, from: configData) {
            config = decoded
        }
    }

    private func saveConfig(_ config: S3Config) {
        if let encoded = try? JSONEncoder().encode(config) {
            configData = encoded
        }
    }
}
