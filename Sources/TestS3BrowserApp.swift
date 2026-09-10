import SwiftUI

@main
struct TestS3BrowserApp: App {
    @AppStorage("s3Config") private var configData = Data()
    @State private var config: S3Config

    init() {
        // Resolve saved credentials before ContentView creates its service or starts requests.
        let savedConfig = UserDefaults.standard.data(forKey: "s3Config")
            .flatMap { try? JSONDecoder().decode(S3Config.self, from: $0) }
        _config = State(initialValue: savedConfig ?? SharedConfig.loadConfig() ?? .default)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(config: $config)
                .task {
                    SharedConfig.saveConfig(config)
                }
                .onChange(of: config) { _, newConfig in
                    saveConfig(newConfig)
                }
        }
    }

    private func saveConfig(_ config: S3Config) {
        if let encoded = try? JSONEncoder().encode(config) {
            configData = encoded
        }
        // Also save to shared storage for share extension access
        SharedConfig.saveConfig(config)
    }
}
