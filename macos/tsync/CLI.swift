import ArgumentParser
import Foundation

@main
@available(macOS 10.15, *)
struct Tsync: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "S3-backed file sync via macOS FileProvider",
        subcommands: [
            InitCommand.self, Start.self, Stop.self, Status.self,
            Evict.self, Restore.self, Pull.self, Ls.self,
            History.self, Purge.self, Wait.self, Sync.self,
        ]
    )
}

// MARK: - tsync init

struct InitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Create config, store AWS credentials, install LaunchAgent"
    )

    @Option(name: .long, help: "S3 bucket name") var bucket: String
    @Option(name: .long, help: "S3 key prefix") var prefix: String = "tsync"
    @Option(name: .long, help: "AWS region") var region: String = "us-east-1"
    @Option(name: .long, help: "Comma-separated domain names") var domains: String = "Music Production"
    @Flag(name: .long, help: "Enable versioning (trash on delete)") var versioning: Bool = false

    func run() async throws {
        print("AWS Access Key ID: ", terminator: "")
        let keyId = readLine(strippingNewline: true) ?? ""
        print("AWS Secret Access Key: ", terminator: "")
        let secret = readLine(strippingNewline: true) ?? ""

        let credentials = AWSCredentials(accessKeyId: keyId, secretAccessKey: secret)
        try KeychainCredentials.store(credentials)
        print("Credentials stored in Keychain")

        let domainList = domains.split(separator: ",").map {
            DomainConfig(name: $0.trimmingCharacters(in: .whitespaces))
        }
        let config = Config(bucket: bucket, prefix: prefix, awsRegion: region, versioning: versioning, domains: domainList)
        try config.save()
        print("Config saved to \(Config.groupContainerURL.appendingPathComponent("config.json").path)")

        try installLaunchAgent()
        print("LaunchAgent installed — run `tsync start` to activate")
    }

    private func installLaunchAgent() throws {
        let appPath = Bundle.main.bundlePath
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>com.toots.tsync</string>
            <key>ProgramArguments</key>
            <array><string>\(appPath)/Contents/MacOS/TsyncApp</string></array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><true/>
        </dict>
        </plist>
        """
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try plist.write(to: dir.appendingPathComponent("com.toots.tsync.plist"), atomically: true, encoding: .utf8)
    }
}

// MARK: - tsync start / stop / status

struct Start: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Start the sync daemon")
    func run() async throws {
        print(shell("launchctl", "load", "-w", launchAgentPlist()))
    }
}

struct Stop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stop the sync daemon")
    func run() async throws {
        print(shell("launchctl", "unload", launchAgentPlist()))
    }
}

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show daemon and domain status")
    func run() async throws {
        print(shell("launchctl", "list", "com.toots.tsync"))
        let config = try Config.load()
        for domain in config.domains {
            let url = cloudStorageURL(domainName: domain.name)
            let exists = FileManager.default.fileExists(atPath: url.path)
            print("Domain: \(domain.name) — \(exists ? url.path : "(not mounted)")")
        }
    }
}

// MARK: - tsync evict / restore / wait

struct Evict: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Evict a file (free local space)")
    @Argument(help: "Path to file") var path: String

    func run() async throws {
        let resp = try IPC.send(IPCRequest(action: "evict", path: (path as NSString).expandingTildeInPath))
        if let err = resp.error { throw ValidationError(err) }
        print("Evicted: \(path)")
    }
}

struct Restore: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Download a placeholder file")
    @Argument(help: "Path to file") var path: String

    func run() async throws {
        let resp = try IPC.send(IPCRequest(action: "restore", path: (path as NSString).expandingTildeInPath))
        if let err = resp.error { throw ValidationError(err) }
        print("Download requested: \(path)")
    }
}

struct Pull: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Download all evicted files in a directory")
    @Argument(help: "Path (defaults to first domain root)") var path: String?
    @Flag(name: .long, help: "Download even files already local") var force: Bool = false

    func run() async throws {
        let config = try Config.load()
        guard let domain = config.domains.first else { print("No domains configured."); return }
        let base = path.map { URL(filePath: $0) } ?? cloudStorageURL(domainName: domain.name)

        let items = try FileManager.default.enumerator(
            at: base,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: .skipsHiddenFiles
        )?.compactMap { $0 as? URL } ?? []

        var queued = 0
        for item in items {
            let v = try item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            guard v.isDirectory != true else { continue }
            let isEvicted = (v.fileSize ?? 0) == 0
            guard isEvicted || force else { continue }
            let resp = try IPC.send(IPCRequest(action: "restore", path: item.path))
            if let err = resp.error { print("  skip \(item.lastPathComponent): \(err)") }
            else { print("  queued \(item.lastPathComponent)"); queued += 1 }
        }
        print("Queued \(queued) file(s) for download.")
    }
}

struct Wait: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Wait until a file is downloaded (for scripts)")
    @Argument(help: "Path to file") var path: String
    @Option(name: .long, help: "Poll interval in seconds") var interval: Double = 0.5
    @Option(name: .long, help: "Timeout in seconds (0 = no timeout)") var timeout: Double = 0

    func run() async throws {
        let start = Date()
        while true {
            let values = try URL(filePath: path).resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            if values.ubiquitousItemDownloadingStatus == .current {
                print("Ready: \(path)")
                return
            }
            if timeout > 0, Date().timeIntervalSince(start) > timeout {
                throw ExitCode(1)
            }
            try await Task.sleep(for: .seconds(interval))
        }
    }
}

// MARK: - tsync ls

struct Ls: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List files with sync status")
    @Argument(help: "Path (defaults to first domain root)") var path: String?
    @Flag(name: .shortAndLong, help: "Recurse into subdirectories") var recursive: Bool = false

    func run() async throws {
        let config = try Config.load()
        guard let domain = config.domains.first else { print("No domains configured."); return }
        let base = path.map { URL(filePath: $0) } ?? cloudStorageURL(domainName: domain.name)

        let keys: Set<URLResourceKey> = [
            .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsUploadedKey,
            .ubiquitousItemIsUploadingKey, .fileSizeKey, .isDirectoryKey
        ]

        let items: [URL]
        if recursive {
            items = (FileManager.default.enumerator(
                at: base, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles
            )?.compactMap { $0 as? URL } ?? []).sorted { $0.path < $1.path }
        } else {
            items = try FileManager.default.contentsOfDirectory(
                at: base, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        }

        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        for item in items {
            let v = try item.resourceValues(forKeys: keys)
            guard v.isDirectory != true else { continue }
            let up: String
            if v.ubiquitousItemIsUploading == true     { up = "uploading" }
            else if v.ubiquitousItemIsUploaded == true  { up = "uploaded " }
            else                                        { up = "pending  " }
            let down: String
            switch v.ubiquitousItemDownloadingStatus {
            case .current:       down = "local"
            case .notDownloaded: down = "cloud"
            case .downloaded:    down = "stale"
            default:             down = "?    "
            }
            let size = v.fileSize.map { fmt.string(fromByteCount: Int64($0)) } ?? ""
            let displayPath = recursive ? item.path.replacingOccurrences(of: base.path + "/", with: "") : item.lastPathComponent
            print("\(up)  \(down)  \(displayPath)  \(size)")
        }
    }
}

// MARK: - tsync history / purge

struct History: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show version history for a file")
    @Argument(help: "Path to file") var path: String

    func run() async throws {
        let (store, s3Key) = try s3Context(for: path)
        defer { try? store.client.shutdown() }
        let entries = try await Versioning.history(for: s3Key, store: store)
        guard !entries.isEmpty else { print("No history found."); return }

        let iso = ISO8601DateFormatter()
        let sizeFmt = ByteCountFormatter()
        sizeFmt.countStyle = .file
        for e in entries.sorted(by: { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }) {
            print("\(e.date.map { iso.string(from: $0) } ?? "unknown")  \(sizeFmt.string(fromByteCount: e.size))  \(e.key)")
        }
    }
}

struct Purge: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Delete all versions from trash")
    @Argument(help: "Path to file") var path: String

    func run() async throws {
        let (store, s3Key) = try s3Context(for: path)
        defer { try? store.client.shutdown() }
        let entries = try await Versioning.history(for: s3Key, store: store)
        for e in entries { try await store.client.delete(key: e.key); print("Deleted \(e.key)") }
        print("Purged \(entries.count) version(s).")
    }
}

// MARK: - tsync sync

struct Sync: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Apply remote changes to local cache")

    @Option(name: .long, help: "Domain name (default: first configured)") var domain: String?

    func run() async throws {
        let config = try Config.load()
        guard let domainName = domain ?? config.domains.first?.name else {
            throw ValidationError("No domains configured.")
        }
        let credentials = try KeychainCredentials.load()
        let client = S3Client(bucket: config.bucket, region: config.awsRegion, credentials: credentials)
        let store = S3Store(client: client, config: config, domainName: domainName)
        defer { try? store.client.shutdown() }

        let lastSyncURL = Config.groupContainerURL.appendingPathComponent("last-sync-\(domainName)")
        let lastSyncKey = (try? String(contentsOf: lastSyncURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""

        try await store.recoverPendingOps(mountURL: cloudStorageURL(domainName: domainName))

        var doFullResync = lastSyncKey.isEmpty
        if !doFullResync {
            let oldest = try await client.listKeys(prefix: store.journalPrefix, maxKeys: 1)
            if let oldestKey = oldest.first {
                let oldestMs = Journal.timestampMs(fromFilename: oldestKey.components(separatedBy: "/").last ?? oldestKey)
                let lastMs = Journal.timestampMs(fromFilename: lastSyncKey.components(separatedBy: "/").last ?? lastSyncKey)
                if oldestMs > lastMs { doFullResync = true }
            }
        }

        if doFullResync {
            let resp = try IPC.send(IPCRequest(action: "fullResync"))
            if let err = resp.error { throw ValidationError(err) }
            let newKey = store.journalPrefix + Journal.entryKey()
            try newKey.write(to: lastSyncURL, atomically: true, encoding: .utf8)
            print("Full resync triggered.")
        } else {
            let entries = try await store.listJournal(startAfter: lastSyncKey.isEmpty ? nil : lastSyncKey)
            let myUUID = Journal.clientUUID()
            let foreign = entries.filter { $0.clientUUID != myUUID }

            var uniqueKeys = Set<String>()
            var parentDirsToSignal = Set<String>()
            let mountURL = cloudStorageURL(domainName: domainName)
            for entry in foreign {
                for op in entry.ops {
                    uniqueKeys.insert(op.key)
                    if let src = op.src { uniqueKeys.insert(src) }
                    // Structural ops need the parent directory re-enumerated so the
                    // platform removes stale entries and discovers new ones.
                    if ["delete", "rename", "rmdir", "mkdir"].contains(op.op) {
                        parentDirsToSignal.insert(
                            mountURL.appendingPathComponent(op.key)
                                .deletingLastPathComponent().path
                        )
                        if let src = op.src {
                            parentDirsToSignal.insert(
                                mountURL.appendingPathComponent(src)
                                    .deletingLastPathComponent().path
                            )
                        }
                    }
                }
            }

            var evicted = 0
            for relKey in uniqueKeys {
                let path = mountURL.appendingPathComponent(relKey).path
                let resp = try IPC.send(IPCRequest(action: "evict", path: path))
                if resp.ok { evicted += 1 }
            }

            // Signal each affected parent directory; fall back to full working-set
            // signal if any directory lookup fails (e.g. the dir was itself deleted).
            var signalFailed = false
            for dirPath in parentDirsToSignal {
                let resp = try IPC.send(IPCRequest(action: "signalDirectory", path: dirPath))
                if !resp.ok { signalFailed = true; break }
            }
            if signalFailed {
                let resp = try IPC.send(IPCRequest(action: "fullResync"))
                if let err = resp.error { print("Warning: re-enumeration signal failed: \(err)") }
            }

            if let last = entries.last {
                try last.s3Key.write(to: lastSyncURL, atomically: true, encoding: .utf8)
            }
            print("Applied \(evicted) eviction(s) from \(foreign.count) remote change(s).")
        }
    }
}

// MARK: - Helpers

/// Scans ~/Library/CloudStorage/ for a mount matching the domain name.
private func cloudStorageURL(domainName: String) -> URL {
    let cloudStorage = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/CloudStorage")
    let suffix = "-" + domainName.replacingOccurrences(of: " ", with: "")
    let candidates = (try? FileManager.default.contentsOfDirectory(
        at: cloudStorage, includingPropertiesForKeys: nil)) ?? []
    return candidates.first { $0.lastPathComponent.hasSuffix(suffix) } ?? cloudStorage
}

private func extractDomainName(from path: String, config: Config) -> String {
    let cloudStorage = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/CloudStorage").path
    let relative = path.hasPrefix(cloudStorage) ? String(path.dropFirst(cloudStorage.count + 1)) : ""
    let folder = relative.components(separatedBy: "/").first ?? ""
    // Mount format: <AppName>-<DomainNameNoSpaces>; find matching configured domain
    for domain in config.domains {
        let suffix = "-" + domain.name.replacingOccurrences(of: " ", with: "")
        if folder.hasSuffix(suffix) { return domain.name }
    }
    return config.domains.first?.name ?? ""
}

private func s3Context(for path: String) throws -> (S3Store, String) {
    let config = try Config.load()
    let credentials = try KeychainCredentials.load()
    let client = S3Client(bucket: config.bucket, region: config.awsRegion, credentials: credentials)
    let dName = extractDomainName(from: path, config: config)
    let store = S3Store(client: client, config: config, domainName: dName)
    let mountURL = cloudStorageURL(domainName: dName)
    let relativePath = path.hasPrefix(mountURL.path + "/")
        ? String(path.dropFirst(mountURL.path.count + 1))
        : URL(filePath: path).lastPathComponent
    return (store, store.key(for: relativePath))
}

private func launchAgentPlist() -> String {
    "\(NSHomeDirectory())/Library/LaunchAgents/com.toots.tsync.plist"
}

@discardableResult
private func shell(_ args: String...) -> String {
    let p = Process()
    p.executableURL = URL(filePath: "/usr/bin/env")
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try? p.run()
    p.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .newlines) ?? ""
}
