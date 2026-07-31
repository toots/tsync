import FileProvider
import Foundation

/// Turning a daemon failure into an error the system will act on sensibly.
///
/// This table is the fix for a specific failure that kept the domain broken for
/// weeks. FileProvider divides errors in two: `serverUnreachable` and
/// `notAuthenticated` mean *stop and wait to be signalled*, while anything else
/// is transient and retried. The old code mapped every failure that was not
/// literally "not found" to `serverUnreachable`, so a one-second daemon restart
/// during an install told the system to stop trying — and the thing that was
/// supposed to signal it afterwards had never worked either.
///
/// So the rule here is: only say the store is unreachable when the daemon says
/// its store is unreachable. Everything unexplained fails one operation and is
/// retried.
enum DaemonError: Error {
    case transport(String)
    /// A structured failure: the daemon's code, and its prose for a human.
    case remote(code: String, message: String)

    var code: String? {
        if case .remote(let code, _) = self { return code }
        return nil
    }

    var message: String {
        switch self {
        case .transport(let m): return m
        case .remote(_, let m): return m
        }
    }
}

enum FileProviderError {
    /// Errors must be in `NSCocoaErrorDomain` or `NSFileProviderErrorDomain`;
    /// FileProvider rejects anything else outright, which is how an EPERM here
    /// once surfaced as an unexplained I/O error for months.
    static func from(_ error: Error, item: NSFileProviderItemIdentifier? = nil) -> Error {
        guard let daemon = error as? DaemonError else {
            // Already a Cocoa error — a staging file operation, most likely.
            return error
        }
        switch daemon.code {
        case "not_found":
            if let item {
                return NSError.fileProviderErrorForNonExistentItem(withIdentifier: item)
            }
            return fp(.noSuchItem, daemon)

        case "exists":
            // The header would rather have the colliding item attached so the
            // system can reconcile against it; the daemon does not say which item
            // it collided with, so the system resolves it by bouncing a name.
            return fp(.filenameCollision, daemon)

        case "not_empty":
            return fp(.directoryNotEmpty, daemon)

        case "read_only", "denied":
            return cocoa(NSFileWriteNoPermissionError, daemon)

        case "unreachable":
            // Deliberately latching: the store really is unavailable, and the
            // system should back off until signalled rather than hammer it.
            return fp(.serverUnreachable, daemon)

        default:
            // "invalid", "internal", and every transport failure. Retried, so a
            // daemon that is restarting costs an operation, not the domain.
            return cocoa(NSFileWriteUnknownError, daemon)
        }
    }

    private static func fp(_ code: NSFileProviderError.Code, _ daemon: DaemonError) -> Error {
        NSError(domain: NSFileProviderError.errorDomain, code: code.rawValue,
                userInfo: [NSLocalizedDescriptionKey: daemon.message])
    }

    private static func cocoa(_ code: Int, _ daemon: DaemonError) -> Error {
        NSError(domain: NSCocoaErrorDomain, code: code,
                userInfo: [NSLocalizedDescriptionKey: daemon.message])
    }
}
