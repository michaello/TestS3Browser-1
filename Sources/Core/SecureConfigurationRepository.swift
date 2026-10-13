import Foundation

/// Credential values are encoded only into the secure store, never preferences.
struct CredentialMaterial: Codable, Equatable, Sendable {
    let accessKey: String
    let secretKey: String
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.accessKey.utf8.elementsEqual(rhs.accessKey.utf8) && lhs.secretKey.utf8.elementsEqual(rhs.secretKey.utf8)
    }
}

struct S3PreferenceSettings: Codable, Equatable, Sendable {
    let bucketName: String
    let region: String
    let prefix: String
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.bucketName.utf8.elementsEqual(rhs.bucketName.utf8) && lhs.region.utf8.elementsEqual(rhs.region.utf8) &&
            lhs.prefix.utf8.elementsEqual(rhs.prefix.utf8)
    }
}

struct StoredS3Preferences: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let settings: S3PreferenceSettings
    let credentialReference: String
}

struct CredentialConfiguration: Equatable, Sendable {
    let settings: S3PreferenceSettings
    let credentials: CredentialMaterial
}

@MainActor
protocol SecureCredentialStore {
    func write(_ material: CredentialMaterial, reference: String) throws
    func read(reference: String) throws -> CredentialMaterial?
    func remove(reference: String) throws
}

@MainActor
protocol ConfigurationPreferenceStore {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String) throws
}

enum SecureConfigurationError: LocalizedError, Equatable {
    case unsupportedSchema
    case missingCredentials
    case secureWriteNotVerified
    case preferenceWriteNotVerified
    case preferenceRecoveryFailed
    case legacyCleanupFailed
    case unsupportedRuntime
    case missingAccessGroup
    case secureStoreFailure(Int32)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema: return "The saved S3 configuration uses an unsupported format."
        case .missingCredentials: return "Saved S3 credentials could not be found. Re-enter them in Settings."
        case .secureWriteNotVerified: return "The secure credential write could not be verified. The previous configuration was retained."
        case .preferenceWriteNotVerified: return "The configuration could not be saved. The previous configuration was retained."
        case .preferenceRecoveryFailed: return "Configuration storage could not be restored after a failed save. Credentials remain secured. Retry before continuing."
        case .legacyCleanupFailed: return "Credentials are secured, but legacy configuration cleanup failed. Retry migration."
        case .unsupportedRuntime: return "Secure credentials are available only in the signed iOS app or its extensions."
        case .missingAccessGroup: return "The app's shared credential access group is not configured."
        case .secureStoreFailure(let status): return "Secure credential storage is unavailable (status \(status)). Saved configuration was retained."
        }
    }
}

/// This model never performs platform credential access. Only the injected app adapter
/// does that; local regressions use fake stores and synthetic credential material.
@MainActor
struct SecureConfigurationRepository {
    static let preferencesKey = "s3Preferences.v1"
    static let legacyKey = "s3Config"

    let shared: any ConfigurationPreferenceStore
    let standard: (any ConfigurationPreferenceStore)?
    let credentials: any SecureCredentialStore
    var makeReference: () -> String = { UUID().uuidString }

    func load() throws -> CredentialConfiguration? {
        guard let data = shared.data(forKey: Self.preferencesKey) else { return nil }
        let preferences = try JSONDecoder().decode(StoredS3Preferences.self, from: data)
        guard preferences.schemaVersion == 1 else { throw SecureConfigurationError.unsupportedSchema }
        guard let material = try credentials.read(reference: preferences.credentialReference) else {
            throw SecureConfigurationError.missingCredentials
        }
        return CredentialConfiguration(settings: preferences.settings, credentials: material)
    }

    /// The main app alone migrates. Extensions only load a completed secure reference.
    func loadAndMigrate() throws -> CredentialConfiguration? {
        if let current = try load() {
            try removeLegacy()
            return current
        }
        guard let legacy = standard?.data(forKey: Self.legacyKey) ?? shared.data(forKey: Self.legacyKey) else { return nil }
        let decoded = try JSONDecoder().decode(LegacyConfiguration.self, from: legacy)
        let configuration = CredentialConfiguration(
            settings: S3PreferenceSettings(bucketName: decoded.bucketName, region: decoded.region, prefix: decoded.prefix),
            credentials: CredentialMaterial(accessKey: decoded.accessKey, secretKey: decoded.secretKey))
        try save(configuration)
        return configuration
    }

    @discardableResult
    func save(_ configuration: CredentialConfiguration) throws -> StoredS3Preferences {
        let previousData = shared.data(forKey: Self.preferencesKey)
        // A Settings save is an explicit replacement, including recovery from malformed
        // preferences. Loading never falls back or silently replaces an unreadable record.
        let previous = previousData.flatMap { try? JSONDecoder().decode(StoredS3Preferences.self, from: $0) }
        let reference: String
        if let previous, previous.schemaVersion == 1,
           let existing = try credentials.read(reference: previous.credentialReference),
           existing == configuration.credentials {
            reference = previous.credentialReference
        } else {
            reference = makeReference()
            guard !reference.isEmpty, reference != previous?.credentialReference,
                  try credentials.read(reference: reference) == nil else { throw SecureConfigurationError.secureWriteNotVerified }
            try credentials.write(configuration.credentials, reference: reference)
            guard try credentials.read(reference: reference) == configuration.credentials else {
                throw SecureConfigurationError.secureWriteNotVerified
            }
        }
        let preferences = StoredS3Preferences(schemaVersion: 1, settings: configuration.settings, credentialReference: reference)
        let data = try JSONEncoder().encode(preferences)
        do {
            try shared.set(data, forKey: Self.preferencesKey)
            guard shared.data(forKey: Self.preferencesKey) == data else { throw SecureConfigurationError.preferenceWriteNotVerified }
        } catch {
            // Unique references leave the old secure item valid if preference publication fails.
            do {
                try shared.set(previousData, forKey: Self.preferencesKey)
                guard shared.data(forKey: Self.preferencesKey) == previousData else {
                    throw SecureConfigurationError.preferenceRecoveryFailed
                }
            } catch { throw SecureConfigurationError.preferenceRecoveryFailed }
            throw error
        }
        try removeLegacy()
        // Retain prior secure items: an extension can still hold the previous preference
        // reference while the app publishes its replacement. They never enter preferences.
        return preferences
    }

    private func removeLegacy() throws {
        do {
            if standard?.data(forKey: Self.legacyKey) != nil {
                try standard?.set(nil, forKey: Self.legacyKey)
                guard standard?.data(forKey: Self.legacyKey) == nil else { throw SecureConfigurationError.legacyCleanupFailed }
            }
            if shared.data(forKey: Self.legacyKey) != nil {
                try shared.set(nil, forKey: Self.legacyKey)
                guard shared.data(forKey: Self.legacyKey) == nil else { throw SecureConfigurationError.legacyCleanupFailed }
            }
        } catch { throw SecureConfigurationError.legacyCleanupFailed }
    }

    private struct LegacyConfiguration: Decodable {
        let bucketName: String
        let region: String
        let accessKey: String
        let secretKey: String
        let prefix: String
    }
}
