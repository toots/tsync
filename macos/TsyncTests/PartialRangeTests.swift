import XCTest

/// Range arithmetic for partial fetches.
///
/// Worth testing on its own because none of it is checkable by looking: the
/// alignment is chosen by the system at runtime and is not stable across
/// reboots, so there is no value to eyeball the code against, and a range that
/// comes out one byte short does not fail — the application reads a hole and
/// treats it as content.
final class PartialRangeTests: XCTestCase {
    private let size: Int64 = 1000

    private func aligned(_ location: Int, _ length: Int,
                         alignment: Int = 16,
                         documentSize: Int64? = nil) -> NSRange {
        PartialRange.aligned(covering: NSRange(location: location, length: length),
                             alignment: alignment,
                             documentSize: documentSize ?? size)
    }

    /// The property that matters most: whatever else it does, the answer has to
    /// contain every byte that was asked for.
    func testCoversTheRequestedRange() {
        for location in stride(from: 0, to: 900, by: 7) {
            for length in [1, 5, 16, 17, 64, 100] {
                let result = aligned(location, length)
                let wantedEnd = min(Int(size), location + length)
                XCTAssertLessThanOrEqual(result.location, location,
                                         "start \(location) len \(length)")
                XCTAssertGreaterThanOrEqual(result.location + result.length, wantedEnd,
                                            "start \(location) len \(length)")
            }
        }
    }

    func testStartIsAlwaysAligned() {
        for alignment in [1, 2, 16, 4096, 65536] {
            for location in stride(from: 0, to: 900, by: 13) {
                let result = aligned(location, 10, alignment: alignment)
                XCTAssertEqual(result.location % alignment, 0,
                               "alignment \(alignment) location \(location)")
            }
        }
    }

    /// The length is a multiple of the alignment everywhere except the last
    /// range of the file, which the system checks against `documentSize`.
    func testLengthIsAlignedExceptAtEndOfFile() {
        for alignment in [16, 4096] {
            for location in stride(from: 0, to: 900, by: 11) {
                let result = aligned(location, 10, alignment: alignment)
                let endsAtFile = result.location + result.length == Int(size)
                if !endsAtFile {
                    XCTAssertEqual(result.length % alignment, 0,
                                   "alignment \(alignment) location \(location)")
                }
            }
        }
    }

    func testRoundsOutwardsToTheAlignment() {
        XCTAssertEqual(aligned(10, 5), NSRange(location: 0, length: 16))
        XCTAssertEqual(aligned(16, 16), NSRange(location: 16, length: 16))
        XCTAssertEqual(aligned(20, 30), NSRange(location: 16, length: 48))
    }

    /// A range reaching the end is clamped there rather than rounded past it:
    /// the file is the limit, not the alignment.
    func testClampsToTheEndOfTheFile() {
        let result = aligned(990, 20)
        XCTAssertEqual(result, NSRange(location: 976, length: 24))
        XCTAssertEqual(result.location + result.length, Int(size))
    }

    func testRangeEntirelyPastTheEndIsEmpty() {
        XCTAssertEqual(aligned(2000, 16).length, 0)
    }

    func testEmptyFileYieldsNothing() {
        XCTAssertEqual(aligned(0, 16, documentSize: 0), NSRange(location: 0, length: 0))
    }

    /// The system promises a power of two, but zero would divide by zero and one
    /// aligns to nothing — neither should be able to produce a wrong range.
    func testDegenerateAlignments() {
        XCTAssertEqual(aligned(10, 5, alignment: 1), NSRange(location: 10, length: 5))
        XCTAssertEqual(aligned(10, 5, alignment: 0), NSRange(location: 10, length: 5))
    }
}
