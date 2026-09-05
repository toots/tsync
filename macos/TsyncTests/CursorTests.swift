import FileProvider
import XCTest

/// The two blobs the system hands back to us.
///
/// Both must mean the same thing to a process that did not issue them: the
/// extension is stopped and restarted at the system's convenience, so a page or
/// an anchor routinely outlives the object that produced it. A positional page
/// passes every test where one process does the whole enumeration and fails the
/// moment that stops being true, which is why these go through the encoding
/// rather than through an enumerator.
final class CursorTests: XCTestCase {
    private func page(_ name: String) throws -> NSFileProviderPage {
        try XCTUnwrap(Cursor.page(name))
    }

    func testANameSurvivesTheRoundTrip() throws {
        XCTAssertEqual(Cursor.name(try page("report.txt")), "report.txt")
    }

    func testAwkwardNamesSurviveIt() throws {
        for name in ["a b", "über.txt", "with|pipe", "…", "Ω/not-a-path"] {
            XCTAssertEqual(Cursor.name(try page(name)), name,
                           "a page cursor must carry the name verbatim")
        }
    }

    /// The sentinels are not names. Reading one as a cursor would resume a fresh
    /// enumeration somewhere in the middle of the folder.
    func testTheInitialPagesAreNotNames() {
        XCTAssertNil(Cursor.name(NSFileProviderPage(
            NSFileProviderPage.initialPageSortedByName as Data)))
        XCTAssertNil(Cursor.name(NSFileProviderPage(
            NSFileProviderPage.initialPageSortedByDate as Data)))
    }

    /// The framework caps a page at 500 bytes and interrupts the enumeration if
    /// one is larger, so an oversized name has to end the listing rather than be
    /// handed over and refused.
    func testAnOversizedNameIsRefusedRatherThanTruncated() {
        XCTAssertNil(Cursor.page(String(repeating: "n", count: Cursor.limit + 1)))
        XCTAssertNotNil(Cursor.page(String(repeating: "n", count: Cursor.limit)))
    }

    /// The daemon compares both halves of its cursor, so what it is handed
    /// back must be what it issued, byte for byte.
    func testAnAnchorCarriesTheDaemonsCursorVerbatim() {
        for cursor in ["1756600000000|0001756600000-abc", "|", ""] {
            XCTAssertEqual(Anchor.decode(Anchor.encode(cursor)), cursor)
        }
    }

    /// Bytes that are not text read as no cursor, which the daemon answers as
    /// "never synced": a full listing, the safe direction.
    func testBytesThatAreNotTextReadAsNoCursor() {
        let anchor = NSFileProviderSyncAnchor(Data([0xff, 0xfe, 0x00]))
        XCTAssertEqual(Anchor.decode(anchor), "")
    }
}
