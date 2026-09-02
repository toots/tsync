import FileProvider
import XCTest

/// Which changes the system hears about, and as what.
///
/// Every rule here fails silently when it is wrong: an item that stops existing,
/// one that comes back after being deleted, or a folder that quietly stops
/// receiving updates. None of them shows up as an error, and the system will not
/// ask again — so they are checked directly rather than through an enumerator.
final class ChangeBatchTests: XCTestCase {
    private func item(ref: String, parent: String, name: String,
                      kind: String = "file") -> DaemonItem {
        decode("""
        {"ref":"\(ref)","parentRef":"\(parent)","name":"\(name)","kind":"\(kind)",
         "size":1,"mtime":1.0,"etag":"e","isUploaded":true}
        """)
    }

    private func op(_ op: String, ref: String, parent: String, name: String,
                    srcRef: String? = nil, srcParent: String? = nil,
                    withItem: Bool = true) -> DaemonOp {
        var fields = """
        "op":"\(op)","ref":"\(ref)","parentRef":"\(parent)","name":"\(name)"
        """
        if let srcRef { fields += ",\"srcRef\":\"\(srcRef)\"" }
        if let srcParent { fields += ",\"srcParentRef\":\"\(srcParent)\"" }
        if withItem {
            fields += ",\"item\":" + String(
                data: try! JSONEncoder().encode(RawItem(ref: ref, parentRef: parent,
                                                        name: name)), encoding: .utf8)!
        }
        return decode("{\(fields)}")
    }

    private struct RawItem: Encodable {
        let ref: String, parentRef: String, name: String
        let kind = "file", size = 1, mtime = 1.0, etag = "e", isUploaded = true
    }

    private func decode<T: Decodable>(_ json: String) -> T {
        try! JSONDecoder().decode(T.self, from: Data(json.utf8))
    }


    /// The observer's two sets are unordered, so reporting both the creation and
    /// the deletion would resurrect the file.
    func testAFileCreatedAndDeletedInOneBatchIsOnlyDeleted() {
        let ops = [
            op("put", ref: "f:d1/a.txt", parent: "d:d1", name: "a.txt"),
            op("delete", ref: "f:d1/a.txt", parent: "d:d1", name: "a.txt", withItem: false),
        ]
        let (updated, deleted) = ChangeBatch.resolve(ops, readOnly: false)
        XCTAssertTrue(updated.isEmpty, "the creation must not outlive the deletion")
        XCTAssertEqual(deleted.map(\.rawValue), ["f:d1/a.txt"])
    }

    /// A file's reference is its parent and its leaf, so a rename makes a new
    /// one. Both ends have to be reported or the old name stays on disk.
    func testARenamedFileRetiresItsOldReference() {
        let ops = [op("rename", ref: "f:d1/b.txt", parent: "d:d1", name: "b.txt",
                      srcRef: "f:d1/a.txt", srcParent: "d:d1")]
        let (updated, deleted) = ChangeBatch.resolve(ops, readOnly: false)
        XCTAssertEqual(updated.map(\.itemIdentifier.rawValue), ["f:d1/b.txt"])
        XCTAssertEqual(deleted.map(\.rawValue), ["f:d1/a.txt"])
    }

    /// A directory keeps its reference across a move, so there is no old one to
    /// retire — retiring it would delete the folder the system just moved.
    func testARenamedFolderRetiresNothing() {
        let ops = [op("rename", ref: "d:d9", parent: "root", name: "after",
                      srcRef: "d:d9", srcParent: "root")]
        let (_, deleted) = ChangeBatch.resolve(ops, readOnly: false)
        XCTAssertTrue(deleted.isEmpty, "a folder's reference survives its rename")
    }

    /// Either end of a move counts. Testing only the destination leaves the old
    /// folder showing a file that has gone.
    func testAMoveOutOfAFolderIsStillReported() {
        let ops = [op("rename", ref: "f:d2/a.txt", parent: "d:d2", name: "a.txt",
                      srcRef: "f:d1/a.txt", srcParent: "d:d1")]
        let (updated, deleted) = ChangeBatch.resolve(ops, readOnly: false)
        XCTAssertEqual(updated.map(\.itemIdentifier.rawValue), ["f:d2/a.txt"])
        XCTAssertEqual(deleted.map(\.rawValue), ["f:d1/a.txt"])
    }

    /// A rename followed by the removal of the new name is not "the new name's
    /// last op wins": the old name has to go too, or it stays on disk for good.
    func testARenamedThenDeletedFileRetiresBothNames() {
        let ops = [
            op("rename", ref: "f:d1/b.txt", parent: "d:d1", name: "b.txt",
               srcRef: "f:d1/a.txt", srcParent: "d:d1"),
            op("delete", ref: "f:d1/b.txt", parent: "d:d1", name: "b.txt", withItem: false),
        ]
        let (updated, deleted) = ChangeBatch.resolve(ops, readOnly: false)
        XCTAssertTrue(updated.isEmpty)
        XCTAssertEqual(Set(deleted.map(\.rawValue)), ["f:d1/a.txt", "f:d1/b.txt"])
    }

    /// Two renames in a row leave one item, under the last name. The middle name
    /// was reported updated and deleted at once, and the two sets are unordered.
    func testARenameChainLeavesOnlyTheLastName() {
        let ops = [
            op("rename", ref: "f:d1/b.txt", parent: "d:d1", name: "b.txt",
               srcRef: "f:d1/a.txt", srcParent: "d:d1"),
            op("rename", ref: "f:d1/c.txt", parent: "d:d1", name: "c.txt",
               srcRef: "f:d1/b.txt", srcParent: "d:d1"),
        ]
        let (updated, deleted) = ChangeBatch.resolve(ops, readOnly: false)
        XCTAssertEqual(updated.map(\.itemIdentifier.rawValue), ["f:d1/c.txt"])
        XCTAssertEqual(Set(deleted.map(\.rawValue)), ["f:d1/a.txt", "f:d1/b.txt"])
    }

    /// A removal has no item to describe, and must still be reported.
    func testARemovalNeedsNoItem() {
        let ops = [op("rmdir", ref: "d:d5", parent: "root", name: "gone", withItem: false)]
        let (updated, deleted) = ChangeBatch.resolve(ops, readOnly: false)
        XCTAssertTrue(updated.isEmpty)
        XCTAssertEqual(deleted.map(\.rawValue), ["d:d5"])
    }

    /// Nothing here re-asks the daemon, so an op that arrives without its item
    /// is dropped rather than reported as an item with invented fields.
    func testAnUpdateWithoutItsItemIsNotInvented() {
        let ops = [op("put", ref: "f:d1/a.txt", parent: "d:d1", name: "a.txt",
                      withItem: false)]
        let (updated, deleted) = ChangeBatch.resolve(ops, readOnly: false)
        XCTAssertTrue(updated.isEmpty)
        XCTAssertTrue(deleted.isEmpty)
    }
}
