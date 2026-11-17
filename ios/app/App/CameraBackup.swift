import BackgroundTasks
import Network
import Photos
import SQLite3
import UIKit

/// ios-app.md §8.2: one record per asset, in the app's own container.
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
    }

    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init() throws {
        let folder = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        guard sqlite3_open(folder.appendingPathComponent("camera.sqlite").path, &db) == SQLITE_OK else {
            throw Self.failure("the camera records do not open")
        }
        try exec(
            """
            CREATE TABLE IF NOT EXISTS asset (
              id TEXT PRIMARY KEY, domain TEXT NOT NULL, stem TEXT NOT NULL, ext TEXT NOT NULL,
              paired_ext TEXT, modified INTEGER NOT NULL, state TEXT NOT NULL,
              attempts INTEGER NOT NULL DEFAULT 0, next_attempt INTEGER, last_error TEXT,
              created INTEGER NOT NULL, written INTEGER NOT NULL DEFAULT 0);
            CREATE UNIQUE INDEX IF NOT EXISTS asset_stem ON asset(domain, stem);
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value BLOB NOT NULL);
            """)
    }

    deinit { sqlite3_close(db) }

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

    func due(now: Int64) -> [Record] {
        rows(
            """
            SELECT id, domain, stem, ext, paired_ext, modified, written FROM asset
            WHERE state = 'PENDING' OR (state = 'FAILED' AND IFNULL(next_attempt, 0) <= ?) ORDER BY created
            """, [now]
        ).map {
            Record(
                id: $0[0] as! String, domain: $0[1] as! String, stem: $0[2] as! String, ext: $0[3] as! String,
                pairedExt: $0[4] as? String, modified: $0[5] as! Int64, written: $0[6] as! Int64 != 0)
        }
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

/// ios-app.md §8: the photo library written into a domain through the file
/// system, so that the extension uploads it.
@MainActor
final class CameraBackup: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    static let shared = CameraBackup()
    nonisolated static let taskIdentifier = (Bundle.main.bundleIdentifier ?? "") + ".camera"
    static let triggerDelay: UInt64 = 10_000_000_000
    static let stagedBytesBudget = 512 << 20
    static let freeSpaceFloor: Int64 = 1 << 30
    static let batteryFloor: Float = 0.15
    nonisolated static let maxNameAttempts = 1000

    @Published private(set) var status = ""
    @Published private(set) var running = false

    private let defaults = UserDefaults.standard
    private let network = NWPathMonitor()
    private var pass: Task<Void, Never>?
    private var again = false
    private var stopping = false
    private var trigger: Task<Void, Never>?
    private var observing = false

    var enabled: Bool { defaults.bool(forKey: "cameraBackup") }
    var wifiOnly: Bool {
        get { defaults.object(forKey: "cameraWifiOnly") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "cameraWifiOnly"); objectWillChange.send() }
    }
    var batteryOk: Bool {
        get { defaults.object(forKey: "cameraBatteryOk") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "cameraBatteryOk"); objectWillChange.send() }
    }
    /// Nil when the config no longer names it: backup then asks for another.
    var domain: String? {
        get {
            let configured = Tsync.domainNames()
            guard let chosen = defaults.string(forKey: "cameraDomain") else { return configured.first }
            return configured.contains(chosen) ? chosen : nil
        }
        set { defaults.set(newValue, forKey: "cameraDomain"); objectWillChange.send() }
    }

    override private init() {
        super.init()
        network.start(queue: .global(qos: .utility))
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    /// Once, as the app starts, as BackgroundRefresh registers.
    nonisolated static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            Task { @MainActor in
                let backup = CameraBackup.shared
                task.expirationHandler = { Task { @MainActor in backup.stopping = true } }
                backup.request()
                await backup.pass?.value
                task.setTaskCompleted(success: true)
            }
        }
    }

    /// §8.6 Controls: "Everything" or "From now on", then access.
    func enable(everything: Bool) async -> String? {
        let access = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard access == .authorized || access == .limited else { return "photo access not granted" }
        if !everything {
            do {
                try await Task.detached { try Self.discover(try CameraRecords(), domain: nil, baseline: true) }.value
            } catch {
                return "backup is not on: \(error.localizedDescription)"
            }
        }
        defaults.set(true, forKey: "cameraBackup")
        objectWillChange.send()
        request()
        return nil
    }

    func disable() {
        defaults.set(false, forKey: "cameraBackup")
        stopping = true
        pass?.cancel()
        objectWillChange.send()
        refreshStatus()
    }

    /// One pass at a time; a pass asked for during one runs after it.
    func request(now: Bool = false) {
        observe()
        guard pass == nil else { return again = true }
        stopping = false
        running = true
        pass = Task {
            repeat {
                again = false
                await run(now: now)
            } while again && !stopping
            pass = nil
            running = false
            refreshStatus()
        }
    }

    /// §8.6: the asset under way finishes in the background; the next does not start.
    func enteredBackground() {
        stopping = true
        if pending > 0 { schedule() }
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in
            trigger?.cancel()
            trigger = Task {
                try? await Task.sleep(nanoseconds: Self.triggerDelay)
                if !Task.isCancelled, UIApplication.shared.applicationState == .active { request() }
            }
        }
    }

    private func observe() {
        guard !observing, enabled, PHPhotoLibrary.authorizationStatus(for: .readWrite) != .notDetermined else { return }
        observing = true
        PHPhotoLibrary.shared().register(self)
    }

    private var pending: Int64 {
        let counts = (try? CameraRecords().counts()) ?? [:]
        return (counts["PENDING"] ?? 0) + (counts["FAILED"] ?? 0)
    }

    private func schedule() {
        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        request.requiresNetworkConnectivity = true
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Footprint.append("app: camera backup not scheduled: \(error.localizedDescription)")
        }
    }

    /// android-app §11.8, on §8's discovery and processing.
    private func run(now: Bool) async {
        guard enabled else { return }
        let access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard access == .authorized || access == .limited else { return outcome("photo access not granted") }
        guard let domain else { return outcome("choose a domain to back up to") }
        if !now, let hold = gate() { return outcome(hold) }
        let background = UIApplication.shared.beginBackgroundTask(withName: "Backing up photos") {}
        defer { UIApplication.shared.endBackgroundTask(background) }
        do {
            let records = try CameraRecords()
            try await Task.detached { try Self.discover(records, domain: domain, baseline: false) }.value
            var uploaded = 0, failed = 0, more = false
            for record in records.due(now: Self.now()) {
                if stopping || Task.isCancelled { more = true; break }
                if !now, let hold = gate() { more = true; status = hold; break }
                if let stop = await budget(record.domain) { more = true; outcome(stop); break }
                do {
                    guard let written = try await Self.write(record) else {
                        try records.delete(record.id)
                        continue
                    }
                    try records.done(written, modified: Self.modified(record.id) ?? record.modified)
                    uploaded += 1
                } catch is CancellationError {
                    more = true
                    break
                } catch {
                    try? records.failed(record.id, error.localizedDescription, now: Self.now())
                    failed += 1
                }
            }
            more = more || !records.due(now: Self.now()).isEmpty
            outcome("\(uploaded) uploaded" + (failed > 0 ? ", \(failed) failed" : "") + (more ? ", more to do" : ""))
            if pending > 0 { schedule() }
        } catch {
            outcome("last pass failed: \(error.localizedDescription)")
            schedule()
        }
    }

    /// §8.6 Gate, re-checked before each asset.
    private func gate() -> String? {
        let path = network.currentPath
        if wifiOnly && (path.status != .satisfied || path.isExpensive) { return "waiting for wifi" }
        let device = UIDevice.current
        let charging = device.batteryState == .charging || device.batteryState == .full
        if batteryOk && !charging
            && ((device.batteryLevel >= 0 && device.batteryLevel < Self.batteryFloor)
                || ProcessInfo.processInfo.isLowPowerModeEnabled)
        {
            return "battery low"
        }
        return nil
    }

    /// §8.4 step 2: what the extension still stages, and the phone's free space.
    private func budget(_ domain: String) async -> String? {
        let free = (try? URL(fileURLWithPath: NSTemporaryDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage) ?? 0
        if free < Self.freeSpaceFloor { return "waiting for free space" }
        guard let status = try? await FileStore.owner(domain, "status") else { return "\(domain) did not answer" }
        if status["pendingBytes"] as? Int ?? 0 >= Self.stagedBytesBudget { return "waiting for uploads to finish" }
        return nil
    }

    private func outcome(_ text: String) {
        defaults.set(text, forKey: "cameraLastOutcome")
        refreshStatus()
    }

    /// android-app §11.8's status line.
    func refreshStatus() {
        guard enabled else { return status = "off" }
        let counts = (try? CameraRecords().counts()) ?? [:]
        let failed = counts["FAILED"] ?? 0, waiting = counts["PENDING"] ?? 0
        var line: String
        if failed > 0 {
            line = "\(failed) failed — \((try? CameraRecords().lastError()) ?? "")"
        } else if counts.isEmpty {
            line = "not started yet"
        } else if waiting > 0 {
            line = "\(waiting) waiting to upload"
        } else {
            line = "up to date"
        }
        if domain == nil { line += " (choose a domain to back up to)" }
        if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited { line += " (only the photos you selected)" }
        if let last = defaults.string(forKey: "cameraLastOutcome") { line += "\nLast pass: \(last)" }
        status = line
    }

    // MARK: Discovery (§8.3)

    nonisolated static func discover(_ records: CameraRecords, domain: String?, baseline: Bool) throws {
        let target = domain ?? Tsync.domainNames().first ?? ""
        let library = PHPhotoLibrary.shared()
        if !baseline, let token = records.token() {
            do {
                let changes = try library.fetchPersistentChanges(since: token)
                try records.transaction {
                    for change in changes {
                        let details = try change.changeDetails(for: .asset)
                        for asset in fetch(Array(details.insertedLocalIdentifiers)) where !records.has(asset.localIdentifier) {
                            try record(asset, records, target, baseline: false)
                        }
                        for asset in fetch(Array(details.updatedLocalIdentifiers)) {
                            if records.has(asset.localIdentifier) {
                                try records.updated(asset.localIdentifier, modified: seconds(asset.modificationDate))
                            } else {
                                try record(asset, records, target, baseline: false)
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
                    try record(asset, records, target, baseline: baseline || before)
                } catch {
                    failure = error
                    stop.pointee = true
                }
            }
            if let failure { throw failure }
            try records.setToken(token)
        }
    }

    nonisolated private static func assets() -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.includeAssetSourceTypes = .typeUserLibrary
        options.predicate = NSPredicate(
            format: "mediaType == %d OR mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        return PHAsset.fetchAssets(with: options)
    }

    nonisolated private static func fetch(_ ids: [String]) -> [PHAsset] {
        guard !ids.isEmpty else { return [] }
        let options = PHFetchOptions()
        options.includeAssetSourceTypes = .typeUserLibrary
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: options)
        return (0..<result.count).map(result.object(at:)).filter { $0.mediaType == .image || $0.mediaType == .video }
    }

    nonisolated private static func record(
        _ asset: PHAsset, _ records: CameraRecords, _ domain: String, baseline: Bool
    ) throws {
        let (main, paired) = resources(asset)
        guard let main else { return }
        let base = stemBase(asset.creationDate ?? Date())
        var stem = base
        for n in 1...maxNameAttempts where records.stemTaken(domain, stem) { stem = "\(base) (\(n))" }
        try records.insert(
            .init(
                id: asset.localIdentifier, domain: domain, stem: stem, ext: ext(main.originalFilename),
                pairedExt: paired.map { ext($0.originalFilename) }, modified: seconds(asset.modificationDate),
                written: false),
            created: seconds(asset.creationDate), baseline: baseline)
    }

    /// §8.1: the asset as Photos shows it, and a Live Photo's video.
    nonisolated private static func resources(_ asset: PHAsset) -> (PHAssetResource?, PHAssetResource?) {
        let all = PHAssetResource.assetResources(for: asset)
        func first(_ types: PHAssetResourceType...) -> PHAssetResource? {
            types.lazy.compactMap { type in all.first { $0.type == type } }.first
        }
        let main = asset.mediaType == .video ? first(.fullSizeVideo, .video) : first(.fullSizePhoto, .photo)
        let paired = asset.mediaSubtypes.contains(.photoLive) ? first(.fullSizePairedVideo, .pairedVideo) : nil
        return (main, paired)
    }

    // MARK: Writing (§8.4)

    /// The record with the stem written to, or nil when the asset is gone.
    nonisolated private static func write(_ record: CameraRecords.Record) async throws -> CameraRecords.Record? {
        guard let asset = fetch([record.id]).first else { return nil }
        let (main, paired) = resources(asset)
        guard let main else { return nil }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        var exported: [(URL, String)] = []
        for (resource, ext) in [(main, record.ext), (paired, record.pairedExt ?? "")] {
            guard let resource else { continue }
            let file = staging.appendingPathComponent(UUID().uuidString)
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            try await PHAssetResourceManager.default().writeData(for: resource, toFile: file, options: options)
            exported.append((file, ext))
        }
        try Task.checkCancellation()
        let root = try await FileStore.root(record.domain)
        var record = record
        let claimed = try CameraRecords()
        // ponytail: a pass that fails between a Live Photo's two files leaves the first under the old stem.
        record.stem = try FileStore.placeCameraFiles(
            exported, stem: record.stem, under: root, replacing: record.written
        ) { $0 != record.stem && claimed.stemTaken(record.domain, $0) }
        return record
    }

    nonisolated private static func stemBase(_ date: Date) -> String {
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
    nonisolated static func ext(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex, name.index(after: dot) != name.endIndex
        else { return "" }
        let part = name[name.index(after: dot)...]
        return part.allSatisfy { $0.isLetter || $0.isNumber } ? part.lowercased() : ""
    }

    nonisolated private static func modified(_ id: String) -> Int64? {
        fetch([id]).first.map { seconds($0.modificationDate) }
    }

    nonisolated private static func seconds(_ date: Date?) -> Int64 { Int64(date?.timeIntervalSince1970 ?? 0) }
    nonisolated private static func now() -> Int64 { Int64(Date().timeIntervalSince1970) }
}
