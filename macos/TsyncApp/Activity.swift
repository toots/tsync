import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// activity.md: the screen's parts, shared by the iOS app and the macOS panel.

/// One request to a domain's owner: the domain, the action, its other fields.
typealias OwnerAsk = (String, String, [String: Any]) async throws -> [String: Any]

/// The two replies, parsed (activity.md §1).
struct ActivityReport {
    static let staleAfter: TimeInterval = 10
    static let smoothing = 0.3
    var status: StatusReply?
    var stats: StatsReply?
    var raw: [String: Any] = [:]
    var failure: String?
    var answeredAt: Date?

    var body: DomainBody? { stats?.domains?.first }

    /// activity.md §3: the process's warnings and errors, newest first.
    var warnings: [SelfReport.Line] {
        var seen = Set<String>()
        var lines: [SelfReport.Line] = []
        for line in stats?.process?.recentErrors ?? [] {
            guard line.level == "warn" || line.level == "err" else { continue }
            let key = "\(line.t ?? 0) \(line.message ?? "")"
            if seen.insert(key).inserted { lines.append(line) }
        }
        return lines.sorted { ($0.t ?? 0) > ($1.t ?? 0) }
    }

    static func ask(_ domain: String, previous: ActivityReport?, owner: OwnerAsk) async -> ActivityReport {
        do {
            async let status = owner(domain, "status", [:])
            async let stats = owner(domain, "stats", ["arg": "frontend"])
            let (statusReply, statsReply) = try await (status, stats)
            var parsed: StatsReply = try decode(statsReply)
            parsed.domains = parsed.domains?.filter { $0.name == domain }
            // activity.md §1: a domain the reply does not list, or lists unanswered, did not answer.
            guard let body = parsed.domains?.first, body.unanswered != true else {
                return ActivityReport(failure: "no process reported it", answeredAt: previous?.answeredAt)
                    .orStill(previous)
            }
            parsed.domains = [body]
            var report = ActivityReport(
                status: try decode(statusReply), stats: parsed,
                raw: ["status": statusReply, "stats": statsReply], answeredAt: Date())
            if let previous { report.smooth(since: previous) }
            return report
        } catch {
            return ActivityReport(failure: error.localizedDescription, answeredAt: previous?.answeredAt)
                .orStill(previous)
        }
    }

    /// activity.md §1: a failure shows only once the last answer is `staleAfter` old.
    private func orStill(_ previous: ActivityReport?) -> ActivityReport {
        guard let previous, previous.status != nil, let at = previous.answeredAt,
              Date().timeIntervalSince(at) < Self.staleAfter else { return self }
        return previous
    }

    /// activity.md §1: rates and latencies averaged against the previous answer, by name.
    private mutating func smooth(since previous: ActivityReport) {
        func average(_ new: Double?, _ old: Double?) -> Double? {
            guard let new, let old else { return new }
            return old + Self.smoothing * (new - old)
        }
        func transfers(_ new: [StatusReply.Transfer]?, _ old: [StatusReply.Transfer]?) -> [StatusReply.Transfer]? {
            new?.map { transfer in
                var transfer = transfer
                transfer.rate = average(transfer.rate, old?.first { $0.key == transfer.key }?.rate)
                return transfer
            }
        }
        let uploading = transfers(status?.uploading, previous.status?.uploading)
        let downloading = transfers(status?.downloading, previous.status?.downloading)
        status?.uploading = uploading
        status?.downloading = downloading
        let oldStores = previous.body?.backends ?? []
        let stores = body?.backends?.map { store in
            var store = store
            let old = oldStores.first { $0.name == store.name }
            let latency = average(store.reach?.latencyMs, old?.reach?.latencyMs)
            let copyRate = average(store.copies?.jobsPerSec, old?.copies?.jobsPerSec)
            store.reach?.latencyMs = latency
            store.copies?.jobsPerSec = copyRate
            return store
        }
        stats?.domains?[0].backends = stores
    }

    private static func decode<T: Decodable>(_ reply: [String: Any]) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: reply))
    }
}

struct StatusReply: Decodable {
    struct Transfer: Decodable {
        var name: String?
        var rel: String?
        var bytes: Int?
        var size: Int?
        var rate: Double?
        /// Two files of one name in different folders are two transfers.
        var key: String { rel ?? name ?? "" }
    }
    var paused: Bool?
    var readOnly: Bool?
    var failing: String?
    var uploading: [Transfer]?
    var downloading: [Transfer]?
    var pendingUploads: Int?
    var pendingDownloads: Int?
    var pendingBytes: Int?
    var newMachines: [String]?
}

struct StatsReply: Decodable {
    var domains: [DomainBody]?
    var process: SelfReport?
    enum CodingKeys: String, CodingKey { case domains, process = "self" }
}

struct SelfReport: Decodable {
    struct Line: Decodable {
        var t: Double?
        var level: String?
        var message: String?
    }
    struct Usage: Decodable {
        var anonymousBytes: Int?
        var privateBytes: Int?
    }
    var recentErrors: [Line]?
    var process: Usage?
}

struct DomainBody: Decodable {
    struct Sync: Decodable {
        struct CannotFollow: Decodable {
            var entry: Int?
            var reason: String?
        }
        var pending: Int?
        var cannotFollow: CannotFollow?
        var failing: String?
    }
    struct Cache: Decodable {
        var bytes: Int?
        var pinnedBytes: Int?
        var maxCache: Int?
    }
    struct Queues: Decodable {
        var parked: Int?
        var lastError: String?
    }
    struct Settings: Decodable {
        var versioning: Bool?
        var readOnly: Bool?
        var symlinks: String?
        var chunkSize: Int?
        var extensions: [String]?
    }
    var name: String
    var unanswered: Bool?
    var mainOffline: Bool?
    var setAside: Int?
    var sync: Sync?
    var cache: Cache?
    var queues: Queues?
    var settings: Settings?
    var backends: [Store]?
}

struct Store: Decodable, Identifiable {
    struct Reach: Decodable {
        var reachable: Bool?
        var latencyMs: Double?
        var error: String?
    }
    struct Health: Decodable {
        var state: String?
        var heldForSeconds: Double?
        var failures: Int?
        var reason: String?
    }
    struct Corrupted: Decodable {
        var checked: Bool?
        var chunks: Int?
        var truncated: Bool?
    }
    struct Disk: Decodable {
        var freeBytes: Int?
        var totalBytes: Int?
    }
    struct Copies: Decodable {
        struct Job: Decodable {
            var job: String?
            var path: String?
            var chunks: Int?
            var checked: Int?
        }
        var owed: Int?
        var jobsPerSec: Double?
        var current: Job?
    }
    var name: String
    var role: String?
    var reach: Reach?
    var health: Health?
    var corrupted: Corrupted?
    var disk: Disk?
    var copies: Copies?
    var id: String { name }

    var isDown: Bool { health?.state == "down" }
    var isUnreachable: Bool { reach?.reachable == false }
    var damagedChunks: Int { corrupted?.checked == true ? corrupted?.chunks ?? 0 : 0 }
    var hasProblem: Bool { isDown || isUnreachable || damagedChunks > 0 }

    var connection: String {
        if let health, health.state == "down" {
            return "Paused after \(health.failures ?? 0) failures, for \(Format.duration(health.heldForSeconds)): \(health.reason ?? "")"
        }
        if let reach, reach.reachable == false { return "Unreachable: \(reach.error ?? "")" }
        if let latency = reach?.latencyMs, latency >= 1 { return "Connected, \(Int(latency.rounded())) ms" }
        return "Connected"
    }
}

/// activity.md §2: one domain.
struct DomainActivity: View {
    let domain: String
    let report: ActivityReport?
    let owner: OwnerAsk
    let refresh: () async -> Void
    /// file-provider §10: Open in Finder, and a transfer's row revealing its file.
    var open: (() -> Void)?
    var reveal: ((String) -> Void)?
    @State private var message: String?

    var body: some View {
        if let report, let status = report.status, let stats = report.body {
            answered(report, status, stats)
        } else {
            Section {
                if let failure = report?.failure {
                    Label("Not answering: \(failure)", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    if let at = report?.answeredAt {
                        Text("Last answered \(Format.relative(at))").font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView()
                }
            }
        }
    }

    @ViewBuilder
    private func answered(_ report: ActivityReport, _ status: StatusReply, _ stats: DomainBody) -> some View {
        Section {
            StateRow(state: DomainState(status, stats), paused: status.paused == true) {
                act("pause", ["arg": status.paused == true ? "off" : "on"])
            }
            if let message { Text(message).font(.footnote).foregroundStyle(.red) }
            if let open { Button("Open in Finder", action: open) }
        }
        Section("Transfers") { transfers(status) }
        Section("Problems") { problems(report, status, stats) }
        if let stores = stats.backends, !stores.isEmpty {
            Section("Stores") { ForEach(stores) { StoreCard(store: $0) } }
        }
        Section("This device") { device(report, stats) }
        Section {
            NavigationLink("Details") { ActivityDetails(domain: domain, report: report) }
        }
    }

    @ViewBuilder private func transfers(_ status: StatusReply) -> some View {
        let uploading = status.uploading ?? [], downloading = status.downloading ?? []
        let waiting = max((status.pendingUploads ?? 0) - uploading.count, 0)
        ForEach(uploading, id: \.key) { TransferRow(verb: "arrow.up", transfer: $0, reveal: reveal) }
        if waiting > 0 {
            Text("\(waiting) more waiting" + ((status.pendingBytes ?? 0) > 0 ? ", \(Format.bytes(status.pendingBytes)) to send" : ""))
                .font(.footnote).foregroundStyle(.secondary)
        }
        ForEach(downloading, id: \.key) { TransferRow(verb: "arrow.down", transfer: $0, reveal: reveal) }
        if uploading.isEmpty && downloading.isEmpty && waiting == 0 && (status.pendingDownloads ?? 0) == 0 {
            Text("Nothing to transfer").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func problems(_ report: ActivityReport, _ status: StatusReply, _ stats: DomainBody) -> some View {
        let machines = status.newMachines ?? []
        let parked = stats.queues?.parked ?? 0
        let setAside = stats.setAside ?? 0
        let stores = (stats.backends ?? []).filter(\.hasProblem)
        ForEach(machines, id: \.self) { name in
            ProblemRow(icon: "laptopcomputer", text: "\(name) can now unlock this vault", detail: nil)
        }
        // vault §6.3: listing the machines acknowledges them.
        if !machines.isEmpty { Button("Mark as seen") { act("vault_machines") } }
        if parked > 0 {
            ProblemRow(icon: "arrow.clockwise.circle", text: Format.count(parked, "upload") + " waiting to be retried",
                       detail: stats.queues?.lastError)
            Button("Retry now") { act("retry") }
        }
        if setAside > 0 {
            ProblemRow(icon: "archivebox", text: Format.count(setAside, "unreadable record") + " set aside", detail: "Kept and never run.")
        }
        ForEach(stores) { store in
            ProblemRow(
                icon: "externaldrive.badge.exclamationmark", text: store.name,
                detail: store.damagedChunks > 0 && !store.isDown && !store.isUnreachable
                    ? Format.count(store.damagedChunks, "damaged chunk") : store.connection)
        }
        if machines.isEmpty && parked == 0 && setAside == 0 && stores.isEmpty {
            Label("No problems", systemImage: "checkmark.circle").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func device(_ report: ActivityReport, _ stats: DomainBody) -> some View {
        let cache = stats.cache
        VStack(alignment: .leading, spacing: 4) {
            if let limit = cache?.maxCache, limit > 0 {
                Meter(label: "Cache", value: "\(Format.bytes(cache?.bytes)) of \(Format.bytes(limit))",
                      used: cache?.bytes ?? 0, total: limit)
            } else {
                LabeledContent("Cache", value: Format.bytes(cache?.bytes))
            }
            if let pinned = cache?.pinnedBytes, pinned > 0 {
                Text("\(Format.bytes(pinned)) kept offline").font(.footnote).foregroundStyle(.secondary)
            }
        }
        if let usage = report.stats?.process?.process, let ram = usage.anonymousBytes ?? usage.privateBytes {
            Text("\(Self.process) uses \(Format.bytes(ram)) of memory").font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Who answers `stats`: the File Provider extension on iOS, the service on macOS.
    #if canImport(UIKit)
    private static let process = "The extension"
    #else
    private static let process = "The service"
    #endif

    private func act(_ action: String, _ fields: [String: Any] = [:]) {
        Task {
            do {
                _ = try await owner(domain, action, fields)
                message = nil
            } catch {
                message = error.localizedDescription
            }
            await refresh()
        }
    }
}

/// activity.md §2.1: the first state that holds.
struct DomainState {
    enum Tone { case neutral, warning, failure }
    let badge: String
    let sentence: String?
    let tone: Tone

    init(_ status: StatusReply, _ stats: DomainBody) {
        let uploads = status.pendingUploads ?? 0, downloads = status.pendingDownloads ?? 0
        if status.paused == true {
            (badge, sentence, tone) = ("Paused", "Changes stay on this device until you resume.", .warning)
        } else if let failing = status.failing ?? stats.sync?.failing {
            (badge, sentence, tone) = ("Not syncing", "\(failing). Retried until it works.", .failure)
        } else if let stuck = stats.sync?.cannotFollow {
            (badge, sentence, tone) = ("Not syncing", "Can't follow change \(stuck.entry ?? 0): \(stuck.reason ?? ""). Retried until it works.", .failure)
        } else if stats.mainOffline == true {
            (badge, sentence, tone) = ("Store offline", "Opening files and uploading wait for the main store.", .warning)
        } else if status.readOnly == true {
            (badge, sentence, tone) = ("Read-only", "This domain can't be changed from this device.", .warning)
        } else if uploads + downloads + (stats.sync?.pending ?? 0) > 0 {
            let parts = [uploads > 0 ? "\(uploads) to upload" : nil, downloads > 0 ? "\(downloads) to download" : nil]
            (badge, sentence, tone) = ("Syncing", parts.compactMap { $0 }.joined(separator: ", "), .neutral)
        } else {
            (badge, sentence, tone) = ("Up to date", nil, .neutral)
        }
    }
}

struct StateRow: View {
    let state: DomainState
    let paused: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(state.badge)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(color.opacity(0.18), in: Capsule())
                    .foregroundStyle(color)
                if let sentence = state.sentence, !sentence.isEmpty { Text(sentence).font(.footnote) }
            }
            Spacer()
            Button(paused ? "Resume" : "Pause", action: toggle).buttonStyle(.bordered)
        }
    }

    private var color: Color {
        switch state.tone {
        case .neutral: return state.badge == "Up to date" ? .green : .blue
        case .warning: return .orange
        case .failure: return .red
        }
    }
}

struct TransferRow: View {
    let verb: String
    let transfer: StatusReply.Transfer
    var reveal: ((String) -> Void)?

    var body: some View {
        let done = transfer.bytes ?? 0, size = transfer.size ?? 0
        VStack(alignment: .leading, spacing: 4) {
            if let reveal, let rel = transfer.rel {
                Button { reveal(rel) } label: { name }.buttonStyle(.plain)
            } else {
                name
            }
            if size > 0 {
                ProgressView(value: Double(min(done, size)), total: Double(size))
                Text("\(Format.bytes(done)) of \(Format.bytes(size))" + ((transfer.rate ?? 0) > 0 ? " · \(Format.bytes(Int(transfer.rate ?? 0)))/s" : ""))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var name: some View {
        Label(transfer.name ?? "", systemImage: verb).lineLimit(1).truncationMode(.middle)
    }
}

struct ProblemRow: View {
    let icon: String
    let text: String
    let detail: String?

    var body: some View {
        Label {
            VStack(alignment: .leading) {
                Text(text)
                if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
            }
        } icon: {
            Image(systemName: icon).foregroundStyle(.orange)
        }
    }
}

/// activity.md §3: at most `shownErrors`, the rest behind Show all.
struct WarningsSection: View {
    let lines: [SelfReport.Line]

    var body: some View {
        if !lines.isEmpty {
            Section("Warnings and errors") {
                ForEach(Array(lines.prefix(ActivityDetails.shownErrors).enumerated()), id: \.offset) { ErrorRow(line: $0.element) }
                if lines.count > ActivityDetails.shownErrors {
                    NavigationLink("Show all \(lines.count)") {
                        List(Array(lines.enumerated()), id: \.offset) { ErrorRow(line: $0.element) }.navigationTitle("Warnings and errors")
                    }
                }
            }
        }
    }
}

struct ErrorRow: View {
    let line: SelfReport.Line

    var body: some View {
        Label {
            VStack(alignment: .leading) {
                Text(line.message ?? "").font(.footnote)
                Text(Format.relative(Date(timeIntervalSince1970: line.t ?? 0))).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: line.level == "err" ? "xmark.octagon" : "exclamationmark.triangle")
                .foregroundStyle(line.level == "err" ? .red : .orange)
        }
    }
}

/// A labelled bar of a part against its whole.
struct Meter: View {
    let label: String
    let value: String
    let used: Int
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(value).foregroundStyle(.secondary)
            }
            .font(.footnote)
            ProgressView(value: Double(min(max(used, 0), total)), total: Double(total))
                .tint(Double(used) / Double(total) > 0.9 ? .orange : .accentColor)
        }
    }
}

/// activity.md §2.4.
struct StoreCard: View {
    let store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(store.name).font(.headline)
                if let role = store.role, role != store.name { Text(role.capitalized).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Image(systemName: store.hasProblem ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(store.hasProblem ? .orange : .green)
            }
            Text(store.connection).font(.footnote).foregroundStyle(store.isDown || store.isUnreachable ? .red : .secondary)
            if let free = store.disk?.freeBytes, let total = store.disk?.totalBytes, total > 0 {
                Meter(label: "Space", value: "\(Format.bytes(free)) free of \(Format.bytes(total))",
                      used: total - free, total: total)
            }
            if let copies = store.copies, let owed = copies.owed, owed > 0 {
                Text("\(owed) to copy" + ((copies.jobsPerSec ?? 0) > 0 ? String(format: ", %.1f/s", copies.jobsPerSec ?? 0) : ""))
                    .font(.footnote)
                if let job = copies.current, let chunks = job.chunks, chunks > 0 {
                    Text((job.path ?? job.job) ?? "").font(.caption).lineLimit(1).truncationMode(.middle)
                    ProgressView(value: Double(min(job.checked ?? 0, chunks)), total: Double(chunks))
                }
            }
            if store.damagedChunks > 0 {
                Text(Format.count(store.damagedChunks, "damaged chunk") + (store.corrupted?.truncated == true ? " or more" : ""))
                    .font(.footnote).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }
}

/// activity.md §2.6: the settings in force; the replies only as Copy report.
struct ActivityDetails: View {
    static let shownErrors = 5
    let domain: String
    let report: ActivityReport

    var body: some View {
        let settings = report.body?.settings
        Form {
            Section("Settings in force") {
                LabeledContent("Versioning", value: settings?.versioning == true ? "On" : "Off")
                LabeledContent("Read-only", value: settings?.readOnly == true ? "Yes" : "No")
                if let symlinks = settings?.symlinks { LabeledContent("Symbolic links", value: symlinks.capitalized) }
                if let chunk = settings?.chunkSize { LabeledContent("Chunk size", value: Format.bytes(chunk)) }
                LabeledContent("Extensions", value: (settings?.extensions ?? []).isEmpty ? "None" : (settings?.extensions ?? []).joined(separator: ", "))
            }
            if let at = report.answeredAt {
                Section { LabeledContent("Asked", value: Format.relative(at)) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(domain)
        .toolbar { Button("Copy report") { Pasteboard.copy(Self.json(report.raw)) } }
    }

    private static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

enum Format {
    /// menu-model §6: the noun in the singular for one.
    static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    static func bytes(_ value: Int?) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value ?? 0), countStyle: .file)
    }

    static func relative(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }

    static func duration(_ seconds: Double?) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: seconds ?? 0) ?? ""
    }
}

enum Pasteboard {
    static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
