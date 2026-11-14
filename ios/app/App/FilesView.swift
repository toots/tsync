import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// A folder of a domain, by its path from the domain's root.
struct Place: Hashable, Codable {
    let domain: String
    let path: [String]

    var name: String { path.last ?? domain }
    var shown: String { ([domain] + path).joined(separator: "/") }
    func child(_ name: String) -> Place { Place(domain: domain, path: path + [name]) }
    func url(in root: URL) -> URL {
        path.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
    }
}

/// file-browser.md §3: the domains, or the only domain's root, and the trail.
struct FilesView: View {
    @EnvironmentObject private var model: AppModel
    @SceneStorage("files.trail") private var stored = Data()
    @State private var trail: [Place] = []
    @State private var restored = false
    @State private var notice: String?

    var body: some View {
        NavigationStack(path: $trail) {
            Group {
                if model.entries.count == 1, let only = model.entries.first {
                    if model.turnedOff.contains(only.name) {
                        TurnedOff(domain: only.name).navigationTitle(only.name)
                    } else {
                        FolderView(place: Place(domain: only.name, path: []), trail: $trail, notice: $notice)
                    }
                } else {
                    DomainsView()
                }
            }
            .navigationDestination(for: Place.self) { FolderView(place: $0, trail: $trail, notice: $notice) }
        }
        .alert(notice ?? "", isPresented: isPresent($notice)) { Button("OK") {} }
        .onAppear {
            guard !restored else { return }
            restored = true
            let names = Set(model.entries.map(\.name))
            trail = ((try? JSONDecoder().decode([Place].self, from: stored)) ?? []).filter { names.contains($0.domain) }
        }
        .onChange(of: trail) { stored = (try? JSONEncoder().encode($0)) ?? Data() }
    }
}

struct DomainsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List(model.entries) { entry in
            if model.turnedOff.contains(entry.name) {
                TurnedOff(domain: entry.name)
            } else {
                NavigationLink(value: Place(domain: entry.name, path: [])) {
                    Label(entry.name, systemImage: "folder")
                }
            }
        }
        .navigationTitle("Files")
    }
}

struct TurnedOff: View {
    let domain: String

    var body: some View {
        VStack(alignment: .leading) {
            Label(domain, systemImage: "folder")
            Text("Turned off in Files: Browse, then More, then Edit").font(.footnote).foregroundStyle(.orange)
        }
    }
}

/// What a folder screen is for: browsing, or choosing where an item goes.
enum FolderMode {
    case browse
    /// [done] with the destination, or nil when cancelled.
    case pick(moving: FileStore.Item, from: Place, done: (Place?) -> Void)
}

@MainActor
final class FolderModel: ObservableObject {
    enum Listing { case loading, listed([FileStore.Item]), unreachable(String), failed(String) }

    @Published private(set) var listing = Listing.loading
    @Published private(set) var writable = true
    @Published var message: String?
    let place: Place
    private(set) var url: URL?
    private var watcher: FolderWatcher?
    private var changes: [CheckedContinuation<Void, Never>] = []

    init(place: Place) { self.place = place }

    func start() async {
        guard url == nil else {
            await load(quietly: true)
            return
        }
        do {
            let root = try await FileStore.root(place.domain)
            let url = place.url(in: root)
            self.url = url
            writable = await Task.detached { FileStore.isWritable(root) }.value
            watcher = FolderWatcher(url) { [weak self] in Task { @MainActor in self?.changed() } }
        } catch {
            listing = .failed(error.localizedDescription)
            return
        }
        await load(quietly: false)
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        url = nil
    }

    private var isListed: Bool { if case .listed = listing { return true } else { return false } }

    /// A quiet load keeps the list on screen, and on a failure keeps it and
    /// answers the failure.
    @discardableResult
    func load(quietly: Bool) async -> Error? {
        guard let url else { return nil }
        if !quietly && !isListed { listing = .loading }
        do {
            listing = .listed(try await Task.detached { try await FileStore.list(url) }.value)
            return nil
        } catch {
            if !(quietly && isListed) {
                listing = FileStore.isUnreachable(error)
                    ? .unreachable("Cannot reach the server") : .failed(error.localizedDescription)
            }
            return error
        }
    }

    /// file-browser-differences.md §2: a refresh pass, then the folder read
    /// again once the system reports it changed, or after refresh_patience.
    func refresh() async {
        FileStore.signal(place.domain)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.nextChange() }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(FileStore.refreshPatience * 1e9)) }
            await group.next()
            group.cancelAll()
        }
        resumeWaiters()
        if let error = await load(quietly: true) {
            message = FileStore.isUnreachable(error) ? "Cannot reach the server" : error.localizedDescription
        }
    }

    private func nextChange() async {
        await withCheckedContinuation { changes.append($0) }
    }

    private func resumeWaiters() {
        let waiting = changes
        changes = []
        waiting.forEach { $0.resume() }
    }

    private func changed() {
        resumeWaiters()
        Task { await load(quietly: true) }
    }

    /// Runs off the main thread; the confirmation or the failure is shown.
    func run(_ confirmation: String, _ body: @escaping @Sendable () async throws -> Void) async -> Bool {
        do {
            try await Task.detached { try await body() }.value
            message = confirmation
            await load(quietly: true)
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }
}

/// file-browser.md §3 and §5: one folder, browsed or picked.
struct FolderView: View {
    let place: Place
    @Binding var trail: [Place]
    @Binding var notice: String?
    var mode = FolderMode.browse
    @StateObject private var folder: FolderModel
    @State private var naming: NamePrompt.Purpose?
    @State private var uploading = false
    @State private var progress: String?
    @State private var acting: FileStore.Item?
    @State private var deleting: FileStore.Item?
    @State private var details: FileStore.Item?
    @State private var moving: FileStore.Item?
    @State private var preview: URL?

    init(place: Place, trail: Binding<[Place]>, notice: Binding<String?>, mode: FolderMode = .browse) {
        self.place = place
        _trail = trail
        _notice = notice
        self.mode = mode
        _folder = StateObject(wrappedValue: FolderModel(place: place))
    }

    private var picking: Bool { if case .pick = mode { return true } else { return false } }

    var body: some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .task { await folder.start() }
            .onDisappear { folder.stop() }
            .refreshable { await folder.refresh() }
            .sheet(item: $naming) { purpose in NamePrompt(purpose: purpose, folder: folder) }
            .sheet(item: $details) { DetailsView(item: $0) }
            .sheet(item: $moving) { item in
                MovePicker(item: item, from: place) { destination in
                    moving = nil
                    if let destination {
                        trail = trailTo(destination)
                        notice = "Moved \(item.name) to \(destination.shown)"
                    }
                }
            }
            .confirmationDialog(
                deleting.map { "Delete \($0.name)?" } ?? "", isPresented: isPresent($deleting), titleVisibility: .visible,
                presenting: deleting
            ) { item in
                Button("Delete", role: .destructive) {
                    Task { _ = await folder.run("Deleted \(item.name)") { try FileStore.delete(item.url) } }
                }
            } message: { item in
                Text(item.isFolder ? "Everything in \(item.name) is deleted too." : "")
            }
            .fileImporter(isPresented: $uploading, allowedContentTypes: [.item], allowsMultipleSelection: true) {
                if case .success(let files) = $0 { upload(files) }
            }
            .quickLookPreview($preview)
            .alert(folder.message ?? "", isPresented: isPresent($folder.message)) { Button("OK") {} }
    }

    private var title: String {
        if case .pick(let item, _, _) = mode { return "Move \(item.name) to \(place.shown)" }
        return place.name
    }

    @ViewBuilder private var content: some View {
        switch folder.listing {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unreachable(let reason), .failed(let reason):
            VStack(spacing: 12) {
                Text(reason).multilineTextAlignment(.center)
                Button("Retry") { Task { await folder.load(quietly: false) } }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .listed(let items):
            let shown = items.filter { if case .pick(let moving, _, _) = mode { return $0.url != moving.url } else { return true } }
            if shown.isEmpty {
                Text("This folder is empty").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !folder.writable && !picking {
                        Text("\(place.domain) is read-only").font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(shown) { row($0) }
                }
            }
        }
    }

    @ViewBuilder private func row(_ item: FileStore.Item) -> some View {
        if item.isFolder {
            NavigationLink(value: place.child(item.name)) { ItemRow(item: item) }
                .contextMenu { if !picking { actions(item) } }
        } else if picking {
            ItemRow(item: item).foregroundStyle(.secondary)
        } else {
            Button { open(item) } label: { ItemRow(item: item) }
                .foregroundStyle(.primary)
                .contextMenu { actions(item) }
        }
    }

    /// file-browser.md §4, as differences §2 offers them.
    @ViewBuilder private func actions(_ item: FileStore.Item) -> some View {
        if !item.isFolder { Button("Open") { open(item) } }
        if item.state != .onlineOnly {
            Button("Remove download") {
                Task {
                    _ = await folder.run("Removed the download of \(item.name)") {
                        try await FileStore.removeDownload(item.url, domain: place.domain)
                    }
                }
            }
        }
        if folder.writable {
            Button("Rename") { naming = .rename(item) }
            Button("Move") { moving = item }
            Button("Delete", role: .destructive) { deleting = item }
        }
        Button("Details") { details = item }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if case .pick = mode {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { cancelPick() } }
        }
        if folder.writable {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("New folder") { naming = .newFolder }
                    if !picking { Button("Upload files") { uploading = true } }
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
        }
    }

    @ViewBuilder private var bottomBar: some View {
        if let progress {
            Text(progress).font(.footnote).padding(8).frame(maxWidth: .infinity).background(.bar)
        } else if case .pick(let item, let from, let done) = mode {
            Button("Move here") {
                Task {
                    guard let url = folder.url else { return }
                    do {
                        try await Task.detached { try FileStore.move(item.url, to: url.appendingPathComponent(item.name)) }.value
                        done(place)
                    } catch {
                        folder.message = FileStore.isTaken(error)
                            ? "\(item.name) is already taken in \(place.shown)" : error.localizedDescription
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(place == from || folder.url == nil)
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }

    private func cancelPick() {
        if case .pick(_, _, let done) = mode { done(nil) }
    }

    private func open(_ item: FileStore.Item) {
        Task {
            progress = "Opening \(item.name)"
            defer { progress = nil }
            do {
                try await Task.detached { try FileStore.download(item.url) }.value
                preview = item.url
            } catch {
                folder.message = "Cannot open \(item.name): \(error.localizedDescription)"
            }
        }
    }

    private func upload(_ files: [URL]) {
        guard let url = folder.url else { return }
        Task {
            var failed: [String] = []
            for (index, file) in files.enumerated() {
                progress = "Uploading \(index + 1) of \(files.count): \(file.lastPathComponent)"
                do {
                    _ = try await Task.detached { try FileStore.upload(file, into: url) }.value
                } catch {
                    failed.append("\(file.lastPathComponent): \(error.localizedDescription)")
                }
            }
            progress = nil
            await folder.load(quietly: true)
            folder.message = failed.isEmpty
                ? (files.count == 1 ? "Uploaded \(files[0].lastPathComponent)" : "Uploaded \(files.count) files")
                : "Not uploaded:\n" + failed.joined(separator: "\n")
        }
    }

    /// The trail that shows a folder: the domain's root is on it only when
    /// Files starts on the list of domains.
    private func trailTo(_ destination: Place) -> [Place] {
        stride(from: model.entries.count > 1 ? 0 : 1, through: destination.path.count, by: 1).map {
            Place(domain: destination.domain, path: Array(destination.path.prefix($0)))
        }
    }

    @EnvironmentObject private var model: AppModel
}

func isPresent<T>(_ binding: Binding<T?>) -> Binding<Bool> {
    Binding(get: { binding.wrappedValue != nil }, set: { if !$0 { binding.wrappedValue = nil } })
}

struct ItemRow: View {
    let item: FileStore.Item

    var body: some View {
        HStack {
            Image(systemName: icon).frame(width: 28).foregroundStyle(.tint)
            VStack(alignment: .leading) {
                Text(item.name).lineLimit(1)
                if let line = secondLine {
                    Text(line).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer()
            switch item.state {
            case .waitingToUpload:
                Image(systemName: "arrow.up.circle").accessibilityLabel("Waiting to upload")
            case .onlineOnly:
                Image(systemName: "icloud").accessibilityLabel("On the server only")
            case .downloaded:
                EmptyView()
            }
        }
    }

    private var secondLine: String? {
        guard !item.isFolder else { return nil }
        let size = item.size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
        let date = item.modified?.formatted(date: .abbreviated, time: .shortened)
        return [size, date].compactMap { $0 }.joined(separator: ", ")
    }

    private var icon: String {
        if item.isFolder { return "folder" }
        guard let type = item.type else { return "doc" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) { return "film" }
        if type.conforms(to: .audio) { return "music.note" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .text) { return "doc.text" }
        return "doc"
    }
}

/// New folder and Rename: a taken name is shown on the field.
struct NamePrompt: View {
    enum Purpose: Identifiable {
        case newFolder
        case rename(FileStore.Item)
        var id: String {
            if case .rename(let item) = self { return item.url.path }
            return "new folder"
        }
    }

    let purpose: Purpose
    @ObservedObject var folder: FolderModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var problem: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled()
                if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
            }
            .navigationTitle(isRename ? "Rename" : "New folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isRename ? "Rename" : "Create") { Task { await submit() } }
                        .disabled(busy || name.isEmpty || name.contains("/"))
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear { if case .rename(let item) = purpose { name = item.name } }
    }

    private var isRename: Bool { if case .rename = purpose { return true } else { return false } }

    private func submit() async {
        guard let url = folder.url else { return }
        busy = true
        defer { busy = false }
        let name = name
        let target = url.appendingPathComponent(name)
        do {
            switch purpose {
            case .newFolder:
                try await Task.detached { try FileStore.newFolder(name, in: url) }.value
            case .rename(let item):
                if item.name == name { return dismiss() }
                try await Task.detached { try FileStore.move(item.url, to: target) }.value
            }
            await folder.load(quietly: true)
            dismiss()
        } catch {
            problem = FileStore.isTaken(error) ? "\(name) is already taken here" : error.localizedDescription
        }
    }
}

/// file-browser.md §5 for a Move: the item's domain only, from its root.
struct MovePicker: View {
    let item: FileStore.Item
    let from: Place
    let done: (Place?) -> Void
    @State private var trail: [Place] = []
    @State private var notice: String?

    var body: some View {
        let root = Place(domain: from.domain, path: [])
        NavigationStack(path: $trail) {
            FolderView(place: root, trail: $trail, notice: $notice, mode: .pick(moving: item, from: from, done: done))
                .navigationDestination(for: Place.self) {
                    FolderView(place: $0, trail: $trail, notice: $notice, mode: .pick(moving: item, from: from, done: done))
                }
        }
        .onAppear {
            trail = from.path.indices.map { Place(domain: from.domain, path: Array(from.path.prefix($0 + 1))) }
        }
    }
}

struct DetailsView: View {
    let item: FileStore.Item
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("Name", value: item.name)
                LabeledContent("Kind", value: item.isFolder ? "Folder" : item.type?.localizedDescription ?? "File")
                if let size = item.size {
                    LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                }
                if let modified = item.modified {
                    LabeledContent("Modified", value: modified.formatted(date: .long, time: .shortened))
                }
                if !item.isFolder {
                    LabeledContent("Bytes", value: item.state == .onlineOnly ? "On the server only" : "On this iPhone")
                }
                LabeledContent("Uploaded", value: item.state == .waitingToUpload ? "Not yet" : "Yes")
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
