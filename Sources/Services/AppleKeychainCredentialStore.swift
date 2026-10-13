import Foundation
#if os(iOS)
import Security
#endif

/// Used only by the signed iOS app/extension. macOS helpers fail before any Security API.
@MainActor
struct AppleKeychainCredentialStore: SecureCredentialStore {
    let accessGroup: String
    private let service = "com.crispytoast.TestS3Browser.aws-credentials.v1"

    init(bundle: Bundle = .main) throws {
        guard let group = bundle.object(forInfoDictionaryKey: "S3CredentialAccessGroup") as? String,
              !group.isEmpty, !group.contains("$(") else { throw SecureConfigurationError.missingAccessGroup }
        accessGroup = group
    }

    func write(_ material: CredentialMaterial, reference: String) throws {
#if os(iOS)
        let data = try JSONEncoder().encode(material)
        var attributes = query(reference)
        attributes[kSecValueData] = data
        attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecureConfigurationError.secureStoreFailure(status) }
#else
        throw SecureConfigurationError.unsupportedRuntime
#endif
    }

    func read(reference: String) throws -> CredentialMaterial? {
#if os(iOS)
        var attributes = query(reference)
        attributes[kSecReturnData] = true
        attributes[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SecureConfigurationError.secureStoreFailure(status) }
        guard let data = result as? Data else { throw SecureConfigurationError.missingCredentials }
        return try JSONDecoder().decode(CredentialMaterial.self, from: data)
#else
        throw SecureConfigurationError.unsupportedRuntime
#endif
    }

    func remove(reference: String) throws {
#if os(iOS)
        let status = SecItemDelete(query(reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureConfigurationError.secureStoreFailure(status)
        }
#else
        throw SecureConfigurationError.unsupportedRuntime
#endif
    }

#if os(iOS)
    private func query(_ reference: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
         kSecAttrAccount: reference, kSecAttrAccessGroup: accessGroup,
         kSecAttrSynchronizable: false, kSecUseDataProtectionKeychain: true,
         kSecUseAuthenticationUI: kSecUseAuthenticationUIFail]
    }
#endif
}

@MainActor
struct UserDefaultsConfigurationStore: ConfigurationPreferenceStore {
    let defaults: UserDefaults
    func data(forKey key: String) -> Data? { defaults.data(forKey: key) }
    func set(_ data: Data?, forKey key: String) throws {
        if let data { defaults.set(data, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }
}
