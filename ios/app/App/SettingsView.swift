import SwiftUI

/// ios-app.md §5.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var removing: Configs.Entry?
    @State private var message = ""
    @State private var adding = false

    var body: some View {
        Form {
            Section("Domains") {
                ForEach(model.entries) { entry in
                    VStack(alignment: .leading) {
                        Text(entry.name)
                        Text(entry.server).font(.footnote).foregroundStyle(.secondary)
                        if model.turnedOff.contains(entry.name) {
                            Text("Turned off in Files: Browse, then More, then Edit")
                                .font(.footnote).foregroundStyle(.orange)
                        }
                    }
                    .swipeActions {
                        Button("Remove", role: .destructive) { removing = entry }
                    }
                    .contextMenu {
                        Button("Remove", role: .destructive) { removing = entry }
                    }
                }
                switch model.refreshStatus {
                case .denied:
                    Text("Background refresh is off for tsync: Files shows changes from other devices when you open tsync. Turn it on in Settings, General, Background App Refresh.")
                        .font(.footnote).foregroundStyle(.orange)
                case .restricted:
                    Text("Background refresh is not available on this iPhone: Files shows changes from other devices when you open tsync.")
                        .font(.footnote).foregroundStyle(.orange)
                default:
                    EmptyView()
                }
                Button("Add a domain") { adding = true }
                ForEach(model.passFailures, id: \.self) { Text($0).foregroundStyle(.red) }
                if !message.isEmpty { Text(message).foregroundStyle(.red) }
            }
            Section("About") {
                LabeledContent("Version", value: Bundle.main.version)
                LabeledContent("Commit", value: Bundle.main.commit)
            }
            Section {
                NavigationLink("Diagnostics") { DiagnosticsView() }
            }
        }
        .navigationTitle("tsync")
        .sheet(isPresented: $adding) {
            NavigationStack { SetupView(dismissible: true) }
        }
        .confirmationDialog(
            "Remove \(removing?.name ?? "")?", isPresented: removingShown, titleVisibility: .visible,
            presenting: removing
        ) { entry in
            Button("Remove \(entry.name)", role: .destructive) {
                Task { message = await model.remove(entry) ?? "" }
            }
        } message: { entry in
            Text("\(entry.name) leaves this iPhone and the Files app. Changes made in Files and not yet uploaded are lost.")
        }
    }

    private var removingShown: Binding<Bool> {
        Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
    }
}

extension Bundle {
    var version: String { object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }

    /// Set by the build from `TSYNC_COMMIT` (run-device.sh).
    var commit: String {
        let value = object(forInfoDictionaryKey: "TsyncCommit") as? String ?? ""
        return value.isEmpty ? "unknown" : value
    }
}
