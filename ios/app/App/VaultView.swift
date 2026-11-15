import SwiftUI
import UniformTypeIdentifiers
import VisionKit

/// ios-app.md §6, after android-app §10.8: Codes and Passwords, every domain
/// shown as one, each under its header when there are several.
struct VaultView: View {
    @EnvironmentObject private var vault: VaultModel
    @SceneStorage("vaultTab") private var tab = "codes"

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if vault.domains.contains(where: { $0.state == .unlocked }) {
                    Picker("", selection: $tab) {
                        Text("Codes").tag("codes")
                        Text("Passwords").tag("passwords")
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    if tab == "codes" { CodesList() } else { PasswordsList() }
                } else {
                    // ios-app §6 Locked: nothing to list yet, so no tabs.
                    List { ForEach(vault.domains) { DomainSection(domain: $0) {} } }
                }
            }
            .navigationTitle("Vault")
            .toolbar { ToolbarItem(placement: .primaryAction) { VaultMenu() } }
        }
    }
}

/// android-app §10.8 Menu: each domain's state, Lock and Forget.
struct VaultMenu: View {
    @EnvironmentObject private var vault: VaultModel
    @State private var confirming: (name: String, forget: Bool)?

    var body: some View {
        Menu {
            ForEach(vault.domains) { domain in
                Section(vault.domains.count > 1 ? domain.name : "") {
                    Text(domain.status)
                    if domain.state == .unlocked {
                        Button("Lock") { confirming = (domain.name, false) }
                    }
                    if case .locked(true, _) = domain.state {
                        Button("Forget the secret key on this iPhone") { confirming = (domain.name, true) }
                    } else if domain.state == .unlocked {
                        Button("Forget the secret key on this iPhone") { confirming = (domain.name, true) }
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .confirmationDialog(
            confirming?.forget == true
                ? "The next unlock needs the secret key again." : "Codes need the passphrase again afterwards.",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible
        ) {
            if let confirming {
                Button(confirming.forget ? "Forget the secret key" : "Lock", role: .destructive) {
                    Task { _ = await vault.lock(confirming.name, forget: confirming.forget) }
                }
            }
        }
    }
}

/// A domain's header and, in place of its rows, its state.
struct DomainSection<Rows: View>: View {
    @EnvironmentObject private var vault: VaultModel
    let domain: VaultModel.Domain
    @ViewBuilder let rows: () -> Rows

    var body: some View {
        Section {
            switch domain.state {
            case .asking: ProgressView()
            case .unreachable(let why): Text("Cannot reach \(domain.name): \(why)").foregroundStyle(.secondary)
            case .turnedOff:
                Text("Turned off in Files: in Files, Browse, then More, then Edit.").foregroundStyle(.secondary)
            case .noVault:
                Text("This domain has no vault: it is created on a computer with tsync vault init.")
                    .foregroundStyle(.secondary)
            case .corrupt(let why): Text(why).foregroundStyle(.secondary)
            case .locked(let enrolled, let lockedBy): UnlockForm(domain: domain.name, enrolled: enrolled, lockedBy: lockedBy)
            case .unlocked: rows()
            }
        } header: {
            if case .locked = domain.state {
                Text(vault.domains.count > 1 ? "Unlock \(domain.name)" : "Unlock the vault")
            } else if vault.domains.count > 1 {
                HStack {
                    if let look = domain.look { Image(uiImage: look) }
                    Text(domain.name)
                }
            }
        } footer: {
            if case .locked = domain.state {
                Text("Enter the vault's passphrase to see its codes and passwords.")
            }
        }
    }
}

/// android-app §10.8 *locked*: the passphrase, and the secret key while this
/// iPhone is not enrolled; the keys are derived here (vault §6.4).
struct UnlockForm: View {
    @EnvironmentObject private var vault: VaultModel
    let domain: String
    let enrolled: Bool
    let lockedBy: String?
    @State private var passphrase = ""
    @State private var secretKey = ""
    @State private var askKey = false
    @State private var failure: String?
    @State private var unlocking = false

    var body: some View {
        if let lockedBy { Text(lockedNote(lockedBy)).font(.footnote).foregroundStyle(.secondary) }
        SecretField("Passphrase", text: $passphrase)
        if !enrolled || askKey {
            SecretField("Secret key", text: $secretKey)
            Text("This iPhone also needs the vault's secret key, the first time.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        if let failure { Text(failure).font(.footnote).foregroundStyle(.red) }
        Button(unlocking ? "Unlocking…" : "Unlock") {
            unlocking = true
            failure = nil
            let typed = secretKey.isEmpty ? nil : secretKey
            Task {
                failure = await vault.unlock(domain, passphrase: passphrase, secretKey: typed)
                unlocking = false
                if failure?.contains("secret key") == true { askKey = true }
                if failure == nil {
                    passphrase = ""
                    secretKey = ""
                }
            }
        }
        .disabled(unlocking || passphrase.isEmpty)
    }

    private func lockedNote(_ by: String) -> String {
        switch by {
        case "idle": return "Locked after a while unused."
        case "screen": return "Locked when the screen locked."
        case "age": return "Locked: the unlock had lasted long enough."
        default: return "Locked."
        }
    }
}

/// security-model §10.6 Fields for a secret: masked, with a control that shows
/// it while on; nothing the keyboard or AutoFill keeps.
struct SecretField: View {
    let title: String
    @Binding var text: String
    @State private var shown = false

    init(_ title: String, text: Binding<String>) {
        self.title = title
        _text = text
    }

    var body: some View {
        HStack {
            Group {
                if shown { TextField(title, text: $text) } else { SecureField(title, text: $text) }
            }
            .textContentType(nil)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .keyboardType(.asciiCapable)
            Button { shown.toggle() } label: { Image(systemName: shown ? "eye.slash" : "eye") }
                .buttonStyle(.borderless)
                .accessibilityLabel(shown ? "Hide" : "Show")
        }
    }
}

// MARK: Codes

struct CodeRow: Identifiable, Equatable {
    let domain: String
    let id: String
    let issuer: String
    let account: String
    let code: String
    let expires: Date
}

struct CodesList: View {
    @EnvironmentObject private var vault: VaultModel
    @Environment(\.scenePhase) private var phase
    @State private var rows: [String: [CodeRow]] = [:]
    @State private var corrupt: [String: Int] = [:]
    @State private var filter = ""
    @State private var adding = false
    @State private var renaming: CodeRow?
    @State private var removing: CodeRow?
    @State private var notice: String?

    var body: some View {
        List {
            ForEach(vault.domains) { domain in
                DomainSection(domain: domain) {
                    ForEach(rows[domain.name] ?? []) { row in code(row) }
                    if let n = corrupt[domain.name], n > 0 { Text("\(n) records do not open").foregroundStyle(.secondary) }
                }
            }
        }
        .searchable(text: $filter)
        .onChange(of: filter) { _ in load() }
        .task(id: vault.domains) { load() }
        .onChange(of: phase) { if $0 == .active { load() } }
        .toolbar { ToolbarItem(placement: .bottomBar) { Button("Add") { adding = true } } }
        .sheet(isPresented: $adding) { AddCode(domains: unlockedNames) { load() } }
        .sheet(item: $renaming) { RenameCode(row: $0) { load() } }
        .confirmationDialog(
            "Remove \(removing.map { label($0) } ?? "")?", isPresented: isPresent($removing), titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                guard let row = removing else { return }
                Task {
                    _ = try? await VaultModel.ask(row.domain, "totp_remove", ["id": row.id])
                    load()
                }
            }
        }
        .alert(notice ?? "", isPresented: isPresent($notice)) { Button("OK") {} }
        .privacySensitive()
    }

    private var unlockedNames: [String] { vault.domains.filter { $0.state == .unlocked }.map(\.name) }

    private func label(_ row: CodeRow) -> String { row.account.isEmpty ? row.issuer : "\(row.issuer) — \(row.account)" }

    @ViewBuilder private func code(_ row: CodeRow) -> some View {
        Button {
            Copy.secret(row.code)
            notice = "Copied the code of \(label(row))"
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(row.issuer)
                    if !row.account.isEmpty { Text(row.account).font(.footnote).foregroundStyle(.secondary) }
                }
                Spacer()
                Text(grouped(row.code)).font(.title3.monospacedDigit())
                // The owner computes every code: asked again when one expires.
                Text(row.expires, style: .timer).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                    .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now in
                        if now >= row.expires { load() }
                    }
            }
        }
        .foregroundStyle(.primary)
        .contextMenu {
            Button("Rename") { renaming = row }
            Button("Remove", role: .destructive) { removing = row }
        }
    }

    private func grouped(_ code: String) -> String {
        stride(from: 0, to: code.count, by: 3).map { i in
            String(code.dropFirst(i).prefix(3))
        }.joined(separator: " ")
    }

    private func load() {
        let names = unlockedNames
        let filter = filter
        Task {
            var rows: [String: [CodeRow]] = [:]
            var corrupt: [String: Int] = [:]
            for name in names {
                var fields: [String: Any] = [:]
                if !filter.isEmpty { fields["filter"] = filter }
                guard let reply = try? await VaultModel.ask(name, "totp_list", fields) else { continue }
                let now = Date()
                rows[name] = (reply["records"] as? [[String: Any]] ?? []).compactMap { r in
                    guard let id = r["id"] as? String, let code = r["code"] as? String else { return nil }
                    return CodeRow(
                        domain: name, id: id, issuer: r["issuer"] as? String ?? "", account: r["account"] as? String ?? "",
                        code: code, expires: now.addingTimeInterval(Double(r["secondsLeft"] as? Int ?? 30)))
                }
                corrupt[name] = (reply["corrupt"] as? [Any])?.count ?? 0
            }
            self.rows = rows
            self.corrupt = corrupt
        }
    }
}

/// android-app §10.8 Add: scan, import a file, or enter a code.
struct AddCode: View {
    let domains: [String]
    let added: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var scanning = false
    @State private var importing = false
    @State private var issuer = ""
    @State private var account = ""
    @State private var secret = ""
    @State private var result: String?

    var body: some View {
        NavigationStack {
            Form {
                if domains.isEmpty {
                    Text("Unlock a vault first.")
                } else {
                    Section {
                        if Scanner.usable { Button("Scan a QR code") { scanning = true } }
                        Button("Import a file") { importing = true }
                    }
                    Section("Enter a code") {
                        TextField("Issuer", text: $issuer)
                        TextField("Account", text: $account).textInputAutocapitalization(.never)
                        SecretField("Secret or otpauth:// link", text: $secret)
                        Button("Add") {
                            let uri = secret.hasPrefix("otpauth://")
                            add(uri ? ["uri": secret] : ["secret": secret, "issuer": issuer, "account": account])
                        }
                        .disabled(secret.isEmpty)
                    }
                    if let result { Text(result) }
                }
            }
            .navigationTitle("Add a code")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $scanning) {
                Scanner { text in
                    scanning = false
                    add(["uri": text])
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .text]) { picked in
                guard case .success(let url) = picked else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                    result = "The file is not text."
                    return
                }
                importText(text)
            }
        }
    }

    /// android-app §10.8: a new record goes to the first domain, in config order.
    private func add(_ fields: [String: Any]) {
        guard let domain = domains.first else { return }
        Task {
            do {
                _ = try await VaultModel.ask(domain, "totp_add", fields)
                added()
                dismiss()
            } catch {
                result = error.localizedDescription
            }
        }
    }

    private func importText(_ text: String) {
        guard let domain = domains.first else { return }
        Task {
            do {
                let reply = try await VaultModel.ask(domain, "totp_import", ["text": text])
                let refused = reply["refused"] as? [[String: Any]] ?? []
                result = "Added \(reply["added"] as? Int ?? 0), already there \(reply["already"] as? Int ?? 0), refused \(refused.count)"
                    + refused.map { "\nline \($0["line"] as? Int ?? 0): \($0["reason"] as? String ?? "")" }.joined()
                added()
            } catch {
                result = error.localizedDescription
            }
        }
    }
}

struct RenameCode: View {
    let row: CodeRow
    let renamed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var issuer = ""
    @State private var account = ""
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Issuer", text: $issuer)
                TextField("Account", text: $account).textInputAutocapitalization(.never)
                if let failure { Text(failure).foregroundStyle(.red) }
            }
            .navigationTitle("Rename")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Rename") {
                        Task {
                            do {
                                _ = try await VaultModel.ask(
                                    row.domain, "totp_rename", ["id": row.id, "issuer": issuer, "account": account])
                                renamed()
                                dismiss()
                            } catch {
                                failure = error.localizedDescription
                            }
                        }
                    }
                }
            }
            .onAppear {
                issuer = row.issuer
                account = row.account
            }
        }
    }
}

/// android-app §10.8 Opened from elsewhere: never added without **Add**.
struct OpenedCode: View {
    let uri: URL
    @EnvironmentObject private var vault: VaultModel
    @Environment(\.dismiss) private var dismiss
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Text("Add \(label) to your vault?")
                if target == nil { Text("No vault on this iPhone is unlocked: unlock one in Vault first.").foregroundStyle(.secondary) }
                if let failure { Text(failure).foregroundStyle(.red) }
            }
            .navigationTitle("A one-time code")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard let target else { return }
                        Task {
                            do {
                                _ = try await VaultModel.ask(target, "totp_add", ["uri": uri.absoluteString])
                                dismiss()
                            } catch {
                                failure = error.localizedDescription
                            }
                        }
                    }
                    .disabled(target == nil)
                }
            }
        }
    }

    private var target: String? { vault.domains.first { $0.state == .unlocked }?.name }

    /// The label of `otpauth://totp/Issuer:account`.
    private var label: String {
        let path = uri.path.hasPrefix("/") ? String(uri.path.dropFirst()) : uri.path
        return path.replacingOccurrences(of: ":", with: " — ")
    }
}

// MARK: Passwords (passwords/android §8)

struct LoginRow: Identifiable {
    let domain: String
    let id: String
    let kind: String
    let title: String
    let detail: String
    let code: Bool
}

struct PasswordsList: View {
    @EnvironmentObject private var vault: VaultModel
    @State private var rows: [String: [LoginRow]] = [:]
    @State private var filter = ""
    @State private var removing: LoginRow?
    @State private var notice: String?

    var body: some View {
        List {
            ForEach(vault.domains) { domain in
                DomainSection(domain: domain) {
                    ForEach(rows[domain.name] ?? []) { row in login(row) }
                }
            }
        }
        .searchable(text: $filter)
        .onChange(of: filter) { _ in load() }
        .task(id: vault.domains) { load() }
        .confirmationDialog(
            "Remove \(removing?.title ?? "")?", isPresented: isPresent($removing), titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                guard let row = removing else { return }
                Task {
                    _ = try? await VaultModel.ask(row.domain, "passwords_remove", ["id": row.id])
                    VaultModel.refreshIdentities()
                    load()
                }
            }
        }
        .alert(notice ?? "", isPresented: isPresent($notice)) { Button("OK") {} }
        .privacySensitive()
    }

    @ViewBuilder private func login(_ row: LoginRow) -> some View {
        HStack {
            Image(systemName: row.kind == "passkey" ? "person.badge.key" : "key").foregroundStyle(.secondary)
            VStack(alignment: .leading) {
                Text(row.title)
                if !row.detail.isEmpty { Text(row.detail).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .contextMenu {
            if row.kind == "login" {
                Button("Copy username") { copy(row, "username", "the username") }
                Button("Copy password") { copy(row, "password", "the password") }
                if row.code { Button("Copy code") { copy(row, "code", "the code") } }
            }
            Button("Remove", role: .destructive) { removing = row }
        }
    }

    private func copy(_ row: LoginRow, _ key: String, _ what: String) {
        Task {
            do {
                let reply = try await VaultModel.ask(row.domain, "passwords_get", ["id": row.id])
                Copy.secret(reply[key] as? String ?? "")
                notice = "Copied \(what) of \(row.title)"
            } catch {
                notice = error.localizedDescription
            }
        }
    }

    private func load() {
        let names = vault.domains.filter { $0.state == .unlocked }.map(\.name)
        let filter = filter
        Task {
            var rows: [String: [LoginRow]] = [:]
            for name in names {
                var fields: [String: Any] = [:]
                if !filter.isEmpty { fields["filter"] = filter }
                guard let reply = try? await VaultModel.ask(name, "passwords_list", fields) else { continue }
                rows[name] = (reply["records"] as? [[String: Any]] ?? []).compactMap { r in
                    guard let id = r["id"] as? String, let kind = r["kind"] as? String else { return nil }
                    let passkey = kind == "passkey"
                    return LoginRow(
                        domain: name, id: id, kind: kind,
                        title: (passkey ? r["rpId"] : r["title"]) as? String ?? "",
                        detail: (passkey ? r["userName"] : r["username"]) as? String ?? "",
                        code: r["code"] as? Bool == true)
                }
            }
            self.rows = rows
        }
    }
}

/// security-model §10.6: on this iPhone only, never to another device.
enum Copy {
    static func secret(_ text: String) {
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: text]], options: [.localOnly: true])
    }
}
