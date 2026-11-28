import SwiftUI
import UIKit

/// activity.md: the picked domain's `status` and `stats`, parsed and shown
/// as a screen, asked every `statusPoll` while it is visible.
struct ActivityView: View {
    @EnvironmentObject private var model: AppModel
    @SceneStorage("activity-domain") private var picked = ""
    @State private var reports: [String: ActivityReport] = [:]
    private static let statusPoll: UInt64 = 2_000_000_000

    var body: some View {
        NavigationStack {
            List {
                if model.entries.count > 1 {
                    Picker("Domain", selection: Binding { shown ?? "" } set: { picked = $0 }) {
                        ForEach(model.entries) { Text($0.name).tag($0.name) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                if let domain = shown {
                    if model.turnedOff.contains(domain) {
                        Section {
                            Label("Turned off in Files: Browse, then More, then Edit", systemImage: "eye.slash")
                                .foregroundStyle(.orange)
                        }
                    } else {
                        DomainActivity(domain: domain, report: reports[domain], owner: FileStore.owner) {
                            await ask(domain)
                        }
                            .id(domain)
                    }
                    WarningsSection(lines: reports[domain]?.warnings ?? [])
                }
                CameraBackupRow()
            }
            .navigationTitle("Activity")
            .task(id: shown) { await poll() }
        }
    }

    /// activity.md §2: a pick no longer listed falls back to the first.
    private var shown: String? {
        model.entries.first { $0.name == picked }?.name ?? model.entries.first?.name
    }

    /// `.task` ends when the screen goes or the pick changes, which ends the polling.
    private func poll() async {
        guard let domain = shown, !model.turnedOff.contains(domain) else { return }
        while !Task.isCancelled {
            await ask(domain)
            try? await Task.sleep(nanoseconds: Self.statusPoll)
        }
    }

    private func ask(_ domain: String) async {
        reports[domain] = await ActivityReport.ask(domain, previous: reports[domain], owner: FileStore.owner)
    }
}

/// ios-app.md §2.1: camera backup's status line, below the domains.
struct CameraBackupRow: View {
    @ObservedObject private var backup = CameraBackup.shared

    var body: some View {
        Section("Camera backup") {
            Text(backup.status).font(.footnote)
            if backup.enabled && !backup.bySystem {
                Button(backup.running ? "Backing up…" : "Back up now") { backup.request(now: true) }
                    .disabled(backup.running)
            }
        }
        .onAppear { backup.refreshStatus() }
    }
}
