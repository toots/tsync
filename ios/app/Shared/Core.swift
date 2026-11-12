import Foundation

/// The core linked into this process (ios/core/tsync_ios.h). Its home is in
/// the process's own container (ios.md §3.2): a file lock held in the App
/// Group by a suspended process gets it killed. The group holds what both
/// processes read: `Tsync.configFile`, which the host names, and the
/// footprint log.
enum Core {
    static var home: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/tsync", isDirectory: true)
    }

    /// Every staging and destination path lies under it (android §4.1 item 5):
    /// the process's temporary directory, which is the provider's temporary
    /// directory in the extension, where the callbacks stage and fetch.
    static var transferRoot: URL { FileManager.default.temporaryDirectory }

    /// The File Provider extension's bounds (ocaml/memory.md §M.5); the app
    /// keeps the core's defaults. Only the first call of a process counts.
    static func start(bounded: Bool) {
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        tsync_ios_start(
            home.path, Tsync.configFile.path, transferRoot.path, bounded ? 32 << 10 : 0,
            bounded ? 1 : 0, bounded ? 4 : 0, bounded ? 1 << 20 : 0)
    }

    /// A text call of tsync_bridge.h; nil before the core started.
    static func text(_ name: String, _ arg: Data) -> String? {
        var length = 0
        let result = arg.withUnsafeBytes { raw in
            tsync_bridge_text(name, raw.bindMemory(to: CChar.self).baseAddress, arg.count, &length)
        }
        guard let result = result else { return nil }
        defer { free(result) }
        return String(decoding: UnsafeRawBufferPointer(start: result, count: length), as: UTF8.self)
    }

    /// The domain, a NUL, then the rest: how check_config and request take it.
    static func text(_ name: String, domain: String, _ rest: String) -> String? {
        text(name, Data(domain.utf8) + Data([0]) + Data(rest.utf8))
    }

    /// The core's sentence when it refuses `candidate` for `domain`, else nil.
    static func checkConfig(_ domain: String, candidate: String) -> String? {
        let sentence = text("check_config", domain: domain, candidate) ?? "the core is not started"
        return sentence.isEmpty ? nil : sentence
    }
}
