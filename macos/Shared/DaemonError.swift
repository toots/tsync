import FileProvider
import Foundation

/// Turning a daemon failure into an error the system will act on sensibly.
///
/// FileProvider divides errors in two: `serverUnreachable` and `notAuthenticated`
/// mean *stop and wait to be signalled*, everything else is transient and
/// retried. So the rule is to claim unreachable only when the daemon says its
/// store is unreachable — otherwise a one-second daemon restart latches the
/// whole domain off. Unexplained failures fail one operation and are retried.
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
    /// FileProvider rejects any domain but `NSCocoaErrorDomain` and
    /// `NSFileProviderErrorDomain` outright, surfacing it as an unexplained I/O
    /// error.
    static func from(_ error: Error, item: NSFileProviderItemIdentifier? = nil) -> Error {
        guard let daemon = error as? DaemonError else {
            // Already a Cocoa error: a staging file operation, most likely.
            return error
        }
        switch daemon.code {
        case "not_found":
            if let item {
                return NSError.fileProviderErrorForNonExistentItem(withIdentifier: item)
            }
            return fp(.noSuchItem, daemon)

        case "exists":
            // The header prefers the colliding item attached, but the daemon
            // does not report which one, so the system bounces a name instead.
            return fp(.filenameCollision, daemon)

        case "not_empty":
            return fp(.directoryNotEmpty, daemon)

        case "read_only", "denied":
            return cocoa(NSFileWriteNoPermissionError, daemon)

        case "unreachable":
            // Deliberately latching: the store really is unavailable, so back
            // off until signalled.
            return fp(.serverUnreachable, daemon)

        default:
            // "invalid", "internal" and transport failures. Retried, so a
            // restarting daemon costs an operation, not the domain.
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
