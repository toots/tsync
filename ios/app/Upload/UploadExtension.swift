import ExtensionFoundation
import Foundation
import Photos

/// ios-app.md §8.7: camera backup's files, sent by the system to the target
/// domain's listener while the app is not running.
@main
@available(iOS 26.4, *)
final class UploadExtension: PHBackgroundResourceUploadExtension {
    static let jobsMax = 20
    static let failureLimit = 3
    static let retriesMax: Int64 = 3

    private static let running = NSLock()
    private static let flag = NSLock()
    private static var terminating = false
    private static var stopped: Bool { flag.withLock { terminating } }

    private let library = PHPhotoLibrary.shared()

    required init() {}

    func process() -> PHBackgroundResourceUploadProcessingResult {
        guard Self.running.try() else { return .processing }
        defer { Self.running.unlock() }
        Self.flag.withLock { Self.terminating = false }
        do {
            return try run()
        } catch {
            CameraPreferences.lastOutcome = "failed: \(error.localizedDescription)"
            return .failure
        }
    }

    func notifyTermination() { Self.flag.withLock { Self.terminating = true } }

    private func run() throws -> PHBackgroundResourceUploadProcessingResult {
        guard CameraPreferences.enabled, CameraPreferences.bySystem,
              let domain = CameraPreferences.domain, let target = UploadTarget(domain)
        else { return .completed }
        let records = try CameraRecords()
        var progress = try retry(records, target)
        let (committed, settled) = try settle(records)
        progress = progress || settled
        if Self.stopped { return .processing }
        guard try CameraLibrary.discover(records, domain: domain, baseline: false, stop: { Self.stopped }) else {
            return .processing
        }
        if CameraPreferences.suspended == nil, try create(records, target) { progress = true }
        let inFlight = records.jobsInFlight()
        CameraPreferences.lastOutcome = "\(committed) uploaded" + (inFlight > 0 ? ", \(inFlight) uploading" : "")
        return progress || inFlight > 0 ? .processing : .completed
    }

    /// §8.7 step 1: a transient failure, or a first refusal of the signature,
    /// is sent again with a destination signed again.
    private func retry(_ records: CameraRecords, _ target: UploadTarget) throws -> Bool {
        let jobs = PHAssetResourceUploadJob.fetchJobs(action: .retry, options: nil)
        var progress = false
        for i in 0..<jobs.count where !Self.stopped {
            let job = jobs.object(at: i)
            guard let row = records.job(job.localIdentifier) else { continue }
            let headers = job.responseHeaderFields ?? [:]
            if headers["x-tsync-content-id"] != nil { continue }
            let kind = headers["x-tsync-kind"]
            guard (kind == nil && row.retries < Self.retriesMax) || (kind == "denied" && row.retries == 0),
                  let record = records.record(row.asset),
                  let asset = CameraLibrary.fetch([record.id]).first,
                  let destination = destination(record, part: row.part, asset: asset, target)
            else { continue }
            try library.performChangesAndWait {
                PHAssetResourceUploadJobChangeRequest(for: job)?.retry(destination: destination)
            }
            try records.retried(job.localIdentifier)
            progress = true
        }
        return progress
    }

    /// §8.7 step 1: every finished job settled into its record, then acknowledged.
    private func settle(_ records: CameraRecords) throws -> (Int, Bool) {
        let jobs = PHAssetResourceUploadJob.fetchJobs(action: .acknowledge, options: nil)
        var committed = 0
        var failures = CameraPreferences.failures
        for i in 0..<jobs.count where !Self.stopped {
            let job = jobs.object(at: i)
            if let row = records.job(job.localIdentifier) {
                let headers = job.responseHeaderFields ?? [:]
                if let contentId = headers["x-tsync-content-id"] {
                    try records.committed(job: job.localIdentifier, row, contentId: contentId)
                    committed += 1
                    failures = 0
                } else {
                    try records.dropJob(job.localIdentifier)
                    let kind = headers["x-tsync-kind"]
                    switch kind {
                    case "exists":
                        if let record = records.record(row.asset) {
                            try records.moveStem(
                                record.id, to: CameraLibrary.nextStem(record.stem, record.domain, records))
                        }
                    case "denied":
                        let reason = "the server refused the domain's secret"
                        try records.failed(row.asset, reason, now: CameraLibrary.now())
                        CameraPreferences.suspended = reason
                    default:
                        let reason = kind.map { "refused: \($0)" }
                            ?? job.error?.localizedDescription ?? "the upload did not complete"
                        try records.failed(row.asset, reason, now: CameraLibrary.now())
                        if kind != nil {
                            failures += 1
                            if failures >= Self.failureLimit { CameraPreferences.suspended = reason }
                        }
                    }
                }
            }
            try library.performChangesAndWait { PHAssetResourceUploadJobChangeRequest(for: job)?.acknowledge() }
        }
        CameraPreferences.failures = failures
        return (committed, jobs.count > 0)
    }

    /// §8.7 step 3: one job per file of each record due, in capture order.
    private func create(_ records: CameraRecords, _ target: UploadTarget) throws -> Bool {
        var inFlight = records.jobsInFlight()
        var progress = false
        for record in records.due(now: CameraLibrary.now()) {
            if Self.stopped || inFlight >= Self.jobsMax { break }
            guard let asset = CameraLibrary.fetch([record.id]).first else {
                try records.delete(record.id)
                continue
            }
            let (main, paired) = CameraLibrary.resources(asset)
            guard let main else {
                try records.delete(record.id)
                continue
            }
            var parts = [(CameraRecords.Record.Part.main, main)]
            if let paired, record.name(.paired) != nil { parts.append((.paired, paired)) }
            var made: [(String, CameraRecords.Record.Part)] = []
            do {
                try library.performChangesAndWait {
                    for (part, resource) in parts {
                        guard let destination = self.destination(record, part: part, asset: asset, target) else { continue }
                        let request = PHAssetResourceUploadJobChangeRequest.creationRequestForJob(
                            destination: destination, resource: resource)
                        if let id = request.placeholderForCreatedAssetResourceUploadJob?.localIdentifier {
                            made.append((id, part))
                        }
                    }
                }
            } catch let error as PHPhotosError where error.code == .limitExceeded {
                break
            }
            try records.transaction {
                for (id, part) in made { try records.addJob(id, asset: record.id, part: part, modified: record.modified) }
                if !made.isEmpty { try records.uploading(record.id) }
            }
            inFlight += made.count
            progress = progress || !made.isEmpty
        }
        return progress
    }

    private func destination(
        _ record: CameraRecords.Record, part: CameraRecords.Record.Part, asset: PHAsset, _ target: UploadTarget
    ) -> URLRequest? {
        guard let path = record.name(part) else { return nil }
        return target.destination(
            path: path, created: asset.creationDate, base: record.written ? record.contentId(part) : nil,
            wifiOnly: CameraPreferences.wifiOnly)
    }
}
