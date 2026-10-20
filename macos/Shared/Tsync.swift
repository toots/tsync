import Foundation

/// The identifiers and paths of the installed base (file-provider §3.1, §3.2).
/// Changing any of them orphans existing installations.
enum Tsync {
    static let appBundleID = "org.feverdreamtv.tsync"
    static let appGroup = "group.org.feverdreamtv.tsync"
    static let serviceLabel = "org.feverdreamtv.tsync.daemon"

    /// The identifier scheme this build registers domains under (§9.1 step 6).
    static let identityScheme = 2

    static var groupContainer: URL {
        if let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroup)
        {
            return url
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/\(appGroup)")
    }

    static var configFile: URL { groupContainer.appendingPathComponent("config.json") }

    /// The names of the domains the config lists; none when it cannot be read.
    static func domainNames(_ url: URL = configFile) -> [String] {
        guard
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return (json["domains"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }
    static var dataDir: URL { groupContainer.appendingPathComponent("tsync") }
    static var socketPath: String { dataDir.appendingPathComponent("tsync.sock").path }
    static var resetMarker: URL { dataDir.appendingPathComponent("fileprovider-reset") }
    static var purgeMarker: URL { dataDir.appendingPathComponent("fileprovider-purge") }
    static var identitySchemeRecord: URL {
        dataDir.appendingPathComponent("fileprovider-identity-scheme")
    }
}

/// §3.3: the File Provider domain identifier of a configured display name.
func domainIdentifier(_ name: String) -> String {
    name.lowercased().replacingOccurrences(of: " ", with: "-")
}
