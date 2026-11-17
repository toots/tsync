import BackgroundTasks
import Network
import Photos
import UIKit

/// ios-app.md §8: the photo library written into a domain through the file
/// system, so that the extension uploads it, or handed to the system's
/// upload extension (§8.7).
@MainActor
final class CameraBackup: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    static let shared = CameraBackup()
    nonisolated static let taskIdentifier = (Bundle.main.bundleIdentifier ?? "") + ".camera"
    static let triggerDelay: UInt64 = 10_000_000_000
    static let refreshPassBudget: TimeInterval = 20
    static let stagedBytesBudget = 512 << 20
    static let freeSpaceFloor: Int64 = 1 << 30
    static let batteryFloor: Float = 0.15

    @Published private(set) var status = ""
    @Published private(set) var running = false

    private let network = NWPathMonitor()
    private var pass: Task<Void, Never>?
    private var again = false
    private var stopping = false
    /// A background refresh run's end: the pass stops between assets after it.
    private var deadline: Date?
    private var trigger: Task<Void, Never>?
    private var observing = false

    var enabled: Bool { CameraPreferences.enabled }
    /// §8.7: the system sends the photos; the app runs no pass of its own.
    var bySystem: Bool { CameraPreferences.bySystem }
    var wifiOnly: Bool {
        get { CameraPreferences.wifiOnly }
        set { CameraPreferences.wifiOnly = newValue; objectWillChange.send() }
    }
    var batteryOk: Bool {
        get { CameraPreferences.batteryOk }
        set { CameraPreferences.batteryOk = newValue; objectWillChange.send() }
    }
    /// Nil when the config no longer names it: backup then asks for another.
    var domain: String? {
        get { CameraPreferences.domain }
        set {
            CameraPreferences.domain = newValue
            objectWillChange.send()
            request()
        }
    }

    override private init() {
        super.init()
        network.start(queue: .global(qos: .utility))
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    /// Once, as the app starts, as BackgroundRefresh registers.
    nonisolated static func register() {
        CameraRecords.migrate()
        CameraPreferences.migrate()
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
        if everything {
            try? CameraRecords().exec("UPDATE asset SET state = 'PENDING' WHERE state = 'BASELINE'")
        } else {
            do {
                let target = domain ?? Tsync.domainNames().first ?? ""
                try await Task.detached { try CameraLibrary.discover(try CameraRecords(), domain: target, baseline: true) }.value
            } catch {
                return "backup is not on: \(error.localizedDescription)"
            }
        }
        CameraPreferences.enabled = true
        objectWillChange.send()
        request()
        return nil
    }

    func disable() {
        CameraPreferences.enabled = false
        stopping = true
        objectWillChange.send()
        refreshStatus()
    }

    /// One pass at a time; a pass asked for during one runs after it.
    func request(now: Bool = false) {
        observe()
        guard pass == nil else {
            again = true
            stopping = !enabled
            return
        }
        stopping = false
        deadline = nil
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

    /// §8.6: a background refresh run's pass, within `refreshPassBudget`.
    func refreshPass() async {
        guard enabled else { return }
        request()
        deadline = Date(timeIntervalSinceNow: Self.refreshPassBudget)
        await withTaskCancellationHandler {
            await pass?.value
        } onCancel: {
            Task { @MainActor in self.stopping = true }
        }
    }

    /// §8.6: the asset under way finishes in the background; the next does not start.
    func enteredBackground() {
        stopping = true
        if pending > 0 && !bySystem { schedule() }
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
        await decideUploads(domain)
        if bySystem { return refreshStatus() }
        if !now, let hold = gate() { return outcome(hold) }
        let background = BackgroundTime()
        background.begin { [weak self] in self?.stopping = true }
        defer { background.end() }
        do {
            let records = try CameraRecords()
            try await Task.detached { try CameraLibrary.discover(records, domain: domain, baseline: false) }.value
            var uploaded = 0, failed = 0, more = false
            var hold: String?
            for record in records.due(now: CameraLibrary.now()) {
                if stopping || Task.isCancelled || deadline.map({ Date() > $0 }) == true { more = true; break }
                if !now, let reason = gate() { more = true; hold = reason; break }
                if let reason = await budget(record.domain) { more = true; hold = reason; break }
                do {
                    guard let (written, modified) = try await Self.write(record) else {
                        try records.delete(record.id)
                        continue
                    }
                    try records.done(written, modified: modified)
                    uploaded += 1
                } catch is CancellationError {
                    more = true
                    break
                } catch {
                    try? records.failed(record.id, error.localizedDescription, now: CameraLibrary.now())
                    failed += 1
                }
            }
            more = more || !records.due(now: CameraLibrary.now()).isEmpty
            outcome("\(uploaded) uploaded" + (failed > 0 ? ", \(failed) failed" : "") + (more ? ", more to do" : "")
                + (hold.map { " (\($0))" } ?? ""))
            if pending > 0 { schedule() }
        } catch {
            outcome("last pass failed: \(error.localizedDescription)")
            schedule()
        }
    }

    /// §8.7: `system` when the target's listener takes uploads on a system that
    /// can send them; a listener that does not answer leaves the last decision.
    private func decideUploads(_ domain: String) async {
        var system = false
        if #available(iOS 26.4, *), enabled, PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized,
           let target = UploadTarget(domain)
        {
            guard let takes = await target.takesUploads() else {
                return Footprint.append("app: camera uploads: \(domain)'s server did not answer")
            }
            system = takes
        }
        if system {
            await fillContentIds(domain)
            CameraPreferences.suspended = nil
            CameraPreferences.failures = 0
        }
        guard #available(iOS 26.4, *) else { return }
        let library = PHPhotoLibrary.shared()
        if !system && library.uploadJobExtensionEnabled {
            // ponytail: before iOS 26.5 the jobs are left to finish; the records go back to PENDING either way.
            if #available(iOS 26.5, *) {
                let jobs = PHAssetResourceUploadJob.fetchJobs(action: .process, options: nil)
                try? library.performChangesAndWait {
                    for i in 0..<jobs.count { PHAssetResourceUploadJobChangeRequest(for: jobs.object(at: i))?.cancel() }
                }
            }
            try? CameraRecords().jobsCancelled()
        }
        if CameraPreferences.bySystem != system {
            Footprint.append("app: camera uploads: \(system ? "system" : "files")")
        }
        CameraPreferences.bySystem = system
        if system != library.uploadJobExtensionEnabled {
            do {
                try library.setUploadJobExtensionEnabled(system)
            } catch {
                Footprint.append("app: upload extension not \(system ? "enabled" : "disabled"): \(error.localizedDescription)")
            }
        }
    }

    /// §8.7: a write again sends the content it replaces; a file written
    /// through the file system gets its content id from the domain.
    private func fillContentIds(_ domain: String) async {
        guard let records = try? CameraRecords() else { return }
        for record in records.writtenWithoutContent() where record.domain == domain {
            func contentId(_ part: CameraRecords.Record.Part) async -> String? {
                guard let path = record.name(part) else { return nil }
                return (try? await FileStore.owner(domain, "stat", ["rel": path]))?["contentId"] as? String
            }
            guard let main = await contentId(.main) else { continue }
            try? records.setContent(record.id, contentId: main, pairedContentId: await contentId(.paired))
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
        CameraPreferences.lastOutcome = text
        refreshStatus()
    }

    /// android-app §11.8's status line.
    func refreshStatus() {
        guard enabled else { return status = "off" }
        let counts = (try? CameraRecords().counts()) ?? [:]
        let failed = counts["FAILED"] ?? 0, waiting = counts["PENDING"] ?? 0, sending = counts["UPLOADING"] ?? 0
        var line: String
        if let suspended = CameraPreferences.suspended, bySystem {
            line = "paused: \(suspended)"
        } else if failed > 0 {
            line = "\(failed) failed — \((try? CameraRecords().lastError()) ?? "")"
        } else if counts.isEmpty {
            line = "not started yet"
        } else if sending > 0 {
            line = "\(sending) uploading (by iOS)" + (waiting > 0 ? ", \(waiting) waiting" : "")
        } else if waiting > 0 {
            line = "\(waiting) waiting to upload"
        } else {
            line = "up to date"
        }
        if domain == nil { line += " (choose a domain to back up to)" }
        if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited { line += " (only the photos you selected)" }
        if let last = CameraPreferences.lastOutcome {
            line += (bySystem ? "\nLast run by iOS: " : "\nLast pass: ") + last
        }
        status = line
    }

    // MARK: Writing (§8.4)

    /// The record with the stem written to and the modification date its
    /// export was taken at, or nil when the asset is gone.
    nonisolated private static func write(_ record: CameraRecords.Record) async throws -> (CameraRecords.Record, Int64)? {
        guard let asset = CameraLibrary.fetch([record.id]).first else { return nil }
        let modified = CameraLibrary.seconds(asset.modificationDate)
        let (main, paired) = CameraLibrary.resources(asset)
        guard let main else { return nil }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        var exported: [(URL, String)] = []
        // §8.5: a Live Photo video the asset gained after it was recorded has no name.
        for (resource, ext) in [(main, Optional(record.ext)), (paired, record.pairedExt)] {
            guard let resource, let ext else { continue }
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
        return (record, modified)
    }
}

/// Background time for a pass: its expiration stops the pass between assets
/// and ends the task, as iOS requires before it ends the app.
@MainActor
final class BackgroundTime {
    private var task = UIBackgroundTaskIdentifier.invalid

    func begin(onExpiry: @escaping @MainActor () -> Void) {
        task = UIApplication.shared.beginBackgroundTask(withName: "Backing up photos") { [weak self] in
            onExpiry()
            self?.end()
        }
    }

    func end() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
}
