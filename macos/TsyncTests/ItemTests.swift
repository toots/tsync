import FileProvider
import XCTest

/// What an item built out of a name the daemon could not spell in UTF-8 is
/// allowed to do.
///
/// The daemon passes a name's bytes through as they are, and a reply is decoded
/// leniently so one bad name costs its own item rather than the whole listing.
/// What is left names nothing the daemon has: writing it would create a second
/// file under the replacement characters and then fail to delete the first.
final class ItemTests: XCTestCase {
    /// `Café.txt` as Latin-1 — a name written on another system.
    private let latin1 = Data("Caf".utf8) + Data([0xE9]) + Data(".txt".utf8)

    /// Built the way a listing arrives: raw bytes, decoded as one line.
    private func item(named name: Data) throws -> TsyncItem? {
        var line = Data(#"{"ref":"f:9f3a/"#.utf8)
        line += name
        line += Data(#"","parentRef":"d:9f3a","name":""#.utf8)
        line += name
        line += Data(#"","kind":"file","size":1,"mtime":1,"etag":"e","isUploaded":true}"#.utf8)
        let text = String(decoding: line, as: UTF8.self)
        return TsyncItem.make(
            try JSONDecoder().decode(DaemonItem.self, from: Data(text.utf8)),
            readOnly: false)
    }

    func testNameThatIsNotUTF8IsReadOnly() throws {
        let item = try XCTUnwrap(try item(named: latin1))
        XCTAssertTrue(item.capabilities.contains(.allowsReading))
        XCTAssertFalse(item.capabilities.contains(.allowsWriting))
        XCTAssertFalse(item.capabilities.contains(.allowsDeleting))
    }

    func testAnOrdinaryNameStaysWritable() throws {
        let item = try XCTUnwrap(try item(named: Data("Café.txt".utf8)))
        XCTAssertTrue(item.capabilities.contains(.allowsWriting))
    }
}
