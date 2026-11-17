import FileProvider
import SwiftUI

@main
struct TsyncPhoneApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var vault = VaultModel()

    init() {
        Core.start(bounded: false)
        BackgroundRefresh.register()
        if Bundle.main.development, CommandLine.arguments.contains("-selftest") { Task.detached { await SelfTest.run() } }
        if Bundle.main.development, CommandLine.arguments.contains("-browsertest") { Task.detached { await BrowserTest.run() } }
    }

    var body: some Scene {
        WindowGroup { RootView().environmentObject(model).environmentObject(vault) }
    }
}

/// ios-app.md §2: Setup until a config loads, then Files, Vault while a domain
/// uses an extension, Activity, and Settings.
struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var vault: VaultModel
    @Environment(\.scenePhase) private var phase
    @SceneStorage("destination") private var destination = "files"
    @State private var opened: OpenedLink?

    var body: some View {
        Group {
            if model.loadFailure != nil || !model.configured {
                NavigationStack { SetupView(failure: model.loadFailure) }
            } else {
                TabView(selection: $destination) {
                    FilesView()
                        .tabItem { Label("Files", systemImage: "folder") }
                        .tag("files")
                    if !vault.domains.isEmpty {
                        VaultView()
                            .tabItem { Label("Vault", systemImage: "lock.shield") }
                            .tag("vault")
                    }
                    ActivityView()
                        .tabItem { Label("Activity", systemImage: "arrow.up.arrow.down") }
                        .tag("activity")
                    NavigationStack { SettingsView() }
                        .tabItem { Label("Settings", systemImage: "gearshape") }
                        .tag("settings")
                }
            }
        }
        // ios-app.md §6: iOS cannot refuse a screenshot, so secrets stay out of
        // the app switcher.
        .overlay { if phase != .active { Color(uiColor: .systemBackground).ignoresSafeArea() } }
        .onAppear {
            BackgroundRefresh.schedule()
            vault.refresh()
        }
        .onChange(of: phase) { phase in
            if phase == .active {
                model.reload()
                vault.refresh()
                BackgroundRefresh.schedule()
            }
        }
        .onOpenURL { url in if url.scheme == "otpauth" { opened = OpenedLink(url: url) } }
        .sheet(item: $opened) { OpenedCode(uri: $0.url) }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
            vault.screenLocked()
        }
    }
}

/// What the screens show of the config and of the framework's domains, and
/// the registration passes (ios-app.md §3).
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var configured = false
    @Published private(set) var loadFailure: String?
    @Published private(set) var entries: [Configs.Entry] = []
    @Published private(set) var turnedOff: Set<String> = []
    @Published private(set) var passFailures: [String] = []
    @Published private(set) var refreshStatus = UIBackgroundRefreshStatus.available

    private let reconciler = Reconciler.shared
    private var observer: NSObjectProtocol?

    init() {
        reconciler.onPass = { [weak self] domains, report in
            // ios.md §5.1: bringing the app forward refreshes what Files shows.
            for domain in domains {
                NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet) { _ in }
            }
            let off = Set(domains.filter { !$0.userEnabled }.map(\.displayName))
            let failures = report.failures + report.collisions.map { "\($0): its identifier collides" }
            Task { @MainActor in
                self?.turnedOff = off
                self?.passFailures = failures
            }
        }
        observer = NotificationCenter.default.addObserver(
            forName: .fileProviderDomainDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.readStates() }
        }
        reload()
    }

    /// After launch, on every return to the foreground and every config change.
    func reload() {
        configured = Configs.exists
        loadFailure = configured ? Configs.loadFailure() : nil
        entries = Configs.entries()
        refreshStatus = UIApplication.shared.backgroundRefreshStatus
        reconciler.request()
    }

    private func readStates() {
        NSFileProviderManager.getDomainsWithCompletionHandler { domains, _ in
            let off = Set(domains.filter { !$0.userEnabled }.map(\.displayName))
            Task { @MainActor in self.turnedOff = off }
        }
    }

    /// ios-app.md §5: out of the framework, then out of the config; the reason
    /// when either refuses.
    func remove(_ entry: Configs.Entry) async -> String? {
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(domainIdentifier(entry.name)),
            displayName: entry.name)
        do {
            try await NSFileProviderManager.remove(domain)
        } catch {
            // providerDomainNotFound, named only from iOS 17.1: nothing to remove.
            let error = error as NSError
            if !(error.domain == NSFileProviderErrorDomain && error.code == -2013) {
                return error.localizedDescription
            }
        }
        let refusal = Configs.remove(entry.name)
        reload()
        return refusal
    }
}

/// A link handed to the app, as a sheet's item.
struct OpenedLink: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
