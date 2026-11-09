import BackgroundTasks
import FileProvider
import UIKit

/// ios.md §5.2: a run only signals; the extension's refresh pass follows.
enum BackgroundRefresh {
    static let identifier = (Bundle.main.bundleIdentifier ?? "") + ".refresh"
    static let interval: TimeInterval = 15 * 60

    /// Submitting aborts the app when the user has turned refresh off.
    @MainActor static func schedule() {
        guard UIApplication.shared.backgroundRefreshStatus == .available else { return }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Footprint.append("app: background refresh not scheduled: \(error.localizedDescription)")
        }
    }

    static func run() async {
        Footprint.append("app: background refresh")
        let domains = await withCheckedContinuation { done in
            NSFileProviderManager.getDomainsWithCompletionHandler { domains, _ in done.resume(returning: domains) }
        }
        for domain in domains {
            try? await NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet)
        }
        await schedule()
    }
}
