import AppKit
import SwiftUI

/// file-provider §10: what the panel shows beside the domains, set on the main queue.
final class PanelModel: ObservableObject {
    @Published var icon = "tsync-error-symbolic"
    @Published var summary = "The service is unreachable"
    @Published var allPaused = false
    @Published var reachable = false
    @Published var notices: [String] = []
    @Published var autofillOff = false
    /// The registered domains, in config order.
    @Published var domains: [String] = []

    var pause: (Bool) -> Void = { _ in }
    var copyCode: (String, String) -> Void = { _, _ in }
    var addCode: (String) -> Void = { _ in }
    var copyPassword: (String, String) -> Void = { _, _ in }
    var unlock: (String) -> Void = { _ in }
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
    static let width: CGFloat = 380
    static let height: CGFloat = 560
    @ObservedObject var model: PanelModel
    let height: CGFloat
    @AppStorage("panel-domain") private var picked = ""
    @State private var reports: [String: ActivityReport] = [:]
    private static let statusPoll: UInt64 = 2_000_000_000

    var body: some View {
        NavigationStack {
            // A grouped form is macOS's card layout; a List draws an iOS table.
            Form {
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
                        reveal: { model.reveal(domain, $0) },
                        codes: { AnyView(VaultPage(kind: .codes, domain: domain, model: model)) },
                        passwords: { AnyView(VaultPage(kind: .passwords, domain: domain, model: model)) }
                    )
                    .id(domain)
                    WarningsSection(lines: reports[domain]?.warnings ?? [])
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: Self.width, height: height)
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
                    Button(action: model.openSettings) { Label("Open System Settings", systemImage: "gear") }
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
            Button { model.pause(!model.allPaused) } label: {
                Label(model.allPaused ? "Resume all" : "Pause all",
                      systemImage: model.allPaused ? "play.fill" : "pause.fill")
            }
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

/// file-provider §10.1, §10.2: one domain's codes or logins, searched as
/// typed. A click on a row copies its secret, asked of the owner then.
struct VaultPage: View {
    struct Item: Identifiable {
        let id: String
        let title: String
        let detail: String
        /// A one-time code and when it runs out.
        var code: String?
        var expires: Date?
    }

    enum Kind {
        case codes, passwords
    }

    let kind: Kind
    let domain: String
    @ObservedObject var model: PanelModel
    @State private var filter = ""
    @State private var items: [Item] = []
    @State private var locked = false
    @State private var problem: String?
    private static let typing: UInt64 = 250_000_000

    var body: some View {
        Form {
            BackRow()
            Section {
                TextField(text: $filter, prompt: Text("Search")) {
                    Label("Search", systemImage: "magnifyingglass")
                }
                if locked {
                    Label("Locked", systemImage: "lock.fill")
                    Button { model.unlock(domain) } label: { Label("Unlock…", systemImage: "lock.open") }
                } else if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                } else if items.isEmpty {
                    Text(kind == .codes ? "No codes" : "No passwords").foregroundStyle(.secondary)
                }
                ForEach(items) { row($0) }
            }
            if kind == .codes && !locked {
                Section {
                    Button { model.addCode(domain) } label: { Label("Add a code…", systemImage: "plus") }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(kind == .codes ? "One-time codes" : "Passwords")
        .task(id: filter) {
            // A new keystroke cancels this task, so only a pause asks the owner.
            if !filter.isEmpty { try? await Task.sleep(nanoseconds: Self.typing) }
            // §10.1: asked again when a shown code runs out.
            while !Task.isCancelled {
                await load()
                guard let next = items.compactMap(\.expires).min() else { return }
                let wait = max(next.timeIntervalSinceNow, 1)
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
    }

    private func row(_ item: Item) -> some View {
        HStack {
            Button { copy(item) } label: {
                HStack {
                    Image(systemName: kind == .codes ? "123.rectangle" : "key").foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        Text(item.title).lineLimit(1)
                        if !item.detail.isEmpty {
                            Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    if let code = item.code { CodeView(code: code, expires: item.expires) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(kind == .codes ? "Copy the code" : "Copy the password")
            if kind == .passwords && !item.detail.isEmpty {
                Button { Pasteboard.copy(item.detail) } label: { Image(systemName: "person") }
                    .buttonStyle(.borderless).help("Copy username")
            }
        }
    }

    private func copy(_ item: Item) {
        switch kind {
        case .codes: model.copyCode(domain, item.id)
        case .passwords: model.copyPassword(domain, item.id)
        }
    }

    private func load() async {
        let action = kind == .codes ? "totp_list" : "passwords_list"
        do {
            let reply = try await ownerAsk(domain, action, filter.isEmpty ? [:] : ["filter": filter])
            let records = reply["records"] as? [[String: Any]] ?? []
            items = records.compactMap(item)
            (locked, problem) = (false, nil)
        } catch let failure as OwnerFailure {
            items = []
            locked = failure.code == "locked"
            problem = failure.code == "not_found" ? "This domain has no vault" : failure.message
        } catch {
            items = []
            (locked, problem) = (false, error.localizedDescription)
        }
    }

    /// Notes and passkeys hold no password; a code record is always listed.
    private func item(_ record: [String: Any]) -> Item? {
        guard let id = record["id"] as? String else { return nil }
        switch kind {
        case .passwords:
            guard record["kind"] as? String == "login" else { return nil }
            return labelled(id, record["title"], record["username"])
        case .codes:
            var item = labelled(id, record["issuer"], record["account"])
            item.code = record["code"] as? String
            item.expires = (record["secondsLeft"] as? Int).map { Date().addingTimeInterval(Double($0)) }
            return item
        }
    }

    private func labelled(_ id: String, _ first: Any?, _ second: Any?) -> Item {
        let first = first as? String ?? "", second = second as? String ?? ""
        return first.isEmpty
            ? Item(id: id, title: second, detail: "")
            : Item(id: id, title: first, detail: second)
    }
}

/// A one-time code with the seconds it has left, warning for the last five.
struct CodeView: View {
    let code: String
    let expires: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = max(Int((expires ?? context.date).timeIntervalSince(context.date).rounded(.up)), 0)
            HStack(spacing: 6) {
                Text(code).font(.title3.monospacedDigit().weight(.semibold))
                if expires != nil {
                    Text("\(left)s").font(.caption.monospacedDigit())
                        .foregroundStyle(left <= 5 ? .orange : .secondary)
                }
            }
        }
    }
}
