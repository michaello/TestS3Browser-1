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
        if !configData.isEmpty,
           let decoded = try? JSONDecoder().decode(S3Config.self, from: configData) {
            config = decoded
        }
        // Always sync current config to App Group for share extension
        SharedConfig.saveConfig(config)
    }

    private func saveConfig(_ config: S3Config) {
        if let encoded = try? JSONEncoder().encode(config) {
            configData = encoded
        }
        // Also save to shared storage for share extension access
        SharedConfig.saveConfig(config)
    }
}
