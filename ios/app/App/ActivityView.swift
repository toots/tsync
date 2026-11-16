import SwiftUI
import UIKit

/// ios-app.md §2.1: each domain's `status` and `stats`, asked every
/// `statusPoll` while the screen is visible.
struct ActivityView: View {
    @EnvironmentObject private var model: AppModel
    @State private var reports: [String: ActivityReport] = [:]
    private static let statusPoll: UInt64 = 2_000_000_000

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.entries) { entry in
                    Section(model.entries.count > 1 ? entry.name : "") {
                        if model.turnedOff.contains(entry.name) {
                            Text("Turned off in Files: Browse, then More, then Edit").foregroundStyle(.orange)
                        } else {
                            DomainActivity(domain: entry.name, report: reports[entry.name]) {
                                reports[entry.name] = await ActivityReport.ask(entry.name)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Activity")
            .task { await poll() }
        }
    }

    /// `.task` ends when the screen goes, which ends the polling.
    private func poll() async {
        while !Task.isCancelled {
            for entry in model.entries where !model.turnedOff.contains(entry.name) {
                reports[entry.name] = await ActivityReport.ask(entry.name)
            }
            try? await Task.sleep(nanoseconds: Self.statusPoll)
        }
    }
}

enum ActivityReport {
    case answered(status: [String: Any], stats: [String: Any])
    case unanswered(String)

    static func ask(_ domain: String) async -> ActivityReport {
        do {
            async let status = FileStore.owner(domain, "status")
            async let stats = FileStore.owner(domain, "stats", ["arg": "frontend"])
            return .answered(status: try await status, stats: try await stats)
        } catch {
            return .unanswered(error.localizedDescription)
        }
    }
}

struct DomainActivity: View {
    let domain: String
    let report: ActivityReport?
    let refresh: () async -> Void
    @State private var message: String?

    var body: some View {
        switch report {
        case nil:
            ProgressView()
        case .unanswered(let reason):
            Text("\(domain) did not answer: \(reason)").foregroundStyle(.secondary)
        case .answered(let status, let stats):
            answered(status, stats)
        }
    }

    @ViewBuilder private func answered(_ status: [String: Any], _ stats: [String: Any]) -> some View {
        let paused = status["paused"] as? Bool ?? false
        let body = (stats["domains"] as? [[String: Any]])?.first { $0["name"] as? String == domain }
        let queues = body?["queues"] as? [String: Any]
        let uploading = status["uploading"] as? [[String: Any]] ?? []
        let downloading = status["downloading"] as? [[String: Any]] ?? []
        let waiting = max((status["pendingUploads"] as? Int ?? 0) - uploading.count, 0)
        let parked = queues?["parked"] as? Int ?? 0
        let recent = (stats["self"] as? [String: Any])?["recentErrors"] as? [[String: Any]] ?? []

        Text(Self.state(status)).font(.headline)
        ForEach(Array(uploading.enumerated()), id: \.offset) { _, transfer in
            Transfer(verb: "Uploading", transfer: transfer)
        }
        if waiting > 0 {
            Text("\(waiting) more to upload, \(Self.bytes(status["pendingBytes"])) owed").foregroundStyle(.secondary)
        }
        ForEach(Array(downloading.enumerated()), id: \.offset) { _, transfer in
            Transfer(verb: "Downloading", transfer: transfer)
        }
        if parked > 0 {
            VStack(alignment: .leading) {
                Text("\(parked) uploads waiting to be retried")
                if let last = queues?["lastError"] as? String { Text(last).font(.footnote).foregroundStyle(.secondary) }
            }
            Button("Retry now") { act("retry") }
        }
        ForEach(Array(recent.enumerated()), id: \.offset) { _, line in
            VStack(alignment: .leading) {
                Text("\(Self.time(line["t"])) \(line["level"] as? String ?? "")").font(.caption).foregroundStyle(.secondary)
                Text(line["message"] as? String ?? "").font(.footnote)
            }
        }
        Button(paused ? "Resume" : "Pause") { act("pause", ["arg": paused ? "off" : "on"]) }
        NavigationLink("Details") { ActivityDetails(domain: domain, status: status, stats: stats) }
        if let message { Text(message).foregroundStyle(.red) }
    }

    private func act(_ action: String, _ fields: [String: Any] = [:]) {
        Task {
            do {
                _ = try await FileStore.owner(domain, action, fields)
                message = nil
            } catch {
                message = error.localizedDescription
            }
            await refresh()
        }
    }

    private static func state(_ status: [String: Any]) -> String {
        if status["paused"] as? Bool == true { return "Paused" }
        if let failing = status["failing"] as? String { return "Not syncing: \(failing)" }
        if status["readOnly"] as? Bool == true { return "Read-only" }
        let busy = (status["pendingUploads"] as? Int ?? 0) + (status["pendingDownloads"] as? Int ?? 0)
        return busy > 0 ? "Syncing" : "Up to date"
    }

    static func bytes(_ value: Any?) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value as? Int ?? 0), countStyle: .file)
    }

    private static func time(_ value: Any?) -> String {
        Date(timeIntervalSince1970: value as? Double ?? 0).formatted(date: .omitted, time: .standard)
    }
}

/// One upload or download, with its progress when its size is known.
struct Transfer: View {
    let verb: String
    let transfer: [String: Any]

    var body: some View {
        let done = transfer["bytes"] as? Int ?? 0, size = transfer["size"] as? Int ?? 0
        VStack(alignment: .leading) {
            Text("\(verb) \(transfer["name"] as? String ?? "")")
            if size > 0 {
                ProgressView(value: Double(min(done, size)), total: Double(size))
                let rate = transfer["rate"] as? Double ?? 0
                Text("\(DomainActivity.bytes(done)) of \(DomainActivity.bytes(size))"
                    + (rate > 0 ? ", \(DomainActivity.bytes(Int(rate)))/s" : ""))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

/// The two replies as indented JSON, for diagnosis.
struct ActivityDetails: View {
    let domain: String
    let status: [String: Any]
    let stats: [String: Any]

    var body: some View {
        let text = Self.json(["status": status, "stats": stats])
        ScrollView {
            Text(text).font(.system(.caption2, design: .monospaced)).textSelection(.enabled).padding()
        }
        .navigationTitle(domain)
        .toolbar { Button("Copy") { UIPasteboard.general.string = text } }
    }

    private static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
