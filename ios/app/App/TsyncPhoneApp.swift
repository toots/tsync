import FileProvider
import SwiftUI

@main
struct TsyncPhoneApp: App {
    @StateObject private var model = AppModel()

    init() {
        Core.start(bounded: false)
        BackgroundRefresh.register()
        if CommandLine.arguments.contains("-selftest") { Task.detached { await SelfTest.run() } }
    }

    var body: some Scene {
        WindowGroup { RootView().environmentObject(model) }
    }
}

/// ios-app.md §2: Setup until a config loads, then Settings.
struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var phase

    var body: some View {
        NavigationStack {
            if model.loadFailure != nil || !model.configured {
                SetupView(failure: model.loadFailure)
            } else {
                SettingsView()
            }
        }
        .onAppear { BackgroundRefresh.schedule() }
        .onChange(of: phase) { phase in
            if phase == .active {
                model.reload()
                BackgroundRefresh.schedule()
            }
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

    private let reconciler = Reconciler()
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
