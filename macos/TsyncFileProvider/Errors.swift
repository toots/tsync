import FileProvider
import Foundation

/// §6.10: an owner failure as an error of the Cocoa or File Provider domain,
/// the only domains the system accepts.
enum Errors {
    enum Kind { case mutation, read }

    /// `missing` is the item a `not_found` names: the target, or for a
    /// creation its parent, which the system then re-creates.
    static func map(
        _ error: Error, _ kind: Kind, missing: NSFileProviderItemIdentifier? = nil,
        occupant: NSFileProviderItem? = nil
    ) -> NSError {
        guard let failure = error as? OwnerFailure else {
            if (error as NSError).domain == NSFileProviderErrorDomain
                || (error as NSError).domain == NSCocoaErrorDomain
            {
                return error as NSError
            }
            return cocoa(kind == .mutation ? .fileWriteUnknown : .fileReadUnknown, error)
        }
        switch (failure.code, kind) {
        case ("cancelled", _):
            return cocoa(.userCancelled, failure)
        case ("not_found", _):
            if let missing = missing {
                return NSError.fileProviderErrorForNonExistentItem(withIdentifier: missing) as NSError
            }
            return provider(.noSuchItem, failure)
        case ("unreachable", _):
            return provider(.serverUnreachable, failure)
        case ("exists", .mutation):
            if let occupant = occupant {
                return NSError.fileProviderErrorForCollision(with: occupant) as NSError
            }
            return provider(.filenameCollision, failure)
        case ("not_empty", .mutation):
            return provider(.directoryNotEmpty, failure)
        case ("read_only", .mutation), ("denied", .mutation), ("invalid", .mutation):
            return provider(.cannotSynchronize, failure)
        case ("denied", .read):
            return cocoa(.fileReadNoPermission, failure)
        case (_, .mutation):
            return cocoa(.fileWriteUnknown, failure)
        case (_, .read):
            return cocoa(.fileReadUnknown, failure)
        }
    }

    /// The owner's own sentence, for `cannotSynchronize` and the logs.
    private static func userInfo(_ error: Error) -> [String: Any] {
        let text = (error as? OwnerFailure)?.message ?? error.localizedDescription
        return [NSLocalizedDescriptionKey: text]
    }

    static func provider(_ code: NSFileProviderError.Code, _ error: Error) -> NSError {
        NSError(domain: NSFileProviderErrorDomain, code: code.rawValue, userInfo: userInfo(error))
    }

    static func cocoa(_ code: CocoaError.Code, _ error: Error) -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: code.rawValue, userInfo: userInfo(error))
    }
}
