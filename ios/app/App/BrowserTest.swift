import FileProvider
import Foundation

/// ios-app.md §5, Run browser test: Files' operations through FileStore, the
/// browser's own code, in a folder of their own in the local test domain.
enum BrowserTest {
    static var log: URL { Tsync.groupContainer.appendingPathComponent("browsertest.log") }

    private static var failures = 0

    static func run() async {
        try? FileManager.default.removeItem(at: log)
        failures = 0
        note("start")
        do {
            try await steps()
        } catch {
            check("no step throws", false, "\(error)")
        }
        note(failures == 0 ? "PASS" : "FAIL: \(failures) steps")
        let copy = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(log.lastPathComponent)
        try? FileManager.default.removeItem(at: copy)
        try? FileManager.default.copyItem(at: log, to: copy)
    }

    private static func steps() async throws {
        if Configs.entries().allSatisfy({ $0.name != "Test" }), let refusal = Configs.add([Configs.localTest()]) {
            throw NSError(domain: "tsync", code: 1, userInfo: [NSLocalizedDescriptionKey: refusal])
        }
        try await NSFileProviderManager.add(
            NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(domainIdentifier("Test")), displayName: "Test"))
        let root = try await FileStore.root("Test")
        let name = "browser-test-\(Int(Date().timeIntervalSince1970))"
        let folder = root.appendingPathComponent(name, isDirectory: true)

        try FileStore.newFolder(name, in: root)
        defer { try? FileStore.delete(folder) }
        check("new folder is listed", try await names(root).contains(name))
        check("the same name again is refused as taken", taken { try FileStore.newFolder(name, in: root) })

        let source = FileManager.default.temporaryDirectory.appendingPathComponent("a.txt")
        try Data("tsync browser test".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let first = try FileStore.upload(source, into: folder)
        let second = try FileStore.upload(source, into: folder)
        check("uploads are named a.txt, then a (1).txt", first == "a.txt" && second == "a (1).txt", "\(first), \(second)")
        check("both uploads are listed", try await names(folder) == ["a (1).txt", "a.txt"])

        let numbered = folder.appendingPathComponent("a (1).txt")
        check("a rename onto a taken name is refused",
              taken { try FileStore.move(numbered, to: folder.appendingPathComponent("a.txt")) })
        check("and changes nothing", try await names(folder) == ["a (1).txt", "a.txt"])
        try FileStore.move(numbered, to: folder.appendingPathComponent("b.txt"))
        check("a rename to a free name is listed", try await names(folder) == ["a.txt", "b.txt"])

        try FileStore.newFolder("sub", in: folder)
        let sub = folder.appendingPathComponent("sub", isDirectory: true)
        try FileStore.move(folder.appendingPathComponent("b.txt"), to: sub.appendingPathComponent("b.txt"))
        check("a moved file is gone from its folder", try await names(folder) == ["a.txt", "sub"])
        check("and listed in the new one", try await names(sub) == ["b.txt"])
        let moved = try String(contentsOf: sub.appendingPathComponent("b.txt"), encoding: .utf8)
        check("with its contents", moved == "tsync browser test", moved)

        let kept = folder.appendingPathComponent("a.txt")
        if try await uploaded(kept, within: 120) {
            try await FileStore.removeDownload(kept, domain: "Test")
            check("a removed download is online only", FileStore.item(kept).state == .onlineOnly)
        } else {
            check("an upload is taken within 120 s", false)
        }

        try FileStore.delete(folder)
        check("a deleted folder is gone", try await !names(root).contains(name))
    }

    /// The system evicts only what the extension has taken.
    private static func uploaded(_ url: URL, within seconds: Int) async throws -> Bool {
        for _ in 0..<seconds {
            if FileStore.item(url).state != .waitingToUpload { return true }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return false
    }

    private static func names(_ folder: URL) async throws -> [String] {
        try await FileStore.list(folder).map(\.name)
    }

    private static func taken(_ body: () throws -> Void) -> Bool {
        do {
            try body()
            return false
        } catch {
            return FileStore.isTaken(error)
        }
    }

    private static func check(_ what: String, _ held: Bool, _ detail: String = "") {
        if !held { failures += 1 }
        note((held ? "ok: " : "FAIL: ") + what + (detail.isEmpty || held ? "" : " (\(detail))"))
    }

    private static func note(_ line: String) {
        let stamped = "\(Date()) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: log) {
            handle.seekToEndOfFile()
            handle.write(Data(stamped.utf8))
            try? handle.close()
        } else {
            try? Data(stamped.utf8).write(to: log)
        }
    }
}
