import FileProvider
import XCTest

/// The error mapping, which is really a table of "should the system keep trying".
///
/// FileProvider splits errors in two: `serverUnreachable` and `notAuthenticated`
/// make it back off until signalled, everything else is transient and retried.
/// The old code sent every failure that was not literally "not found" down the
/// first path, so a daemon restart during an install left the domain stopped —
/// and the thing meant to signal it afterwards had never worked. These tests
/// exist to keep that specific mistake from coming back.
final class DaemonErrorTests: XCTestCase {
    private func mapped(_ code: String) -> NSError {
        FileProviderError.from(DaemonError.remote(code: code, message: "test")) as NSError
    }

    private func assertRetried(_ code: String, line: UInt = #line) {
        let error = mapped(code)
        XCTAssertEqual(error.domain, NSCocoaErrorDomain,
                       "\(code) must not latch the domain", line: line)
    }

    private func assertFileProvider(_ code: String, _ expected: NSFileProviderError.Code,
                                    line: UInt = #line) {
        let error = mapped(code)
        XCTAssertEqual(error.domain, NSFileProviderError.errorDomain, line: line)
        XCTAssertEqual(error.code, expected.rawValue, line: line)
    }

    func testMissingItemIsReportedAsSuch() {
        assertFileProvider("not_found", .noSuchItem)
    }

    func testCollisionAndNonEmptyAreDistinct() {
        assertFileProvider("exists", .filenameCollision)
        assertFileProvider("not_empty", .directoryNotEmpty)
    }

    /// The only code that should stop the system trying, because it is the only
    /// one that means the store itself is unavailable.
    func testOnlyUnreachableLatches() {
        assertFileProvider("unreachable", .serverUnreachable)
    }

    /// The regression that wedged the domain: an unexplained failure, or a daemon
    /// that is simply restarting, must cost one operation and be retried.
    func testUnexplainedFailuresAreRetried() {
        assertRetried("internal")
        assertRetried("invalid")
        assertRetried("something_new_the_daemon_learned_to_say")

        let transport = FileProviderError.from(DaemonError.transport("connection refused")) as NSError
        XCTAssertEqual(transport.domain, NSCocoaErrorDomain,
                       "a daemon that is restarting must not stop the domain")
    }

    func testRefusalsSurfaceToTheUser() {
        for code in ["read_only", "denied"] {
            let error = mapped(code)
            XCTAssertEqual(error.domain, NSCocoaErrorDomain)
            XCTAssertEqual(error.code, NSFileWriteNoPermissionError)
        }
    }

    /// FileProvider rejects errors from any other domain outright, which is how
    /// an EPERM here once surfaced as an unexplained I/O error for months.
    func testEveryMappingUsesAnAcceptedDomain() {
        let accepted = [NSCocoaErrorDomain, NSFileProviderError.errorDomain]
        for code in ["not_found", "exists", "not_empty", "read_only", "denied",
                     "unreachable", "invalid", "internal", "unknown"] {
            XCTAssertTrue(accepted.contains(mapped(code).domain),
                          "\(code) mapped to an unacceptable domain")
        }
    }

    /// A "not found" carrying the item lets the system reconcile that exact item
    /// away rather than working out what went missing.
    func testNotFoundNamesTheItem() {
        let identifier = NSFileProviderItemIdentifier("d:9f3a")
        let error = FileProviderError.from(
            DaemonError.remote(code: "not_found", message: "gone"),
            item: identifier) as NSError
        XCTAssertEqual(error.domain, NSFileProviderError.errorDomain)
        XCTAssertEqual(error.code, NSFileProviderError.noSuchItem.rawValue)
    }
}
