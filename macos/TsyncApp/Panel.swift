import AppKit
import SwiftUI

/// file-provider §10: what the panel shows beside the domains, set on the main queue.
final class PanelModel: ObservableObject {
    @Published var icon = "tsync-error-symbolic"
    @Published var summary = "The service is unreachable"
    @Published var allPaused = false
    @Published var reachable = false
    @Published var hasCodes = false
    @Published var notices: [String] = []
    @Published var autofillOff = false
    /// The registered domains, in config order.
    @Published var domains: [String] = []

    var pause: (Bool) -> Void = { _ in }
    var showCodes: () -> Void = {}
    var openSettings: () -> Void = {}
    var open: (String) -> Void = { _ in }
    var reveal: (String, String) -> Void = { _, _ in }
}

/// One request to the owner on its own thread: `OwnerClient.call` blocks.
func ownerAsk(_ domain: String, _ action: String, _ fields: [String: Any]) async throws
    -> [String: Any]
{
    var request = fields
    request["action"] = action
    request["domain"] = domain
    return try await withCheckedThrowingContinuation { done in
        Thread.detachNewThread { done.resume(with: Result { try OwnerClient.call(request) }) }
    }
}

struct Panel: View {
    @ObservedObject var model: PanelModel
    @AppStorage("panel-domain") private var picked = ""
    @State private var reports: [String: ActivityReport] = [:]
    private static let statusPoll: UInt64 = 2_000_000_000

    var body: some View {
        NavigationStack {
            List {
                notices
                Section { summary }
                if model.domains.count > 1 {
                    Picker("Domain", selection: Binding { shown ?? "" } set: { picked = $0 }) {
                        ForEach(model.domains, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                if let domain = shown {
                    DomainActivity(
                        domain: domain, report: reports[domain], owner: ownerAsk,
                        refresh: { await ask(domain) },
                        open: { model.open(domain) },
                        reveal: { model.reveal(domain, $0) }
                    )
                    .id(domain)
                    WarningsSection(lines: reports[domain]?.warnings ?? [])
                }
                if model.hasCodes {
                    Section { Button("One-time codes…", action: model.showCodes) }
                }
            }
        }
        .frame(width: 380, height: 560)
        .task(id: shown) { await poll() }
    }

    @ViewBuilder private var notices: some View {
        if !model.notices.isEmpty || model.autofillOff {
            Section {
                ForEach(model.notices, id: \.self) {
                    ProblemRow(icon: "exclamationmark.triangle", text: $0, detail: nil)
                }
                if model.autofillOff {
                    ProblemRow(
                        icon: "key", text: "AutoFill is off for tsync",
                        detail: "Turn it on in System Settings, under Passwords.")
                    Button("Open System Settings", action: model.openSettings)
                }
            }
        }
    }

    private var summary: some View {
        HStack {
            if let image = NSImage(named: model.icon) {
                Image(nsImage: image).renderingMode(.template)
            }
            Text(model.summary).font(.headline)
            Spacer()
            Button(model.allPaused ? "Resume all" : "Pause all") { model.pause(!model.allPaused) }
                .disabled(!model.reachable)
        }
    }

    /// activity.md §2: a pick no longer listed falls back to the first.
    private var shown: String? {
        model.domains.first { $0 == picked } ?? model.domains.first
    }

    /// `.task` ends when the panel closes or the pick changes, which ends the polling.
    private func poll() async {
        guard let domain = shown else { return }
        while !Task.isCancelled {
            await ask(domain)
            try? await Task.sleep(nanoseconds: Self.statusPoll)
        }
    }

    private func ask(_ domain: String) async {
        reports[domain] = await ActivityReport.ask(domain, previous: reports[domain], owner: ownerAsk)
    }
}
