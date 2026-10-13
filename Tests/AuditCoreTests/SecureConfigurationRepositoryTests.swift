import Foundation
import Testing
@testable import AuditCore

@MainActor
struct AuditN07 {
    enum Failure: Error { case injected }
    enum PreferenceFault: CaseIterable { case reject, writeThenReject, discard, corrupt }
    enum SecureFault: CaseIterable { case reject, discard, corrupt, readback }

    @MainActor final class Preferences: ConfigurationPreferenceStore {
        var values: [String: Data] = [:]
        var writes: [(String, Data?)] = []
        var faults: [Int: PreferenceFault] = [:]

        func data(forKey key: String) -> Data? { values[key] }
        func set(_ data: Data?, forKey key: String) throws {
            writes.append((key, data))
            switch faults[writes.count] {
            case .reject: throw Failure.injected
            case .writeThenReject:
                values[key] = data
                throw Failure.injected
            case .discard: return
            case .corrupt: values[key] = Data("invalid preference fixture".utf8)
            case nil: values[key] = data
            }
        }
    }

    @MainActor final class Credentials: SecureCredentialStore {
        var values: [String: CredentialMaterial] = [:]
        var writes: [String] = []
        var reads: [String] = []
        var fault: SecureFault?
        var failAllReads = false

        func write(_ material: CredentialMaterial, reference: String) throws {
            writes.append(reference)
            switch fault {
            case .reject: throw Failure.injected
            case .discard: return
            case .corrupt: values[reference] = CredentialMaterial(accessKey: "wrong", secretKey: "wrong")
            default: values[reference] = material
            }
        }
        func read(reference: String) throws -> CredentialMaterial? {
            reads.append(reference)
            if failAllReads || (fault == .readback && writes.contains(reference)) { throw Failure.injected }
            return values[reference]
        }
        func remove(reference: String) throws { values[reference] = nil }
    }

    @MainActor final class Fixture {
        let shared = Preferences()
        let standard = Preferences()
        let credentials = Credentials()
        var serial = 0
        var repository: SecureConfigurationRepository {
            SecureConfigurationRepository(shared: shared, standard: standard, credentials: credentials,
                makeReference: { self.serial += 1; return "opaque-fixture-reference-\(self.serial)" })
        }
    }

    private var configuration: CredentialConfiguration {
        CredentialConfiguration(settings: S3PreferenceSettings(bucketName: "bucket-fixture", region: "test-region", prefix: "exact//prefix/"),
            credentials: CredentialMaterial(accessKey: "dummy-access-N07", secretKey: "dummy-secret-N07"))
    }

    private func legacy(_ configuration: CredentialConfiguration) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "bucketName": configuration.settings.bucketName, "region": configuration.settings.region,
            "prefix": configuration.settings.prefix, "accessKey": configuration.credentials.accessKey,
            "secretKey": configuration.credentials.secretKey
        ])
    }

    @Test func newPreferencesContainOnlySettingsAndOpaqueReference() throws {
        let fixture = Fixture()
        let preferences = try fixture.repository.save(configuration)
        let data = try #require(fixture.shared.values[SecureConfigurationRepository.preferencesKey])
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == ["schemaVersion", "settings", "credentialReference"])
        let settings = try #require(json["settings"] as? [String: String])
        #expect(Set(settings.keys) == ["bucketName", "region", "prefix"])
        let encoded = String(decoding: data, as: UTF8.self)
        #expect(encoded.contains(configuration.credentials.accessKey) == false)
        #expect(encoded.contains(configuration.credentials.secretKey) == false)
        #expect(encoded.contains("accessKey") == false)
        #expect(encoded.contains("secretKey") == false)
        #expect(preferences.credentialReference == "opaque-fixture-reference-1")
        #expect(fixture.credentials.values[preferences.credentialReference] == configuration.credentials)
        #expect(try fixture.repository.load() == configuration)
        #expect(fixture.standard.values.isEmpty)
    }

    @Test func standardMigrationPreservesAppliedSettingsAndUnrelatedStores() throws {
        let fixture = Fixture()
        fixture.standard.values[SecureConfigurationRepository.legacyKey] = try legacy(configuration)
        let outdated = CredentialConfiguration(settings: S3PreferenceSettings(bucketName: "old", region: "old", prefix: ""),
            credentials: CredentialMaterial(accessKey: "old-dummy", secretKey: "old-dummy"))
        fixture.shared.values[SecureConfigurationRepository.legacyKey] = try legacy(outdated)
        let stars = Data("star-fixture".utf8), snapshot = Data("snapshot-fixture".utf8)
        fixture.standard.values["starredKeys"] = stars
        fixture.shared.values["widgetSnapshot"] = snapshot

        #expect(try fixture.repository.loadAndMigrate() == configuration)
        #expect(fixture.standard.values[SecureConfigurationRepository.legacyKey] == nil)
        #expect(fixture.shared.values[SecureConfigurationRepository.legacyKey] == nil)
        #expect(fixture.standard.values["starredKeys"] == stars)
        #expect(fixture.shared.values["widgetSnapshot"] == snapshot)
        #expect(try fixture.repository.load() == configuration)
    }

    @Test func appGroupLegacyMigratesWhenStandardHasNoRecord() throws {
        let fixture = Fixture()
        fixture.shared.values[SecureConfigurationRepository.legacyKey] = try legacy(configuration)
        #expect(try fixture.repository.loadAndMigrate() == configuration)
        #expect(fixture.shared.values[SecureConfigurationRepository.legacyKey] == nil)
        #expect(fixture.credentials.writes.count == 1)
    }

    @Test func extensionAndIntentsReadOnlyCompletedSharedReferences() throws {
        let fixture = Fixture()
        fixture.shared.values[SecureConfigurationRepository.legacyKey] = try legacy(configuration)
        let consumer = SecureConfigurationRepository(shared: fixture.shared, standard: nil, credentials: fixture.credentials)
        #expect(try consumer.load() == nil)
        #expect(fixture.credentials.reads.isEmpty)
        #expect(fixture.shared.writes.isEmpty)
        #expect(try fixture.repository.loadAndMigrate() == configuration)
        #expect(try consumer.load() == configuration)
        #expect(fixture.credentials.writes.count == 1)
    }

    @Test(arguments: SecureFault.allCases)
    func failedSecureWriteOrReadbackRetainsBothLegacySourcesAndRetries(_ fault: SecureFault) throws {
        let fixture = Fixture()
        let data = try legacy(configuration)
        fixture.standard.values[SecureConfigurationRepository.legacyKey] = data
        fixture.shared.values[SecureConfigurationRepository.legacyKey] = data
        fixture.credentials.fault = fault
        #expect(throws: (any Error).self) { try fixture.repository.loadAndMigrate() }
        #expect(fixture.shared.values[SecureConfigurationRepository.preferencesKey] == nil)
        #expect(fixture.standard.values[SecureConfigurationRepository.legacyKey] == data)
        #expect(fixture.shared.values[SecureConfigurationRepository.legacyKey] == data)
        #expect(fixture.standard.writes.isEmpty)
        #expect(fixture.shared.writes.isEmpty)
        fixture.credentials.fault = nil
        #expect(try fixture.repository.loadAndMigrate() == configuration)
        #expect(fixture.standard.values[SecureConfigurationRepository.legacyKey] == nil)
        #expect(fixture.shared.values[SecureConfigurationRepository.legacyKey] == nil)
    }

    @Test(arguments: PreferenceFault.allCases)
    func failedPreferencePublicationRetainsPreviousCredentialsAndLegacy(_ fault: PreferenceFault) throws {
        let fixture = Fixture()
        let first = try fixture.repository.save(configuration)
        let previousData = fixture.shared.values[SecureConfigurationRepository.preferencesKey]
        let legacyData = try legacy(configuration)
        fixture.standard.values[SecureConfigurationRepository.legacyKey] = legacyData
        fixture.shared.values[SecureConfigurationRepository.legacyKey] = legacyData
        let replacement = CredentialConfiguration(settings: configuration.settings,
            credentials: CredentialMaterial(accessKey: "replacement-dummy", secretKey: "replacement-secret-dummy"))
        fixture.shared.faults[fixture.shared.writes.count + 1] = fault
        #expect(throws: (any Error).self) { try fixture.repository.save(replacement) }
        #expect(fixture.shared.values[SecureConfigurationRepository.preferencesKey] == previousData)
        #expect(fixture.credentials.values[first.credentialReference] == configuration.credentials)
        #expect(try fixture.repository.load() == configuration)
        #expect(fixture.standard.values[SecureConfigurationRepository.legacyKey] == legacyData)
        #expect(fixture.shared.values[SecureConfigurationRepository.legacyKey] == legacyData)
        #expect(try fixture.repository.save(replacement).credentialReference != first.credentialReference)
        #expect(try fixture.repository.load() == replacement)
    }

    @Test func failedRollbackIsSurfacedAndExplicitReplacementRecovers() throws {
        let fixture = Fixture()
        let first = try fixture.repository.save(configuration)
        fixture.shared.faults[2] = .corrupt
        fixture.shared.faults[3] = .discard
        let replacement = CredentialConfiguration(settings: configuration.settings,
            credentials: CredentialMaterial(accessKey: "replacement", secretKey: "replacement"))
        #expect(throws: SecureConfigurationError.preferenceRecoveryFailed) { try fixture.repository.save(replacement) }
        #expect(fixture.credentials.values[first.credentialReference] == configuration.credentials)
        #expect(throws: (any Error).self) { try fixture.repository.load() }
        try fixture.repository.save(replacement)
        #expect(try fixture.repository.load() == replacement)
    }

    @Test(arguments: [false, true])
    func legacyCleanupFailureKeepsVerifiedConfigurationAndCanRetry(_ failStandard: Bool) throws {
        let fixture = Fixture()
        let data = try legacy(configuration)
        fixture.standard.values[SecureConfigurationRepository.legacyKey] = data
        fixture.shared.values[SecureConfigurationRepository.legacyKey] = data
        if failStandard { fixture.standard.faults[1] = .reject }
        else { fixture.shared.faults[2] = .discard }
        #expect(throws: SecureConfigurationError.legacyCleanupFailed) { try fixture.repository.loadAndMigrate() }
        #expect(try fixture.repository.load() == configuration)
        #expect(fixture.standard.values[SecureConfigurationRepository.legacyKey] != nil ||
            fixture.shared.values[SecureConfigurationRepository.legacyKey] != nil)
        #expect(try fixture.repository.loadAndMigrate() == configuration)
        #expect(fixture.standard.values[SecureConfigurationRepository.legacyKey] == nil)
        #expect(fixture.shared.values[SecureConfigurationRepository.legacyKey] == nil)
        #expect(fixture.credentials.writes.count == 1)
    }

    @Test func missingOrUnavailableSecureItemDoesNotFallBackToLegacyOrDefaults() throws {
        let fixture = Fixture()
        let first = try fixture.repository.save(configuration)
        fixture.standard.values[SecureConfigurationRepository.legacyKey] = try legacy(configuration)
        fixture.credentials.values[first.credentialReference] = nil
        #expect(throws: SecureConfigurationError.missingCredentials) { try fixture.repository.loadAndMigrate() }
        #expect(fixture.standard.values[SecureConfigurationRepository.legacyKey] != nil)
        fixture.credentials.failAllReads = true
        #expect(throws: Failure.injected) { try fixture.repository.loadAndMigrate() }
        #expect(fixture.standard.writes.isEmpty)
        fixture.credentials.failAllReads = false
        try fixture.repository.save(configuration)
        #expect(try fixture.repository.load() == configuration)
    }

    @Test(arguments: [false, true])
    func malformedOrFuturePreferencesNeverTriggerLegacyFallback(_ futureSchema: Bool) throws {
        let fixture = Fixture()
        let data = futureSchema ? try JSONEncoder().encode(StoredS3Preferences(schemaVersion: 2,
            settings: configuration.settings, credentialReference: "future")) : Data("bad-json".utf8)
        fixture.shared.values[SecureConfigurationRepository.preferencesKey] = data
        fixture.standard.values[SecureConfigurationRepository.legacyKey] = try legacy(configuration)
        #expect(throws: (any Error).self) { try fixture.repository.loadAndMigrate() }
        #expect(fixture.shared.values[SecureConfigurationRepository.preferencesKey] == data)
        #expect(fixture.standard.values[SecureConfigurationRepository.legacyKey] != nil)
        #expect(fixture.credentials.reads.isEmpty)
        #expect(fixture.credentials.writes.isEmpty)
        #expect(fixture.shared.writes.isEmpty)
    }

    @Test func settingsOnlySaveVerifiesAndReusesCredentialReference() throws {
        let fixture = Fixture()
        let first = try fixture.repository.save(configuration)
        let changed = CredentialConfiguration(settings: S3PreferenceSettings(bucketName: "other", region: "test-region", prefix: "new//"),
            credentials: configuration.credentials)
        let second = try fixture.repository.save(changed)
        #expect(second.credentialReference == first.credentialReference)
        #expect(fixture.credentials.writes.count == 1)
        #expect(fixture.credentials.reads.filter { $0 == first.credentialReference }.count >= 2)
        #expect(try fixture.repository.load() == changed)
    }

    @Test func replacementKeepsPriorReferenceAvailableForAlreadyRunningExtension() throws {
        let fixture = Fixture()
        let first = try fixture.repository.save(configuration)
        let replacement = CredentialConfiguration(settings: configuration.settings,
            credentials: CredentialMaterial(accessKey: "new-dummy", secretKey: "new-secret-dummy"))
        let second = try fixture.repository.save(replacement)
        #expect(second.credentialReference != first.credentialReference)
        #expect(try fixture.credentials.read(reference: first.credentialReference) == configuration.credentials)
        #expect(try fixture.repository.load() == replacement)
    }

    @Test func emptyStoresLoadAsUnconfiguredWithoutWriting() throws {
        let fixture = Fixture()
        #expect(try fixture.repository.loadAndMigrate() == nil)
        #expect(fixture.credentials.reads.isEmpty)
        #expect(fixture.credentials.writes.isEmpty)
        #expect(fixture.shared.writes.isEmpty)
        #expect(fixture.standard.writes.isEmpty)
    }
}
