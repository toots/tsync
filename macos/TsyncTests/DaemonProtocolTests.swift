import FileProvider
import XCTest

/// The protocol, against a real daemon.
///
/// This is the seam that has actually broken here. The two sides used to agree
/// on the storage key layout by having the same string written out in OCaml and
/// in Swift, with a comment asking whoever changed one to change the other —
/// which is not a mechanism. Nothing in either test suite would have noticed
/// them drifting apart.
///
/// So the daemon is started for real, from the binary in this repo, against a
/// local store in a temporary directory. No network, no app, no registered
/// domain, and nothing shared with whatever else is running on the machine.
final class DaemonProtocolTests: XCTestCase {
    private var root: URL!
    private var daemon: Process!
    private var client: DaemonClient!

    private static let domain = "iface"

    /// The daemon binary, found relative to this source file so the test does not
    /// depend on where it is run from.
    private static var executable: URL {
        URL(fileURLWithPath: #filePath)          // macos/TsyncTests/this.swift
            .deletingLastPathComponent()          // macos/TsyncTests
            .deletingLastPathComponent()          // macos
            .deletingLastPathComponent()          // repo root
            .appendingPathComponent("_build/default/bin/tsync.exe")
    }

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: Self.executable.path),
                          "no daemon binary; run `dune build bin/tsync.exe` first")

        // Short on purpose. A unix socket path is capped at 104 bytes, and the
        // daemon puts its socket several directories below HOME, so the usual
        // per-test temporary directory leaves no room for it.
        let tag = UUID().uuidString.prefix(8).lowercased()
        root = URL(fileURLWithPath: "/tmp/ts-\(tag)")
        let store = root.appendingPathComponent("store")
        // The daemon derives every path from HOME, so redirecting it is what
        // keeps this test off the real cache, journal and socket.
        let home = root.appendingPathComponent("home")
        let container = home.appendingPathComponent(
            "Library/Group Containers/\(Config.groupID)")
        for directory in [store, container] {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
        }

        let config: [String: Any] = [
            "name": "protocol-test",
            "domains": [[
                "name": Self.domain,
                "versioning": false,
                "symlinks": "keep",
                "readOnly": false,
                "backends": [["name": "store", "type": "local",
                              "role": "main", "path": store.path]],
                // Serves the IPC socket this test drives. The http-proxy frontend
                // deliberately has none.
                "frontends": ["file_provider"],
            ]],
        ]
        try JSONSerialization.data(withJSONObject: config)
            .write(to: container.appendingPathComponent("config.json"))

        daemon = Process()
        daemon.executableURL = Self.executable
        daemon.arguments = ["start"]
        daemon.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        daemon.standardOutput = FileHandle.nullDevice
        daemon.standardError = FileHandle.nullDevice
        try daemon.run()

        let socket = container.appendingPathComponent("tsync/tsync.sock").path
        client = DaemonClient(socketPath: socket, domain: Self.domain)
        try await waitForDaemon()
    }

    override func tearDown() async throws {
        if daemon?.isRunning == true {
            daemon.terminate()
            daemon.waitUntilExit()
        }
        if let root { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }

    private func waitForDaemon() async throws {
        for _ in 0..<100 {
            if (try? await client.listDir(ItemID.rootForm)) != nil { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("daemon did not come up")
    }

    // MARK: - Helpers

    /// A file handed to the daemon the way the extension hands one over: written
    /// somewhere it can take over by rename, on the same volume as its store.
    private func staged(_ contents: String) throws -> String {
        let path = root.appendingPathComponent("staged-\(UUID().uuidString)")
        try contents.write(to: path, atomically: true, encoding: .utf8)
        return path.path
    }

    private func listRoot() async throws -> [DaemonItem] {
        try await client.listDir(ItemID.rootForm).items
    }

    // MARK: - Tests

    func testEmptyDomainListsNothing() async throws {
        let items = try await listRoot()
        XCTAssertTrue(items.isEmpty, "a fresh domain should have no items")
    }

    /// Everything needed to build an `NSFileProviderItem` has to come back from
    /// the daemon, because this side cannot work any of it out.
    func testCreatedFileIsFullyDescribed() async throws {
        _ = try await client.write(parentRef: ItemID.rootForm, name: "hello.txt",
                                   staging: try staged("hello"))
        let items = try await listRoot()
        XCTAssertEqual(items.count, 1)
        let file = try XCTUnwrap(items.first)

        XCTAssertEqual(file.name, "hello.txt")
        XCTAssertEqual(file.kind, "file")
        XCTAssertEqual(file.size, 5)
        XCTAssertEqual(file.parentRef, ItemID.rootForm,
                       "a top-level item's parent must be the root the system knows")
        XCTAssertNotNil(ItemID.parse(file.ref), "the reference must be one we can read")
        XCTAssertNotNil(TsyncItem.make(file, readOnly: false))
    }

    /// Partial fetching rests entirely on this call, and both sides have to
    /// agree on field names that appear nowhere else in the protocol. The
    /// arithmetic around it is checked in `PartialRangeTests`; what is checked
    /// here is that the request reaches the daemon and the served range comes
    /// back — a typo in either direction is invisible until a file is opened.
    func testRangeIsServedAtItsOwnOffset() async throws {
        _ = try await client.write(parentRef: ItemID.rootForm, name: "big.txt",
                                   staging: try staged("0123456789ABCDEF"))
        let items = try await listRoot()
        let listed = try XCTUnwrap(items.first)
        let destination = root.appendingPathComponent("range-\(UUID().uuidString)")

        let served = try await client.fetchRange(ref: listed.ref,
                                                 destination: destination.path,
                                                 offset: 8, length: 4)
        XCTAssertEqual(served, NSRange(location: 8, length: 4))

        // Everything before the range is a hole, so the file stops where the
        // range does: that is what shows the bytes landed at their own offset
        // rather than at the start of the file.
        let written = try Data(contentsOf: destination)
        XCTAssertEqual(written.count, 12)
        XCTAssertEqual(String(decoding: written[8..<12], as: UTF8.self), "89AB")
    }

    /// A range running past the end comes back short rather than padded. The
    /// system checks the served length against the size we reported for the
    /// item, so inventing bytes here would fail the whole fetch.
    func testRangePastTheEndIsServedShort() async throws {
        _ = try await client.write(parentRef: ItemID.rootForm, name: "small.txt",
                                   staging: try staged("0123456789"))
        let items = try await listRoot()
        let listed = try XCTUnwrap(items.first)
        let destination = root.appendingPathComponent("short-\(UUID().uuidString)")

        let served = try await client.fetchRange(ref: listed.ref,
                                                 destination: destination.path,
                                                 offset: 8, length: 64)
        XCTAssertEqual(served, NSRange(location: 8, length: 2))
    }

    /// A reference composed here must name the same item the daemon named, or
    /// creating an item and then finding it again would take a full listing.
    func testFileReferenceIsComposable() async throws {
        _ = try await client.write(parentRef: ItemID.rootForm, name: "a.txt",
                                   staging: try staged("x"))
        let rootItems = try await listRoot()
        let listed = try XCTUnwrap(rootItems.first)
        let composed = try XCTUnwrap(ItemID.file(in: .rootContainer, named: "a.txt"))
        XCTAssertEqual(ItemID.wire(composed.identifier), listed.ref)

        let stat = try await client.stat(listed.ref)
        XCTAssertEqual(stat.name, "a.txt")
        XCTAssertEqual(stat.ref, listed.ref)
    }

    /// A child's parent reference has to be exactly its container's own
    /// reference. Anything else and the system builds a container that is not
    /// there.
    func testChildParentMatchesContainer() async throws {
        _ = try await client.mkdir(parentRef: ItemID.rootForm, name: "sub")
        let rootItems = try await listRoot()
        let folder = try XCTUnwrap(rootItems.first)
        XCTAssertEqual(folder.kind, "dir")

        _ = try await client.write(parentRef: folder.ref, name: "inside.txt",
                                   staging: try staged("deep"))
        let children = try await client.listDir(folder.ref).items
        let child = try XCTUnwrap(children.first)
        XCTAssertEqual(child.parentRef, folder.ref)
    }

    /// A page is the last name served and nothing else, so the pages of one
    /// listing lie end to end whoever asks for them. An offset into a listing
    /// held in memory passes this and fails the moment the process serving it is
    /// not the one that started.
    func testAFolderPagesEndToEnd() async throws {
        let names = ["a.txt", "b.txt", "c.txt", "d.txt", "e.txt"]
        for name in names {
            _ = try await client.write(parentRef: ItemID.rootForm, name: name,
                                       staging: try staged(name))
        }

        var seen: [String] = []
        var after: String? = nil
        // One more round than there are pages, so a cursor that fails to advance
        // shows up as a repeat rather than as a hang.
        for _ in 0...names.count {
            let page = try await client.listDir(ItemID.rootForm, after: after, limit: 2)
            XCTAssertLessThanOrEqual(page.items.count, 2, "a page must honour its limit")
            seen.append(contentsOf: page.items.map(\.name))
            guard let next = page.next else { break }
            XCTAssertEqual(next, page.items.last?.name,
                           "the cursor is the last name served")
            after = next
        }
        XCTAssertEqual(seen, names, "the pages laid end to end are the listing")
    }

    /// Resuming from a name that is no longer there still lands after it, which
    /// is what stops a deletion mid-enumeration skipping the next item.
    func testAPageResumesAfterADeletedName() async throws {
        for name in ["a.txt", "b.txt", "c.txt"] {
            _ = try await client.write(parentRef: ItemID.rootForm, name: name,
                                       staging: try staged(name))
        }
        try await client.delete(ref: "f:\(ItemID.rootFolderID)/b.txt", isDirectory: false)
        let page = try await client.listDir(ItemID.rootForm, after: "b.txt", limit: 10)
        XCTAssertEqual(page.items.map(\.name), ["c.txt"])
    }

    /// The whole point of the identifier change: a folder that is renamed is
    /// still the same folder. If this fails, every rename is reported to the
    /// system as a merge and everything underneath is silently re-identified.
    func testRenamingAFolderKeepsItsIdentity() async throws {
        _ = try await client.mkdir(parentRef: ItemID.rootForm, name: "before")
        let beforeItems = try await listRoot()
        let before = try XCTUnwrap(beforeItems.first)
        _ = try await client.write(parentRef: before.ref, name: "keep.txt",
                                   staging: try staged("content"))

        _ = try await client.rename(ref: before.ref, parentRef: ItemID.rootForm,
                                    name: "after")

        let afterItems = try await listRoot()
        let after = try XCTUnwrap(afterItems.first)
        XCTAssertEqual(after.name, "after")
        XCTAssertEqual(after.ref, before.ref,
                       "a renamed folder must keep its reference")

        // And its contents came with it, still reachable by the same reference.
        let kept = try await client.listDir(after.ref).items
        let child = try XCTUnwrap(kept.first)
        XCTAssertEqual(child.name, "keep.txt")
    }

    /// A directory's version must not change on its own, or the system treats it
    /// as modified on every look. It used to report the current clock as its
    /// modification time.
    func testDirectoryVersionIsStable() async throws {
        _ = try await client.mkdir(parentRef: ItemID.rootForm, name: "steady")
        let steadyItems = try await listRoot()
        let first = try XCTUnwrap(steadyItems.first)
        try await Task.sleep(nanoseconds: 50_000_000)
        let second = try await client.stat(first.ref)
        XCTAssertEqual(first.etag, second.etag)
        XCTAssertEqual(second.mtime, 0, "a directory has no useful modification time")

        let a = try XCTUnwrap(TsyncItem.make(first, readOnly: false))
        let b = try XCTUnwrap(TsyncItem.make(second, readOnly: false))
        XCTAssertEqual(a.itemVersion.contentVersion, b.itemVersion.contentVersion)
    }

    /// Asking about something that is gone has to say so. This is the answer the
    /// system uses to take an item off disk; anything else and a deleted item
    /// stays forever.
    func testDeletedItemIsReportedMissing() async throws {
        _ = try await client.write(parentRef: ItemID.rootForm, name: "doomed.txt",
                                   staging: try staged("bye"))
        let doomed = try await listRoot()
        let file = try XCTUnwrap(doomed.first)
        try await client.delete(ref: file.ref, isDirectory: false)

        do {
            _ = try await client.stat(file.ref)
            XCTFail("a deleted file should not resolve")
        } catch let error as DaemonError {
            XCTAssertEqual(error.code, "not_found")
        }
    }

    func testDeletedFolderIsReportedMissing() async throws {
        _ = try await client.mkdir(parentRef: ItemID.rootForm, name: "gone")
        let goneItems = try await listRoot()
        let folder = try XCTUnwrap(goneItems.first)
        try await client.delete(ref: folder.ref, isDirectory: true)

        do {
            _ = try await client.stat(folder.ref)
            XCTFail("a deleted folder should not resolve")
        } catch let error as DaemonError {
            XCTAssertEqual(error.code, "not_found")
        }
    }

    /// Errors arrive as codes, not prose, so the mapping to what the system
    /// should do can be made on something stable.
    func testFailuresCarryACode() async throws {
        do {
            _ = try await client.stat("d:0000000000000000")
            XCTFail("an unknown reference should not resolve")
        } catch let error as DaemonError {
            XCTAssertEqual(error.code, "not_found")
            XCTAssertEqual((FileProviderError.from(error) as NSError).domain,
                           NSFileProviderError.errorDomain)
        }
    }

    /// The daemon serves a whole conversation on one connection now. A client
    /// that assumed otherwise would work by accident and then stop when the
    /// subscription path reused a connection.
    func testManyRequestsInSequence() async throws {
        for i in 0..<5 {
            _ = try await client.write(parentRef: ItemID.rootForm, name: "f\(i).txt",
                                       staging: try staged("\(i)"))
        }
        let items = try await listRoot()
        XCTAssertEqual(items.count, 5)
        XCTAssertEqual(Set(items.map(\.name)).count, 5)
    }
}
