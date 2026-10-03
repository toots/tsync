import FileProvider
import Foundation

/// §5: anchors and pages are the owner's strings, carried as their UTF-8 bytes.
enum Cursors {
    /// The framework's limit on both.
    static let maxBytes = 500

    /// The owner's cursor to resume from; nil for either initial page.
    /// Throws for a page that is not one of ours.
    static func resume(from page: NSFileProviderPage) throws -> String? {
        let data = page.rawValue
        if data == NSFileProviderPage.initialPageSortedByName as Data
            || data == NSFileProviderPage.initialPageSortedByDate as Data
        {
            return nil
        }
        guard data.count <= maxBytes, let cursor = String(data: data, encoding: .utf8) else {
            throw NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.pageExpired.rawValue)
        }
        return cursor
    }

    /// Refuses, never truncates, a cursor over the limit.
    static func page(_ cursor: String) -> NSFileProviderPage? {
        let data = Data(cursor.utf8)
        return data.count <= maxBytes ? NSFileProviderPage(data) : nil
    }

    static func anchor(_ cursor: String) -> NSFileProviderSyncAnchor? {
        let data = Data(cursor.utf8)
        return data.count <= maxBytes ? NSFileProviderSyncAnchor(data) : nil
    }

    /// Nil when the bytes are not UTF-8: no anchor.
    static func cursor(of anchor: NSFileProviderSyncAnchor) -> String? {
        guard anchor.rawValue.count <= maxBytes else { return nil }
        return String(data: anchor.rawValue, encoding: .utf8)
    }

    /// The framework's suggested size, or 100 when it suggests none; at least 1.
    static func limit(_ suggested: Int) -> Int {
        suggested > 0 ? suggested : 100
    }
}
