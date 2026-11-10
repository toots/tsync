import BackgroundTasks
import FileProvider
import UIKit

/// ios.md §5.2: a run only signals; the extension's refresh pass follows.
enum BackgroundRefresh {
    static let identifier = (Bundle.main.bundleIdentifier ?? "") + ".refresh"
    static let interval: TimeInterval = 15 * 60

    /// Once, as the app starts: SwiftUI's `.backgroundTask` registers again
    /// when it rebuilds the scene, and a second registration aborts the app.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            let run = Task { await BackgroundRefresh.run() }
            task.expirationHandler = { run.cancel() }
            Task {
                await run.value
                task.setTaskCompleted(success: true)
            }
        }
    }

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
