import FileProvider
import Foundation
import os

/// Launched with `-selftest`: drives the local test domain through file
/// coordination, so every step reaches the File Provider extension as the
/// Files app's would, and marks each step in the extension's footprint log.
/// Progress goes to `selftest.log` in the App Group container, copied with the
/// footprint log into the app's Documents when the test ends.
enum SelfTest {
    static let files = 1000
    static let bigBytes = 256 << 20

    static var log: URL { Tsync.groupContainer.appendingPathComponent("selftest.log") }

    static func run() async {
        try? FileManager.default.removeItem(at: log)
        do {
            note("start")
            if let refusal = Configs.add([Configs.localTest()]) {
                throw failure(refusal)
            }
            let domain = NSFileProviderDomain(
                identifier: NSFileProviderDomainIdentifier(domainIdentifier("Test")), displayName: "Test")
            try await NSFileProviderManager.add(domain)
            guard let manager = NSFileProviderManager(for: domain) else { throw failure("no manager") }
            let root = try await manager.getUserVisibleURL(for: .rootContainer)
            // The domain's folder is outside the app's sandbox on a device.
            let scoped = root.startAccessingSecurityScopedResource()
            defer { if scoped { root.stopAccessingSecurityScopedResource() } }
            note("root \(root.path), security scoped: \(scoped)")
            note("temporary directory \(try manager.temporaryDirectoryURL().path)")
            let many = root.appendingPathComponent("many", isDirectory: true)
            try coordinatedWrite(many) { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true) }
            for i in 0..<files {
                let name = String(format: "file-%05d.txt", i)
                try coordinatedWrite(many.appendingPathComponent(name)) {
                    try Data(name.utf8).write(to: $0)
                }
                if i % 250 == 0 { note("wrote \(i) files") }
            }
            note("wrote \(files) files")
            let listed = try coordinatedRead(many) {
                try FileManager.default.contentsOfDirectory(atPath: $0.path).count
            }
            note("listed \(listed) entries")
            let big = FileManager.default.temporaryDirectory.appendingPathComponent("big.bin")
            try writeRandom(big, bytes: bigBytes)
            let target = root.appendingPathComponent("big.bin")
            try coordinatedWrite(target) { url in
                try? FileManager.default.removeItem(at: url)
                try FileManager.default.copyItem(at: big, to: url)
            }
            try? FileManager.default.removeItem(at: big)
            note("wrote big.bin")
            try await evictOnceUploaded(target, manager)
            note("evicted big.bin")
            let read = try coordinatedRead(target) { url -> Int in
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                var total = 0
                while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { total += chunk.count }
                return total
            }
            note("read big.bin: \(read) bytes")
            note(read == bigBytes && listed == files ? "PASS" : "FAIL")
        } catch {
            note("FAIL \(error)")
        }
        copyLogsToDocuments()
    }

    /// ios-app.md §5 Diagnostics: every folder listed through the file
    /// system, so that the extension pulls each one; progress goes to the
    /// footprint log.
    private static let walking = OSAllocatedUnfairLock(initialState: false)

    static func walk() async {
        let started = walking.withLock { busy in
            defer { busy = true }
            return !busy
        }
        guard started else { return }
        defer { walking.withLock { $0 = false } }
        let domains = await withCheckedContinuation { done in
            NSFileProviderManager.getDomainsWithCompletionHandler { domains, _ in done.resume(returning: domains) }
        }
        for domain in domains {
            guard let manager = NSFileProviderManager(for: domain),
                let root = try? await manager.getUserVisibleURL(for: .rootContainer)
            else { continue }
            let scoped = root.startAccessingSecurityScopedResource()
            defer { if scoped { root.stopAccessingSecurityScopedResource() } }
            Footprint.append("app: walk of \(domain.displayName) starts")
            var pending = [root]
            var folders = 0
            while let folder = pending.popLast() {
                let children = await listed(folder)
                folders += 1
                if folders % 100 == 0 { Footprint.append("app: walked \(folders) folders of \(domain.displayName)") }
                pending += children.filter {
                    $0.lastPathComponent != ".Trash"
                        && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                }
            }
            Footprint.append("app: walked \(folders) folders of \(domain.displayName)")
        }
        copyLogsToDocuments()
    }

    /// A folder the extension is still pulling answers "retry" until it has it.
    private static func listed(_ folder: URL) async -> [URL] {
        let started = Date()
        let waited = { Int(Date().timeIntervalSince(started)) }
        for attempt in 0..<60 {
            do {
                let children = try FileManager.default.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: [.isDirectoryKey])
                if attempt > 0 {
                    Footprint.append("app: walk listed \(folder.lastPathComponent) after \(waited()) s: \(children.count) items")
                }
                return children
            } catch {
                if attempt == 0 { Footprint.append("app: walk waits on \(folder.lastPathComponent): \(error.localizedDescription)") }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        Footprint.append("app: walk skipped \(folder.lastPathComponent) after \(waited()) s")
        return []
    }

    /// `devicectl` reads the app's own container but not the App Group's.
    static func copyLogsToDocuments() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for source in [log, Footprint.oldLog, Footprint.log] {
            let copy = documents.appendingPathComponent(source.lastPathComponent)
            try? FileManager.default.removeItem(at: copy)
            try? FileManager.default.copyItem(at: source, to: copy)
        }
    }

    /// The system creates the item only once the extension has taken the
    /// copy, and evicts it only once it is uploaded.
    private static func evictOnceUploaded(_ url: URL, _ manager: NSFileProviderManager) async throws {
        var last: Error = failure("never tried")
        for _ in 0..<300 {
            do {
                try await manager.evictItem(identifier: try await identifier(of: url))
                return
            } catch {
                last = error
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        throw last
    }

    private static func identifier(of url: URL) async throws -> NSFileProviderItemIdentifier {
        try await withCheckedThrowingContinuation { continuation in
            NSFileProviderManager.getIdentifierForUserVisibleFile(at: url) { identifier, _, error in
                if let identifier = identifier { return continuation.resume(returning: identifier) }
                continuation.resume(throwing: error ?? failure("no identifier for \(url.path)"))
            }
        }
    }

    private static func coordinatedWrite(_ url: URL, _ body: (URL) throws -> Void) throws {
        var outer: NSError?
        var inner: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &outer) {
            do { try body($0) } catch { inner = error }
        }
        if let error = outer ?? inner { throw error }
    }

    private static func coordinatedRead<T>(_ url: URL, _ body: (URL) throws -> T) throws -> T {
        var outer: NSError?
        var result: Result<T, Error> = .failure(failure("not read"))
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &outer) { url in
            result = Result { try body(url) }
        }
        if let outer = outer { throw outer }
        return try result.get()
    }

    private static func writeRandom(_ url: URL, bytes: Int) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        for _ in 0..<(bytes >> 20) {
            arc4random_buf(&buffer, buffer.count)
            try handle.write(contentsOf: buffer)
        }
    }

    private static func failure(_ why: String) -> NSError {
        NSError(domain: "tsync.selftest", code: 1, userInfo: [NSLocalizedDescriptionKey: why])
    }

    static func note(_ step: String) {
        Footprint.append("--- \(step)")
        let line = "\(Date()) \(step)\n"
        if let handle = try? FileHandle(forWritingTo: log) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: log, atomically: false, encoding: .utf8)
        }
    }
}
