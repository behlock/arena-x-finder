import Foundation
import Security

// Use the macOS login keychain with an explicit trusted-application ACL. This
// supports a locally signed app + extension without a provisioned iOS-style
// Keychain access group. No credential is written into the shared container.
public enum CredentialVault {
    private static func query(service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "personal-access-token"]
    }
    public static func read(service: String = "com.behlock.arena-x-finder", interactive: Bool = true) throws -> String? {
        var query = query(service: service)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !interactive { query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw BridgeError.message("Open Are.na x Finder and reconnect your account to allow Keychain access (\(status)).")
        }
        return token
    }
    public static func save(_ token: String, trustedPaths: [String], service: String = "com.behlock.arena-x-finder") throws {
        var applications: [SecTrustedApplication] = []
        for path in trustedPaths {
            var application: SecTrustedApplication?
            let status = SecTrustedApplicationCreateFromPath(path, &application)
            guard status == errSecSuccess, let application else { throw BridgeError.message("Could not authorize the signed Finder extension (\(status)).") }
            applications.append(application)
        }
        guard !applications.isEmpty else { throw BridgeError.message("No trusted app was provided for Keychain access.") }
        var access: SecAccess?
        let status = SecAccessCreate("Are.na x Finder access token" as CFString, applications as CFArray, &access)
        guard status == errSecSuccess, let access else { throw BridgeError.message("Could not prepare Keychain access (\(status)).") }
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8), kSecAttrAccess as String: access]
        let query = query(service: service)
        var result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound { result = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) }
        guard result == errSecSuccess else { throw BridgeError.message("Could not save your access token in Keychain (\(result)).") }
    }
    public static func removeSmokeCredential() { SecItemDelete(query(service: "com.behlock.arena-x-finder.smoke") as CFDictionary) }
}
