import Foundation
import ArenaCore

enum TokenStore {
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
