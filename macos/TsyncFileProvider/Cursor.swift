import FileProvider

/// The two opaque blobs the system hands back to us, and what they mean.
///
/// Both must be readable by a process with no memory of issuing them: the
/// extension is stopped and restarted at the system's convenience, and a page
/// or an anchor may outlive the object that produced it. So neither carries an
/// offset into anything held in memory — a page names the last entry served,
/// and an anchor is the daemon's own cursor, which names a journal entry it
/// still has.
///
/// Both are capped at 500 bytes by the framework. A name is at most 255, and a
/// folder id and a journal key are short and fixed, so nothing here approaches
/// it; anything that would is refused rather than truncated, since an oversized
/// page interrupts the enumeration and an oversized anchor reads as expired.
enum Cursor {
    static let limit = 500

    private static func data(_ s: String) -> Data? {
        let d = Data(s.utf8)
        return d.count <= limit ? d : nil
    }

    /// The two initial-page constants are sentinels, not names, so they read as
    /// "from the start". They import as plain data rather than as the wrapper
    /// the parameter uses, hence the cast.
    private static let sentinels: [Data] = [
        NSFileProviderPage.initialPageSortedByName as Data,
        NSFileProviderPage.initialPageSortedByDate as Data,
    ]

    static func name(_ page: NSFileProviderPage) -> String? {
        let raw = page.rawValue
        guard !sentinels.contains(raw),
              let name = String(data: raw, encoding: .utf8), !name.isEmpty
        else { return nil }
        return name
    }

    /// nil when the name will not fit, which finishes the enumeration where it
    /// stands rather than handing back a page the system will reject.
    static func page(_ name: String) -> NSFileProviderPage? {
        guard let d = data(name) else { return nil }
        return NSFileProviderPage(d)
    }
}

/// A sync anchor: the daemon's own string, carried back to it verbatim.
///
/// It spells the mirror generation the anchor was issued against and the
/// journal entry it reached, and the daemon is the one to compare either. A
/// reimport stamps a new generation there, so an anchor from before it expires
/// on sight, including when the stamp landed while this extension was not
/// running, which is the usual case. Nothing here reads that stamp: a file the
/// daemon writes is not one this process may open.
enum Anchor {
    static func decode(_ anchor: NSFileProviderSyncAnchor) -> String {
        String(data: anchor.rawValue, encoding: .utf8) ?? ""
    }

    static func encode(_ cursor: String) -> NSFileProviderSyncAnchor {
        NSFileProviderSyncAnchor(Data(cursor.utf8))
    }
}
