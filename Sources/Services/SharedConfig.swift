import Foundation

/// Shared configuration storage using App Groups UserDefaults.
/// Both the main app and share extension use the same app group container.
enum SharedConfig {
    private static let suiteName = "group.com.crispytoast.TestS3Browser"
    private static let configKey = "s3Config"

    /// Saves S3Config to shared App Groups UserDefaults
    static func saveConfig(_ config: S3Config) {
        guard let data = try? JSONEncoder().encode(config) else {
            print("[SharedConfig] Failed to encode config")
            return
        }
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            print("[SharedConfig] Failed to access App Group UserDefaults with suite: \(suiteName)")
            return
        }
        defaults.set(data, forKey: configKey)
        defaults.synchronize()
        print("[SharedConfig] Config saved to App Group UserDefaults")
    }

    /// Loads S3Config from shared App Groups UserDefaults
    static func loadConfig() -> S3Config? {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            print("[SharedConfig] Failed to access App Group UserDefaults with suite: \(suiteName)")
            return nil
        }
        guard let data = defaults.data(forKey: configKey) else {
            print("[SharedConfig] No config data found in App Group UserDefaults")
            return nil
        }
        guard let config = try? JSONDecoder().decode(S3Config.self, from: data) else {
            print("[SharedConfig] Failed to decode config from App Group UserDefaults")
            return nil
        }
        print("[SharedConfig] Config loaded from App Group UserDefaults")
        return config
    }
}
