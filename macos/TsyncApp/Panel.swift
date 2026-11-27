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
                        codes: model.hasCodes ? model.showCodes : nil,
                        passwords: { AnyView(PasswordsPage(domain: domain, model: model)) }
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

/// file-provider §10.2: one domain's logins, searched as typed; a password is
/// asked of the owner only when its button is clicked.
struct PasswordsPage: View {
    struct Login: Identifiable {
        let id: String
        let title: String
        let username: String
    }

    let domain: String
    @ObservedObject var model: PanelModel
    @State private var filter = ""
    @State private var logins: [Login] = []
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
                } else if logins.isEmpty {
                    Text("No passwords").foregroundStyle(.secondary)
                }
                ForEach(logins) { row($0) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Passwords")
        .task(id: filter) {
            // A new keystroke cancels this task, so only a pause asks the owner.
            if !filter.isEmpty { try? await Task.sleep(nanoseconds: Self.typing) }
            if !Task.isCancelled { await load() }
        }
    }

    private func row(_ login: Login) -> some View {
        HStack {
            Image(systemName: "key").foregroundStyle(.secondary)
            VStack(alignment: .leading) {
                Text(login.title.isEmpty ? login.username : login.title).lineLimit(1)
                if !login.title.isEmpty && !login.username.isEmpty {
                    Text(login.username).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if !login.username.isEmpty {
                Button { Pasteboard.copy(login.username) } label: { Image(systemName: "person") }
                    .buttonStyle(.borderless).help("Copy username")
            }
            Button { model.copyPassword(domain, login.id) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).help("Copy password")
        }
    }

    private func load() async {
        do {
            let reply = try await ownerAsk(domain, "passwords_list", filter.isEmpty ? [:] : ["filter": filter])
            let records = reply["records"] as? [[String: Any]] ?? []
            logins = records.compactMap { record in
                guard record["kind"] as? String == "login", let id = record["id"] as? String else { return nil }
                return Login(
                    id: id, title: record["title"] as? String ?? "",
                    username: record["username"] as? String ?? "")
            }
            (locked, problem) = (false, nil)
        } catch let failure as OwnerFailure {
            logins = []
            locked = failure.code == "locked"
            problem = failure.code == "not_found" ? "This domain has no vault" : failure.message
        } catch {
            logins = []
            (locked, problem) = (false, error.localizedDescription)
        }
    }
}
