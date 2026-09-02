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

    func testAnAnchorCarriesItsGenerationAndCursor() {
        let anchor = Anchor.encode(token: "1756600000000", cursor: "0001756600000-abc")
        let decoded = Anchor.decode(anchor)
        XCTAssertEqual(decoded.token, "1756600000000")
        XCTAssertEqual(decoded.cursor, "0001756600000-abc")
    }

    /// A client that has never synced holds no cursor, and the generation is
    /// still what decides whether its anchor survives a resync.
    func testAnEmptyCursorStillCarriesTheGeneration() {
        let decoded = Anchor.decode(Anchor.encode(token: "gen", cursor: ""))
        XCTAssertEqual(decoded.token, "gen")
        XCTAssertEqual(decoded.cursor, "")
    }

    /// Anything that is not one of ours reads as "no generation", which fails
    /// the comparison and expires — the safe direction.
    func testAGarbageAnchorDoesNotDecodeAsAGeneration() {
        let decoded = Anchor.decode(NSFileProviderSyncAnchor(Data("nonsense".utf8)))
        XCTAssertEqual(decoded.token, "")
    }
}
