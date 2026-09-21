import Darwin
import XCTest

/// That a cancelled request lets go of its thread.
///
/// `Task.cancel()` does not reach a thread sitting in `recv`, and those threads
/// come from a small global pool: a daemon that accepts a request and takes its
/// time answering it — which is every `ensure_cached` of a large file — will
/// otherwise collect one stuck thread per cancelled fetch until nothing the
/// extension does gets a thread at all. Nothing else in the suite would notice,
/// because the pool is exhausted rather than broken.
///
/// So the daemon here is a socket that accepts and never answers, which is the
/// state that matters and the one a real daemon is hardest to hold in.
final class DaemonCancellationTests: XCTestCase {
    private var listener: Int32 = -1
    private var path: String!
    private let accepted = Accepted()

    /// Held open for as long as the test runs: a connection closed from this end
    /// would end the `recv` the test is trying to get stuck in.
    private final class Accepted: @unchecked Sendable {
        private let lock = NSLock()
        private var fds: [Int32] = []

        func keep(_ fd: Int32) {
            lock.lock()
            defer { lock.unlock() }
            fds.append(fd)
        }

        func closeAll() {
            lock.lock()
            defer { lock.unlock() }
            for fd in fds { close(fd) }
            fds = []
        }
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        path = "/tmp/ts-cancel-\(UUID().uuidString.prefix(8).lowercased()).sock"

        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        try XCTSkipUnless(listener >= 0, "cannot create a socket")

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        path.withCString { cstr in
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: capacity) {
                    _ = strlcpy($0, cstr, capacity)
                }
            }
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bound, 0, "bind \(path!)")
        XCTAssertEqual(listen(listener, 8), 0)

        let listening = listener
        let accepted = self.accepted
        Thread.detachNewThread {
            while true {
                let fd = accept(listening, nil, nil)
                if fd < 0 { return }
                accepted.keep(fd)
            }
        }
    }

    override func tearDown() {
        if listener >= 0 { close(listener) }
        accepted.closeAll()
        try? FileManager.default.removeItem(atPath: path)
        super.tearDown()
    }

    func testCancellingARequestDoesNotWaitOnTheDaemon() {
        let client = DaemonClient(socketPath: path, domain: "d")
        let cancelled = expectation(description: "the request reports being cancelled")
        let request = Task {
            do {
                _ = try await client.send(DaemonRequest(action: "status"))
                XCTFail("a daemon that never answered answered")
            } catch is CancellationError {
                cancelled.fulfill()
            } catch {
                XCTFail("expected CancellationError, got \(error)")
            }
        }
        // Long enough to have connected, written, and settled into the read.
        Thread.sleep(forTimeInterval: 0.3)
        request.cancel()
        // Generous: what is being ruled out is waiting for an answer that never
        // comes, not a slow one.
        wait(for: [cancelled], timeout: 5)
    }
}
