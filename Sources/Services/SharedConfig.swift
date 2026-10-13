import Foundation

/// App/share/intents resolve the same opaque secure credential reference.
@MainActor
enum SharedConfig {
    private static let suiteName = "group.com.crispytoast.TestS3Browser"

    static func saveConfig(_ config: S3Config) throws {
        let repository = try repository(includeLegacyStandard: true)
        try repository.save(config.credentialConfiguration)
    }

    /// Extensions never migrate or fall back to plaintext configuration.
    static func loadConfig() throws -> S3Config? {
        try repository(includeLegacyStandard: false).load().map(S3Config.init)
    }

    static func requireConfig() throws -> S3Config {
        guard let config = try loadConfig() else { throw SecureConfigurationError.missingCredentials }
        return config
    }

    /// Only the main app calls this before creating its service or starting requests.
    static func loadAndMigrateConfig() throws -> S3Config? {
        let repository = try repository(includeLegacyStandard: true)
        guard let material = try repository.loadAndMigrate() else { return nil }
        return S3Config(material)
    }

    private static func repository(includeLegacyStandard: Bool) throws -> SecureConfigurationRepository {
        guard let defaults = UserDefaults(suiteName: suiteName) else { throw SecureConfigurationError.preferenceWriteNotVerified }
        return SecureConfigurationRepository(shared: UserDefaultsConfigurationStore(defaults: defaults),
            standard: includeLegacyStandard ? UserDefaultsConfigurationStore(defaults: .standard) : nil,
            credentials: try AppleKeychainCredentialStore())
    }
}

extension S3Config {
    var credentialConfiguration: CredentialConfiguration {
        CredentialConfiguration(settings: S3PreferenceSettings(bucketName: bucketName, region: region, prefix: prefix),
            credentials: CredentialMaterial(accessKey: accessKey, secretKey: secretKey))
    }

    init(_ stored: CredentialConfiguration) {
        self.init(bucketName: stored.settings.bucketName, region: stored.settings.region,
                  accessKey: stored.credentials.accessKey, secretKey: stored.credentials.secretKey, prefix: stored.settings.prefix)
    }
}
