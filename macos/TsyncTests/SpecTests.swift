import FileProvider
import UniformTypeIdentifiers
import XCTest

/// The pure parts of the extension and the app, checked against the spec.
/// Each test renders its cases as text and compares the whole with one
/// expected block, so a change reads as a diff.
final class SpecTests: XCTestCase {
    private func snapshot(_ lines: [String], _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        let got = lines.joined(separator: "\n")
        XCTAssertFalse(lines.isEmpty, "nothing was checked", file: file, line: line)
        XCTAssertEqual(got, expected.trimmingCharacters(in: .newlines), file: file, line: line)
    }

    /// §6.1: only `root`, `d:` and `i:` references parse; `root` is the root
    /// container both ways.
    func testItemReferences() {
        let refs = [
            "root", "d:3f2a9c1b7d4e-1a", "d:3f2a9c1b7d4e", "i:6c1e0b9a2f4d47e8a3b5c7d9e1f20384",
            "i:6C1E0B9A2F4D47E8A3B5C7D9E1F20384", "i:6c1e", "f:3f2a/a.txt", "d:", "d:a-b-c", "x",
        ]
        var lines = refs.map { "\($0) \(ItemRef.isValid($0))" }
        lines.append("root -> \(ItemRef.identifier("root") == .rootContainer)")
        lines.append("rootContainer -> \(ItemRef.ref(.rootContainer))")
        lines.append("d:1 -> \(ItemRef.identifier("d:1").rawValue)")
        snapshot(lines, """
            root true
            d:3f2a9c1b7d4e-1a true
            d:3f2a9c1b7d4e true
            i:6c1e0b9a2f4d47e8a3b5c7d9e1f20384 true
            i:6C1E0B9A2F4D47E8A3B5C7D9E1F20384 false
            i:6c1e false
            f:3f2a/a.txt false
            d: false
            d:a-b-c false
            x false
            root -> true
            rootContainer -> root
            d:1 -> d:1
            """)
    }

    private func row(_ fields: [String: Any]) -> Row? {
        var json: [String: Any] = ["ref": "i:6c1e0b9a2f4d47e8a3b5c7d9e1f20384", "parentRef": "root", "name": "a.txt"]
        json.merge(fields) { $1 }
        return Row(json)
    }

    /// §6.2, §6.3: versions from the owner's identity, never empty; a row whose
    /// references do not parse is dropped.
    func testRowsAndVersions() {
        let cases: [(String, [String: Any])] = [
            ("file", ["kind": "file", "contentId": "1294bbe85c2f380b", "etag": ""]),
            ("file no id", ["kind": "file", "etag": ""]),
            ("dir", ["kind": "dir", "ref": "d:9f3a", "etag": "9f3a"]),
            ("root", ["kind": "dir", "ref": "root", "etag": ".tsync-root"]),
            ("symlink", ["kind": "symlink", "contentId": "aa00bb11cc22dd33", "symlinkTarget": "x"]),
            ("bad ref", ["ref": "f:1/a"]),
            ("bad parent", ["parentRef": "nope"]),
            ("read-only", ["kind": "file", "contentId": "1", "readOnly": true]),
        ]
        let lines = cases.map { name, fields -> String in
            guard let row = row(fields) else { return "\(name): dropped" }
            let item = Item(row)
            return "\(name): version=\(String(decoding: row.contentVersion, as: UTF8.self)) parent=\(ItemRef.ref(item.parentItemIdentifier)) writable=\(item.capabilities.contains(.allowsWriting) || item.capabilities.contains(.allowsAddingSubItems))"
        }
        snapshot(lines, """
            file: version=1294bbe85c2f380b parent=root writable=true
            file no id: version=- parent=root writable=true
            dir: version=9f3a parent=root writable=true
            root: version=.tsync-root parent=root writable=true
            symlink: version=l:aa00bb11cc22dd33 parent=root writable=false
            bad ref: dropped
            bad parent: dropped
            read-only: version=1 parent=root writable=false
            """)
    }

    /// §6.2: a declared package directory takes its type, a folder named like a
    /// flat file stays a folder, a flat file named like a package stays a file.
    func testContentTypes() {
        let cases: [(String, Row.Kind)] = [
            ("Notes.rtfd", .dir), ("photos.jpg", .dir), ("plain", .dir), ("Notes.rtfd", .file),
            ("photo.jpg", .file), ("README", .file), ("link", .symlink),
        ]
        let lines = cases.map { name, kind -> String in
            let type = Item.contentType(name: name, kind: kind)
            return "\(name) \(kind): directory=\(type.conforms(to: .directory)) package=\(type.conforms(to: .package)) symlink=\(type == .symbolicLink)"
        }
        snapshot(lines, """
            Notes.rtfd dir: directory=true package=true symlink=false
            photos.jpg dir: directory=true package=false symlink=false
            plain dir: directory=true package=false symlink=false
            Notes.rtfd file: directory=false package=false symlink=false
            photo.jpg file: directory=false package=false symlink=false
            README file: directory=false package=false symlink=false
            link symlink: directory=false package=false symlink=true
            """)
    }

    private func op(_ kind: String, _ ref: String, item name: String? = nil) -> [String: Any] {
        var op: [String: Any] = ["op": kind, "ref": ref, "parentRef": "root", "name": name ?? "x"]
        if let name = name {
            op["item"] = ["ref": ref, "parentRef": "root", "name": name, "kind": "file", "contentId": "1"]
        }
        return op
    }

    /// §7 and its conformance cases.
    func testChangeBatches() {
        let a = "i:00000000000000000000000000000001"
        let b = "i:00000000000000000000000000000002"
        let cases: [(String, [[String: Any]])] = [
            ("create then delete", [op("put", a, item: "a"), op("delete", a)]),
            ("rename then delete", [op("rename", a, item: "b"), op("delete", a)]),
            ("a, b, c", [op("put", a, item: "a"), op("rename", a, item: "b"), op("rename", a, item: "c")]),
            ("removal without item", [op("rmdir", "d:9f3a")]),
            ("update without item", [op("put", a)]),
            ("two items", [op("put", a, item: "a"), op("put", b, item: "b"), op("delete", a)]),
        ]
        let lines = cases.map { name, ops -> String in
            let batch = ChangeBatch(ops: ops)
            return "\(name): updated=\(batch.updated.map(\.name)) deleted=\(batch.deleted)"
        }
        snapshot(lines, """
            create then delete: updated=[] deleted=["i:00000000000000000000000000000001"]
            rename then delete: updated=[] deleted=["i:00000000000000000000000000000001"]
            a, b, c: updated=["c"] deleted=[]
            removal without item: updated=[] deleted=["d:9f3a"]
            update without item: updated=[] deleted=[]
            two items: updated=["b"] deleted=["i:00000000000000000000000000000001"]
            """)
    }

    /// §6.8 and its conformance cases.
    func testAlignedRanges() {
        let cases: [(Int, Int, Int, Int64)] = [
            (0, 10, 4096, 100_000), (5000, 10, 4096, 100_000), (4096, 4096, 4096, 100_000),
            (99_000, 5000, 4096, 100_000), (100_000, 10, 4096, 100_000), (200_000, 10, 4096, 100_000),
            (0, 10, 4096, 0),
            (10, 5, 0, 100), (10, 5, 1, 100), (90, 50, 16, 100),
        ]
        let lines = cases.map { location, length, alignment, size -> String in
            let r = alignedRange(NSRange(location: location, length: length), alignment: alignment, documentSize: size)
            return "[\(location)+\(length)] /\(alignment) of \(size) -> \(r.start)+\(r.length)"
        }
        snapshot(lines, """
            [0+10] /4096 of 100000 -> 0+4096
            [5000+10] /4096 of 100000 -> 4096+4096
            [4096+4096] /4096 of 100000 -> 4096+4096
            [99000+5000] /4096 of 100000 -> 98304+1696
            [100000+10] /4096 of 100000 -> 98304+1696
            [200000+10] /4096 of 100000 -> 100000+0
            [0+10] /4096 of 0 -> 0+0
            [10+5] /0 of 100 -> 10+5
            [10+5] /1 of 100 -> 10+5
            [90+50] /16 of 100 -> 80+20
            """)
    }

    /// §6.10: every code to a Cocoa or File Provider error; only `unreachable`
    /// gives server-unreachable.
    func testErrorMapping() {
        let failures: [OwnerFailure] = [
            .refused(code: "not_found", message: "m", item: nil),
            .refused(code: "exists", message: "m", item: nil),
            .refused(code: "not_empty", message: "m", item: nil),
            .refused(code: "read_only", message: "m", item: nil),
            .refused(code: "denied", message: "m", item: nil),
            .refused(code: "invalid", message: "m", item: nil),
            .refused(code: "unreachable", message: "m", item: nil),
            .refused(code: "paused", message: "m", item: nil),
            .refused(code: "busy", message: "m", item: nil),
            .refused(code: "internal", message: "m", item: nil),
            .refused(code: "frobnicated", message: "m", item: nil),
            .noOwner("nothing listening"),
            .transport("connection reset"),
            .cancelled,
        ]
        func name(_ e: NSError) -> String {
            if e.domain == NSFileProviderErrorDomain {
                switch NSFileProviderError.Code(rawValue: e.code) {
                case .noSuchItem: return "noSuchItem"
                case .filenameCollision: return "filenameCollision"
                case .directoryNotEmpty: return "directoryNotEmpty"
                case .cannotSynchronize: return "cannotSynchronize"
                case .serverUnreachable: return "serverUnreachable"
                default: return "provider \(e.code)"
                }
            }
            switch CocoaError.Code(rawValue: e.code) {
            case .fileWriteUnknown: return "write-unknown"
            case .fileReadUnknown: return "read-unknown"
            case .fileReadNoPermission: return "read-no-permission"
            case .userCancelled: return "user-cancelled"
            default: return "cocoa \(e.code)"
            }
        }
        let lines = failures.map { f -> String in
            let label: String
            switch f {
            case .refused(let code, _, _): label = code
            case .noOwner: label = "no owner"
            case .transport: label = "transport"
            case .cancelled: label = "cancelled"
            }
            return "\(label): mutation=\(name(Errors.map(f, .mutation))) read=\(name(Errors.map(f, .read)))"
        }
        snapshot(lines, """
            not_found: mutation=noSuchItem read=noSuchItem
            exists: mutation=filenameCollision read=read-unknown
            not_empty: mutation=directoryNotEmpty read=read-unknown
            read_only: mutation=cannotSynchronize read=read-unknown
            denied: mutation=cannotSynchronize read=read-no-permission
            invalid: mutation=cannotSynchronize read=read-unknown
            unreachable: mutation=serverUnreachable read=serverUnreachable
            paused: mutation=write-unknown read=read-unknown
            busy: mutation=write-unknown read=read-unknown
            internal: mutation=write-unknown read=read-unknown
            frobnicated: mutation=write-unknown read=read-unknown
            no owner: mutation=serverUnreachable read=serverUnreachable
            transport: mutation=write-unknown read=read-unknown
            cancelled: mutation=user-cancelled read=user-cancelled
            """)
    }

    /// §5: the initial pages are not names; oversized cursors are refused,
    /// never truncated; bytes that are not UTF-8 are no anchor.
    func testCursors() throws {
        var lines: [String] = []
        lines.append("sorted by name: \(String(describing: try Cursors.resume(from: NSFileProviderPage(NSFileProviderPage.initialPageSortedByName as Data))))")
        lines.append("sorted by date: \(String(describing: try Cursors.resume(from: NSFileProviderPage(NSFileProviderPage.initialPageSortedByDate as Data))))")
        lines.append("a cursor: \(String(describing: try Cursors.resume(from: Cursors.page("1700000000000:42")!)))")
        lines.append("500 bytes: \(Cursors.page(String(repeating: "a", count: 500)) != nil)")
        lines.append("501 bytes: \(Cursors.page(String(repeating: "a", count: 501)) != nil)")
        lines.append("anchor over 500: \(Cursors.anchor(String(repeating: "a", count: 501)) != nil)")
        lines.append("non-UTF-8 anchor: \(String(describing: Cursors.cursor(of: NSFileProviderSyncAnchor(Data([0xff, 0xfe])))))")
        lines.append("limit 0: \(Cursors.limit(0)), limit 7: \(Cursors.limit(7))")
        snapshot(lines, """
            sorted by name: nil
            sorted by date: nil
            a cursor: Optional("1700000000000:42")
            500 bytes: true
            501 bytes: false
            anchor over 500: false
            non-UTF-8 anchor: nil
            limit 0: 100, limit 7: 7
            """)
    }

    /// §3.3, §9.1 step 1.
    func testDomainsAndConfig() throws {
        let config = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try """
            {"domains":[
              {"name":"My Files","frontends":["file_provider"]},
              {"name":"Other","frontends":[{"type":"file_provider"}]},
              {"name":"Linux only","frontends":["fuse"]}]}
            """.write(to: config, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: config) }
        var lines = ["My Files", "ÉTÉ Photos", "a  b"].map { "\($0) -> \(domainIdentifier($0))" }
        lines.append("configured: \(configuredDomainNames(config) ?? [])")
        lines.append("unreadable: \(String(describing: configuredDomainNames(config.appendingPathExtension("missing"))))")
        snapshot(lines, """
            My Files -> my-files
            ÉTÉ Photos -> été-photos
            a  b -> a--b
            configured: ["My Files", "Other"]
            unreadable: nil
            """)
    }
}
