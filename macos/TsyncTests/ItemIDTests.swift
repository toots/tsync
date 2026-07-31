import FileProvider
import XCTest

/// The identifier scheme, checked against the same cases as the daemon's
/// `tests/item_ref`. Both ends have to agree on the spelling or items are
/// renamed, merged, or lost, and nothing else in either process would notice.
final class ItemIDTests: XCTestCase {
    func testDirectoryIsNamedByID() {
        XCTAssertEqual(ItemID.directory(folderID: "9f3a").identifier.rawValue, "d:9f3a")
        guard case .directory(let id)? = ItemID.parse("d:9f3a") else {
            return XCTFail("expected a directory")
        }
        XCTAssertEqual(id, "9f3a")
    }

    func testFileIsNamedByParentAndLeaf() {
        let file = ItemID.file(parentID: "9f3a", name: "report.pdf")
        XCTAssertEqual(file.identifier.rawValue, "f:9f3a/report.pdf")
        guard case .file(let parent, let name)? = ItemID.parse("f:9f3a/report.pdf") else {
            return XCTFail("expected a file")
        }
        XCTAssertEqual(parent, "9f3a")
        XCTAssertEqual(name, "report.pdf")
    }

    /// The system's root identifier and the daemon's name for it are different
    /// spellings of one container. Letting the two diverge makes the system
    /// invent a second root above the real one.
    func testRootHasOneIdentity() {
        XCTAssertEqual(ItemID.root.identifier, .rootContainer)
        XCTAssertEqual(ItemID.wire(.rootContainer), ItemID.rootForm)
        guard case .root? = ItemID.parse("root") else { return XCTFail("expected root") }
        guard case .root? = ItemID.parse("d:" + ItemID.rootFolderID) else {
            return XCTFail("the root folder id should normalise to the root")
        }
    }

    /// Only the first slash separates a parent from a leaf; everything after it
    /// is the name, however odd.
    func testAwkwardNames() {
        guard case .file(let parent, let name)? = ItemID.parse("f:9f3a/od:d name.txt") else {
            return XCTFail("expected a file")
        }
        XCTAssertEqual(parent, "9f3a")
        XCTAssertEqual(name, "od:d name.txt")
    }

    /// Malformed references arrive from another process, so parsing answers
    /// rather than throwing.
    func testMalformedReferencesAreRejected() {
        XCTAssertNil(ItemID.parse("f:9f3a"), "a file form needs a leaf")
        XCTAssertNil(ItemID.parse("f:9f3a/"), "an empty leaf is not a name")
        XCTAssertNil(ItemID.parse("f:/a.txt"), "a file form needs a parent")
        XCTAssertNil(ItemID.parse("d:"), "a bare prefix is not a reference")
        XCTAssertNil(ItemID.parse("tsync/dom/manifests/a.txt"),
                     "a storage key is not a reference")
    }

    func testRoundTrip() {
        for raw in ["d:9f3a", "f:9f3a/report.pdf"] {
            XCTAssertEqual(ItemID.parse(raw)?.identifier.rawValue, raw)
        }
    }

    /// A file's reference is composable from its container's, which is what lets
    /// a creation check for an existing item without listing the whole folder.
    func testComposingAChildReference() {
        let parent = ItemID.directory(folderID: "9f3a").identifier
        XCTAssertEqual(ItemID.file(in: parent, named: "a.txt")?.identifier.rawValue,
                       "f:9f3a/a.txt")
        XCTAssertEqual(ItemID.file(in: .rootContainer, named: "a.txt")?.identifier.rawValue,
                       "f:\(ItemID.rootFolderID)/a.txt")
        XCTAssertNil(ItemID.file(in: ItemID.file(parentID: "9f3a", name: "x").identifier,
                                 named: "a.txt"),
                     "a file is not a container")
    }
}
