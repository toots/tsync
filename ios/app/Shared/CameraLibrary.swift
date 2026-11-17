import CryptoKit
import Foundation
import Photos
import SQLite3

/// ios-app.md §8.2: one record per asset, in the App Group, which the app and
/// the upload extension both open. A connection lives for one pass or one
/// extension run: a suspended process holding a lock in the group is ended.
final class CameraRecords {
    struct Record {
        let id: String
        let domain: String
        var stem: String
        let ext: String
        let pairedExt: String?
        let modified: Int64
        /// Written once already: a write again replaces the files.
        let written: Bool
        /// §8.7: each file's content as last uploaded, the base of a write again.
        let contentId: String?
        let pairedContentId: String?

        enum Part: String { case main, paired }

        /// §8.5: nil for a Live Photo video the asset gained after it was recorded.
        func name(_ part: Part) -> String? {
            guard let ext = part == .main ? ext : pairedExt else { return nil }
            return ext.isEmpty ? stem : "\(stem).\(ext)"
        }

        func contentId(_ part: Part) -> String? { part == .main ? contentId : pairedContentId }
    }

    /// §8.7: a job the system holds.
    struct Job {
        let asset: String
        let part: Record.Part
        /// The asset's modification date when the job was made.
        let modified: Int64
        let retries: Int64
    }

    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    static var file: URL { Tsync.groupContainer.appendingPathComponent("camera.sqlite") }

    /// §8.2: a database first made in the app's own container moves to the group.
    static func migrate() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: file.path),
              let old = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
                .appendingPathComponent("camera.sqlite"),
              fm.fileExists(atPath: old.path)
        else { return }
        for suffix in ["", "-wal", "-shm"] {
            let from = URL(fileURLWithPath: old.path + suffix)
            if fm.fileExists(atPath: from.path) { try? fm.moveItem(atPath: from.path, toPath: file.path + suffix) }
        }
    }

    init() throws {
        guard sqlite3_open(Self.file.path, &db) == SQLITE_OK else {
            throw Self.failure("the camera records do not open")
        }
        // A pass, the extension, the status line and a name claim each open their own connection.
        sqlite3_busy_timeout(db, 5000)
        try exec("PRAGMA journal_mode = WAL")
        try exec(
            """
            CREATE TABLE IF NOT EXISTS asset (
              id TEXT PRIMARY KEY, domain TEXT NOT NULL, stem TEXT NOT NULL, ext TEXT NOT NULL,
              paired_ext TEXT, modified INTEGER NOT NULL, state TEXT NOT NULL,
              attempts INTEGER NOT NULL DEFAULT 0, next_attempt INTEGER, last_error TEXT,
              created INTEGER NOT NULL, written INTEGER NOT NULL DEFAULT 0);
            CREATE UNIQUE INDEX IF NOT EXISTS asset_stem ON asset(domain, stem);
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value BLOB NOT NULL);
            CREATE TABLE IF NOT EXISTS job (
              id TEXT PRIMARY KEY, asset TEXT NOT NULL, part TEXT NOT NULL,
              modified INTEGER NOT NULL, retries INTEGER NOT NULL DEFAULT 0);
            """)
        for column in ["content_id", "paired_content_id"] where !columns().contains(column) {
            try exec("ALTER TABLE asset ADD COLUMN \(column) TEXT")
        }
    }

    deinit { sqlite3_close(db) }

    private func columns() -> Set<String> {
        Set(rows("PRAGMA table_info(asset)").compactMap { $0[1] as? String })
    }

    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func token() -> PHPersistentChangeToken? {
        guard let data = rows("SELECT value FROM meta WHERE key = 'token'").first?[0] as? Data else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: data)
    }

    func setToken(_ token: PHPersistentChangeToken) throws {
        let data = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
        try exec("INSERT OR REPLACE INTO meta (key, value) VALUES ('token', ?)", [data])
    }

    func has(_ id: String) -> Bool { !rows("SELECT 1 FROM asset WHERE id = ?", [id]).isEmpty }

    func stemTaken(_ domain: String, _ stem: String) -> Bool {
        !rows("SELECT 1 FROM asset WHERE domain = ? AND stem = ?", [domain, stem]).isEmpty
    }

    func oldestCapture() -> Int64? { rows("SELECT MIN(created) FROM asset").first?[0] as? Int64 }

    func insert(_ record: Record, created: Int64, baseline: Bool) throws {
        try exec(
            "INSERT INTO asset (id, domain, stem, ext, paired_ext, modified, state, created) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            [record.id, record.domain, record.stem, record.ext, record.pairedExt, record.modified,
             baseline ? "BASELINE" : "PENDING", created])
    }

    /// §8.3: a changed `DONE` record is written again; a waiting one keeps waiting.
    func updated(_ id: String, modified: Int64) throws {
        try exec(
            """
            UPDATE asset SET state = CASE WHEN state = 'DONE' AND modified != ?1 THEN 'PENDING' ELSE state END,
              modified = CASE WHEN state = 'BASELINE' THEN modified ELSE ?1 END WHERE id = ?2
            """, [modified, id])
    }

    func delete(_ id: String) throws { try exec("DELETE FROM asset WHERE id = ?", [id]) }

    private static let recordColumns =
        "id, domain, stem, ext, paired_ext, modified, written, content_id, paired_content_id"

    private static func record(_ row: [Any?]) -> Record {
        Record(
            id: row[0] as! String, domain: row[1] as! String, stem: row[2] as! String, ext: row[3] as! String,
            pairedExt: row[4] as? String, modified: row[5] as! Int64, written: row[6] as! Int64 != 0,
            contentId: row[7] as? String, pairedContentId: row[8] as? String)
    }

    func due(now: Int64) -> [Record] {
        rows(
            """
            SELECT \(Self.recordColumns) FROM asset
            WHERE state = 'PENDING' OR (state = 'FAILED' AND IFNULL(next_attempt, 0) <= ?) ORDER BY created
            """, [now]
        ).map(Self.record)
    }

    func record(_ id: String) -> Record? {
        rows("SELECT \(Self.recordColumns) FROM asset WHERE id = ?", [id]).first.map(Self.record)
    }

    func done(_ record: Record, modified: Int64) throws {
        try exec(
            "UPDATE asset SET state = 'DONE', written = 1, stem = ?, modified = ?, attempts = 0, next_attempt = NULL, last_error = NULL WHERE id = ?",
            [record.stem, modified, record.id])
    }

    func failed(_ id: String, _ error: String, now: Int64) throws {
        let attempts = (rows("SELECT attempts FROM asset WHERE id = ?", [id]).first?[0] as? Int64 ?? 0) + 1
        let backoff = min(15 * 60 * Int64(1) << min(attempts - 1, 20), 6 * 3600)
        try exec(
            "UPDATE asset SET state = 'FAILED', attempts = ?, next_attempt = ?, last_error = ? WHERE id = ?",
            [attempts, now + backoff, error, id])
    }

    func counts() -> [String: Int64] {
        Dictionary(uniqueKeysWithValues: rows("SELECT state, COUNT(*) FROM asset GROUP BY state").map {
            ($0[0] as! String, $0[1] as! Int64)
        })
    }

    func lastError() -> String? {
        rows("SELECT last_error FROM asset WHERE state = 'FAILED' ORDER BY next_attempt DESC LIMIT 1").first?[0] as? String
    }

    // MARK: Jobs (§8.7)

    func uploading(_ id: String) throws { try exec("UPDATE asset SET state = 'UPLOADING' WHERE id = ?", [id]) }

    func addJob(_ id: String, asset: String, part: Record.Part, modified: Int64) throws {
        try exec("INSERT OR REPLACE INTO job (id, asset, part, modified) VALUES (?, ?, ?, ?)", [id, asset, part.rawValue, modified])
    }

    func job(_ id: String) -> Job? {
        rows("SELECT asset, part, modified, retries FROM job WHERE id = ?", [id]).first.map {
            Job(asset: $0[0] as! String, part: Record.Part(rawValue: $0[1] as! String) ?? .main, modified: $0[2] as! Int64, retries: $0[3] as! Int64)
        }
    }

    func retried(_ id: String) throws { try exec("UPDATE job SET retries = retries + 1 WHERE id = ?", [id]) }

    func jobsInFlight() -> Int { Int(rows("SELECT COUNT(*) FROM job").first?[0] as? Int64 ?? 0) }

    /// A part committed: its content id kept; the asset's last part makes it
    /// `DONE`, or `PENDING` again when it changed since its jobs were made.
    func committed(job id: String, _ job: Job, contentId: String) throws {
        let column = job.part == .paired ? "paired_content_id" : "content_id"
        try exec("UPDATE asset SET \(column) = ? WHERE id = ?", [contentId, job.asset])
        try exec("DELETE FROM job WHERE id = ?", [id])
        guard rows("SELECT 1 FROM job WHERE asset = ?", [job.asset]).isEmpty else { return }
        try exec(
            """
            UPDATE asset SET written = 1, attempts = 0, next_attempt = NULL, last_error = NULL,
              state = CASE WHEN modified = ? THEN 'DONE' ELSE 'PENDING' END
            WHERE id = ? AND state = 'UPLOADING'
            """, [job.modified, job.asset])
    }

    func dropJob(_ id: String) throws { try exec("DELETE FROM job WHERE id = ?", [id]) }

    /// §8.7: turning to `files`, the jobs the system dropped are owed again.
    func jobsCancelled() throws {
        try transaction {
            try exec("UPDATE asset SET state = 'PENDING' WHERE state = 'UPLOADING'")
            try exec("DELETE FROM job")
        }
    }

    func moveStem(_ id: String, to stem: String) throws {
        try exec("UPDATE asset SET stem = ?, state = 'PENDING' WHERE id = ?", [stem, id])
    }

    /// Written through the file system, with no content id to send as a base.
    func writtenWithoutContent() -> [Record] {
        rows("SELECT \(Self.recordColumns) FROM asset WHERE written = 1 AND content_id IS NULL").map(Self.record)
    }

    func setContent(_ id: String, contentId: String?, pairedContentId: String?) throws {
        try exec(
            "UPDATE asset SET content_id = ?, paired_content_id = ? WHERE id = ?", [contentId, pairedContentId, id])
    }

    func exec(_ sql: String, _ arguments: [Any?] = []) throws {
        if arguments.isEmpty {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
            return
        }
        let statement = try prepare(sql, arguments)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
    }

    private func rows(_ sql: String, _ arguments: [Any?] = []) -> [[Any?]] {
        guard let statement = try? prepare(sql, arguments) else { return [] }
        defer { sqlite3_finalize(statement) }
        var result: [[Any?]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append((0..<sqlite3_column_count(statement)).map { column -> Any? in
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: return sqlite3_column_int64(statement, column)
                case SQLITE_TEXT: return String(cString: sqlite3_column_text(statement, column))
                case SQLITE_BLOB:
                    let bytes = sqlite3_column_bytes(statement, column)
                    return bytes == 0 ? Data() : Data(bytes: sqlite3_column_blob(statement, column), count: Int(bytes))
                default: return nil
                }
            })
        }
        return result
    }

    private func prepare(_ sql: String, _ arguments: [Any?]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
        for (index, argument) in arguments.enumerated() {
            let position = Int32(index + 1)
            switch argument {
            case let text as String: sqlite3_bind_text(statement, position, text, -1, Self.transient)
            case let number as Int64: sqlite3_bind_int64(statement, position, number)
            case let data as Data:
                _ = data.withUnsafeBytes {
                    sqlite3_bind_blob(statement, position, $0.baseAddress, Int32(data.count), Self.transient)
                }
            default: sqlite3_bind_null(statement, position)
            }
        }
        return statement
    }

    private func error() -> NSError { Self.failure(String(cString: sqlite3_errmsg(db))) }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "tsync", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// §8.2: the camera preferences, in the App Group's defaults so the upload
/// extension reads them.
enum CameraPreferences {
    static let defaults = UserDefaults(suiteName: Tsync.appGroup) ?? .standard
    static let keys = [
        "cameraBackup", "cameraDomain", "cameraWifiOnly", "cameraBatteryOk", "cameraLastOutcome",
    ]

    /// Moved from the app's own defaults once.
    static func migrate() {
        for key in keys where defaults.object(forKey: key) == nil {
            if let value = UserDefaults.standard.object(forKey: key) { defaults.set(value, forKey: key) }
        }
    }

    static var enabled: Bool {
        get { defaults.bool(forKey: "cameraBackup") }
        set { defaults.set(newValue, forKey: "cameraBackup") }
    }
    static var wifiOnly: Bool {
        get { defaults.object(forKey: "cameraWifiOnly") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "cameraWifiOnly") }
    }
    static var batteryOk: Bool {
        get { defaults.object(forKey: "cameraBatteryOk") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "cameraBatteryOk") }
    }
    /// §8.7: `cameraUploads` is `system` or `files`.
    static var bySystem: Bool {
        get { defaults.string(forKey: "cameraUploads") == "system" }
        set { defaults.set(newValue ? "system" : "files", forKey: "cameraUploads") }
    }
    static var suspended: String? {
        get { defaults.string(forKey: "cameraUploadsSuspended") }
        set { defaults.set(newValue, forKey: "cameraUploadsSuspended") }
    }
    /// §8.7: consecutive refusals, toward the suspension.
    static var failures: Int {
        get { defaults.integer(forKey: "cameraUploadFailures") }
        set { defaults.set(newValue, forKey: "cameraUploadFailures") }
    }
    static var lastOutcome: String? {
        get { defaults.string(forKey: "cameraLastOutcome") }
        set { defaults.set(newValue, forKey: "cameraLastOutcome") }
    }

    /// Nil when the config no longer names it.
    static var domain: String? {
        get {
            let configured = Tsync.domainNames()
            guard let chosen = defaults.string(forKey: "cameraDomain") else { return configured.first }
            return configured.contains(chosen) ? chosen : nil
        }
        set { defaults.set(newValue, forKey: "cameraDomain") }
    }
}

/// §8.3 discovery and §8.5 naming, the same in the app and the extension.
enum CameraLibrary {
    static let maxNameAttempts = 1000

    static func discover(_ records: CameraRecords, domain: String, baseline: Bool) throws {
        let library = PHPhotoLibrary.shared()
        if !baseline, let token = records.token() {
            do {
                let changes = try library.fetchPersistentChanges(since: token)
                try records.transaction {
                    for change in changes {
                        let details = try change.changeDetails(for: .asset)
                        for asset in fetch(Array(details.insertedLocalIdentifiers)) where !records.has(asset.localIdentifier) {
                            try record(asset, records, domain, baseline: false)
                        }
                        for asset in fetch(Array(details.updatedLocalIdentifiers)) {
                            if records.has(asset.localIdentifier) {
                                try records.updated(asset.localIdentifier, modified: seconds(asset.modificationDate))
                            } else {
                                try record(asset, records, domain, baseline: false)
                            }
                        }
                        for id in details.deletedLocalIdentifiers { try records.delete(id) }
                        try records.setToken(change.changeToken)
                    }
                }
                return
            } catch let error as PHPhotosError
                where error.code == .persistentChangeTokenExpired || error.code == .persistentChangeDetailsUnavailable
            {}
        }
        // Taken first: a change during the walk is seen again by the next discovery.
        let token = library.currentChangeToken
        let oldest = records.oldestCapture()
        try records.transaction {
            var failure: Error?
            assets().enumerateObjects { asset, _, stop in
                guard !records.has(asset.localIdentifier) else { return }
                let before = oldest.map { seconds(asset.creationDate) < $0 } ?? false
                do {
                    try record(asset, records, domain, baseline: baseline || before)
                } catch {
                    failure = error
                    stop.pointee = true
                }
            }
            if let failure { throw failure }
            try records.setToken(token)
        }
    }

    private static func assets() -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.includeAssetSourceTypes = .typeUserLibrary
        options.predicate = NSPredicate(
            format: "mediaType == %d OR mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        return PHAsset.fetchAssets(with: options)
    }

    static func fetch(_ ids: [String]) -> [PHAsset] {
        guard !ids.isEmpty else { return [] }
        let options = PHFetchOptions()
        options.includeAssetSourceTypes = .typeUserLibrary
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: options)
        return (0..<result.count).map(result.object(at:)).filter { $0.mediaType == .image || $0.mediaType == .video }
    }

    private static func record(_ asset: PHAsset, _ records: CameraRecords, _ domain: String, baseline: Bool) throws {
        let (main, paired) = resources(asset)
        guard let main else { return }
        try records.insert(
            .init(
                id: asset.localIdentifier, domain: domain,
                stem: freeStem(stemBase(asset.creationDate ?? Date()), domain, records), ext: ext(main.originalFilename),
                pairedExt: paired.map { ext($0.originalFilename) }, modified: seconds(asset.modificationDate),
                written: false, contentId: nil, pairedContentId: nil),
            created: seconds(asset.creationDate), baseline: baseline)
    }

    /// §8.5: the first sequence name after `after` that no record holds.
    static func freeStem(_ base: String, _ domain: String, _ records: CameraRecords, after: Int = 0) -> String {
        var n = after
        var stem = n == 0 ? base : "\(base) (\(n))"
        while records.stemTaken(domain, stem) && n < maxNameAttempts {
            n += 1
            stem = "\(base) (\(n))"
        }
        return stem
    }

    /// §8.4: a stem found taken moves to its next sequence name.
    static func nextStem(_ stem: String, _ domain: String, _ records: CameraRecords) -> String {
        if stem.hasSuffix(")"), let open = stem.range(of: " (", options: .backwards),
           let n = Int(stem[open.upperBound..<stem.index(before: stem.endIndex)])
        {
            return freeStem(String(stem[..<open.lowerBound]), domain, records, after: n + 1)
        }
        return freeStem(stem, domain, records, after: 1)
    }

    /// §8.1: the asset as Photos shows it, and a Live Photo's video.
    static func resources(_ asset: PHAsset) -> (PHAssetResource?, PHAssetResource?) {
        let all = PHAssetResource.assetResources(for: asset)
        func first(_ types: PHAssetResourceType...) -> PHAssetResource? {
            types.lazy.compactMap { type in all.first { $0.type == type } }.first
        }
        let main = asset.mediaType == .video ? first(.fullSizeVideo, .video) : first(.fullSizePhoto, .photo)
        let paired = asset.mediaSubtypes.contains(.photoLive) ? first(.fullSizePairedVideo, .pairedVideo) : nil
        return (main, paired)
    }

    static func stemBase(_ date: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = .current
        format.dateFormat = "yyyy"
        let year = format.string(from: date)
        format.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Camera Uploads/\(year)/\(format.string(from: date))"
    }

    /// android-app §11.5: after the last dot, neither first nor last, letters
    /// and digits only, lower-cased; else none.
    static func ext(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex, name.index(after: dot) != name.endIndex
        else { return "" }
        let part = name[name.index(after: dot)...]
        return part.allSatisfy { $0.isLetter || $0.isNumber } ? part.lowercased() : ""
    }

    static func seconds(_ date: Date?) -> Int64 { Int64(date?.timeIntervalSince1970 ?? 0) }
    static func now() -> Int64 { Int64(Date().timeIntervalSince1970) }
}

/// §8.7: the target domain's listener, from the config in the App Group, and
/// the requests signed for it (http-proxy wire §3, §5.7).
struct UploadTarget {
    static let signatureLifetime: TimeInterval = 29 * 86400

    let domain: String
    let url: String
    let secret: String

    /// Nil unless the domain's main is an `http-proxy` store.
    init?(_ domain: String) {
        guard
            let data = try? Data(contentsOf: Tsync.configFile),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let entry = (json["domains"] as? [[String: Any]])?.first(where: { $0["name"] as? String == domain }),
            let main = (entry["backends"] as? [[String: Any]])?.first(where: { $0["role"] as? String == "main" }),
            main["type"] as? String == "http-proxy",
            let url = main["url"] as? String, let secret = main["secret"] as? String
        else { return nil }
        self.domain = domain
        self.url = url.hasSuffix("/") ? String(url.dropLast()) : url
        self.secret = secret
    }

    /// wire §3.2: a query value's canonical bytes.
    static func escape(_ value: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$'()*=:@/?".utf8)
        return value.utf8.map { allowed.contains($0) ? String(UnicodeScalar($0)) : String(format: "%%%02X", $0) }
            .joined()
    }

    static func query(_ parameters: [(String, String)]) -> String {
        parameters.map { "\($0.0)=\(escape($0.1))" }.joined(separator: "&")
    }

    private func hmac(_ message: String) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: Data(secret.utf8)))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// wire §5.7: `<expires>.<hmac>` over the canonical target.
    func uploadSignature(_ target: String, expires: Int) -> String {
        "\(expires).\(hmac("UPLOAD\n\(target)\n\(expires)"))"
    }

    /// §8.7: a job's destination.
    func destination(path: String, created: Date?, base: String?, wifiOnly: Bool) -> URLRequest? {
        var parameters = [("domain", domain), ("path", path)]
        if let created { parameters.append(("created", String(Int64(created.timeIntervalSince1970 * 1e9)))) }
        if let base { parameters.append(("base", base)) }
        let target = "/upload?" + Self.query(parameters)
        guard let url = URL(string: url + target) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.allowsExpensiveNetworkAccess = !wifiOnly
        request.allowsCellularAccess = !wifiOnly
        request.setValue(
            uploadSignature(target, expires: Int(Date().timeIntervalSince1970 + Self.signatureLifetime)),
            forHTTPHeaderField: "x-tsync-upload")
        return request
    }

    /// wire §5.3: whether the listener takes uploads into the domain; nil
    /// when it did not answer.
    func takesUploads() async -> Bool? {
        let target = "/upload-limit?" + Self.query([("prefix", "tsync/\(domain)/")])
        guard let url = URL(string: url + target) else { return false }
        var request = URLRequest(url: url, timeoutInterval: 15)
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let empty = SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined()
        request.setValue(timestamp, forHTTPHeaderField: "x-tsync-timestamp")
        request.setValue(hmac("GET\n\(target)\n\(timestamp)\n\(empty)"), forHTTPHeaderField: "x-tsync-signature")
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode
        else { return nil }
        return status == 200
    }
}
