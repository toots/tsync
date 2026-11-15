import FileProvider
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// ios-app.md §7: Save to tsync. It writes into the domain's folder through
/// the file system; the system hands each file to the File Provider extension.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
            .filter { $0.hasItemConformingToTypeIdentifier(UTType.data.identifier) }
        let save = SaveView(providers: providers) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
        let host = UIHostingController(rootView: save)
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }
}

/// The folder last saved to, per domain, by its path below the root.
enum SaveFolders {
    private static let key = "saveFolders"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: Tsync.appGroup) }

    static func path(_ domain: String) -> [String] {
        (defaults?.dictionary(forKey: key)?[domain] as? [String]) ?? []
    }

    static func remember(_ path: [String], for domain: String) {
        var all = defaults?.dictionary(forKey: key) ?? [:]
        all[domain] = path
        defaults?.set(all, forKey: key)
    }
}

struct SaveView: View {
    let providers: [NSItemProvider]
    let done: () -> Void

    @State private var domains: [String] = []
    @State private var domain = ""
    @State private var root: URL?
    @State private var path: [String] = []
    @State private var name = ""
    @State private var failures: [String] = []
    @State private var problem: String?
    @State private var saving = false
    @State private var saved = false
    @State private var choosing = false
    @State private var unopened: String?

    var body: some View {
        NavigationStack {
            Form {
                if let problem {
                    Text(problem).foregroundStyle(.secondary)
                } else if saved {
                    Section("Not saved") { ForEach(failures, id: \.self) { Text($0) } }
                } else {
                    if domains.count > 1 {
                        Picker("Domain", selection: $domain) { ForEach(domains, id: \.self) { Text($0) } }
                    }
                    Button { choosing = true } label: {
                        LabeledContent("Folder", value: path.last ?? domain)
                    }
                    .disabled(root == nil)
                    if let unopened { Text(unopened).foregroundStyle(.secondary) }
                    if providers.count == 1 {
                        TextField("Name", text: $name).autocorrectionDisabled()
                    } else {
                        Text("\(providers.count) items")
                    }
                }
            }
            .navigationTitle("Save to tsync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if saved || problem != nil {
                    ToolbarItem(placement: .confirmationAction) { Button("Done", action: done) }
                } else {
                    // ios-app §7: the request completes only once every write has returned.
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: done).disabled(saving) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(saving ? "Saving…" : "Save") { Task { await save() } }
                            .disabled(saving || root == nil || (providers.count == 1 && (name.isEmpty || name.contains("/"))))
                    }
                }
            }
            .navigationDestination(isPresented: $choosing) {
                if let root { FolderChooser(root: root, path: $path, choosing: $choosing) }
            }
            .task { await start() }
            .onChange(of: domain) { _ in Task { await open() } }
        }
    }

    private func start() async {
        guard !providers.isEmpty else { return problem = "Nothing here can be saved to tsync." }
        name = providers.first?.suggestedName ?? ""
        let configured = Tsync.domainNames()
        let enabled = Set(((try? await NSFileProviderManager.domains()) ?? []).filter(\.userEnabled).map(\.displayName))
        domains = configured.filter(enabled.contains)
        if domains.isEmpty {
            problem = configured.isEmpty
                ? "No domain is set up: open tsync first."
                : "tsync is turned off in Files: in Files, Browse, then More, then Edit."
            return
        }
        domain = domains[0]
    }

    /// The domain's root, and its remembered folder when it still exists.
    private func open() async {
        let asked = domain
        root = nil
        unopened = nil
        let found = try? await FileStore.root(asked)
        guard asked == domain else { return }
        guard let found else { return unopened = "\(asked) cannot be opened." }
        let remembered = SaveFolders.path(asked)
        var isFolder: ObjCBool = false
        let folder = remembered.reduce(found) { $0.appendingPathComponent($1, isDirectory: true) }
        path = FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder) && isFolder.boolValue
            ? remembered : []
        root = found
    }

    private func save() async {
        guard let root else { return }
        saving = true
        let folder = path.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
        let single = providers.count == 1 ? name : nil
        var failed: [String] = []
        for provider in providers {
            if let failure = await Self.save(provider, named: single, into: folder) { failed.append(failure) }
        }
        SaveFolders.remember(path, for: domain)
        saving = false
        // The writes have returned: the system holds the bytes.
        if failed.isEmpty { return done() }
        failures = failed
        saved = true
    }

    /// Nil once written, else the item's name and the reason.
    private static func save(_ provider: NSItemProvider, named: String?, into folder: URL) async -> String? {
        let label = named ?? provider.suggestedName ?? "an item"
        do {
            let staged = try await staged(provider, named: named)
            defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
            _ = try await Task.detached { try FileStore.upload(staged, into: folder) }.value
            return nil
        } catch {
            return "\(label): \(error.localizedDescription)"
        }
    }

    /// The provider's file, copied out of its loader under the name to save it as.
    private static func staged(_ provider: NSItemProvider, named: String?) async throws -> URL {
        let named = named ?? provider.suggestedName
        return try await withCheckedThrowingContinuation { done in
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.data.identifier) { url, error in
                guard let url else {
                    return done.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                }
                do {
                    let directory = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let staged = directory.appendingPathComponent(Self.name(named, url))
                    try FileManager.default.copyItem(at: url, to: staged)
                    done.resume(returning: staged)
                } catch {
                    done.resume(throwing: error)
                }
            }
        }
    }

    /// The typed name, else the sharing app's, keeping the loaded file's extension.
    private static func name(_ named: String?, _ loaded: URL) -> String {
        let base = named ?? loaded.deletingPathExtension().lastPathComponent
        let ext = loaded.pathExtension
        return ext.isEmpty || base.lowercased().hasSuffix("." + ext.lowercased()) ? base : base + "." + ext
    }
}

/// Folders from the root down, with New folder.
struct FolderChooser: View {
    let root: URL
    @Binding var path: [String]
    @Binding var choosing: Bool
    @State private var shown: [String] = []
    @State private var folders: [String] = []
    @State private var problem: String?
    @State private var naming = false
    @State private var newName = ""

    var body: some View {
        List {
            if !shown.isEmpty {
                Button("Up") { shown.removeLast() }
            }
            if let problem { Text(problem).foregroundStyle(.secondary) }
            ForEach(folders, id: \.self) { folder in
                Button { shown.append(folder) } label: { Label(folder, systemImage: "folder") }
            }
        }
        .navigationTitle(shown.last ?? "Choose folder")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Use") {
                    path = shown
                    choosing = false
                }
            }
            ToolbarItem(placement: .bottomBar) { Button("New folder") { naming = true } }
        }
        .alert("New folder", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Create") { create() }
            Button("Cancel", role: .cancel) {}
        }
        .task(id: shown) { await load() }
        .onAppear { shown = path }
    }

    private var folder: URL { shown.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) } }

    private func load() async {
        do {
            let items = try await FileStore.list(folder)
            guard !Task.isCancelled else { return }
            folders = items.filter(\.isFolder).map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            problem = nil
        } catch {
            guard !Task.isCancelled else { return }
            folders = []
            problem = error.localizedDescription
        }
    }

    private func create() {
        let name = newName
        newName = ""
        guard !name.isEmpty else { return }
        let parent = folder
        Task {
            do {
                try await Task.detached { try FileStore.newFolder(name, in: parent) }.value
                shown.append(name)
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}
