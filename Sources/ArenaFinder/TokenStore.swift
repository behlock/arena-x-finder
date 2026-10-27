import Foundation
import Security
import ArenaCore

enum TokenStore {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.behlock.arena-x-finder",
         kSecAttrAccount as String: "personal-access-token"]
    }
    static func read() throws -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw BridgeError.message("Couldn’t read your access token from Keychain (\(status)).")
        }
        return token
    }
    static func save(_ token: String) throws {
        try CredentialVault.save(token, trustedPaths: trustedPaths)
    }
    static var trustedPaths: [String] {
        var paths = [Bundle.main.executableURL!.path]
        let provider = Bundle.main.bundleURL.appendingPathComponent("Contents/PlugIns/ArenaProvider.appex/Contents/MacOS/ArenaProvider")
        if FileManager.default.fileExists(atPath: provider.path) { paths.append(provider.path) }
        return paths
    }
}
