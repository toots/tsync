import SwiftUI

/// ios-app.md §5.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var removing: Configs.Entry?
    @State private var message = ""
    @State private var adding = false
    @State private var footprint = ""

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
                Button("Add a domain") { adding = true }
                ForEach(model.passFailures, id: \.self) { Text($0).foregroundStyle(.red) }
                if !message.isEmpty { Text(message).foregroundStyle(.red) }
            }
            Section("About") {
                LabeledContent("Version", value: Bundle.main.version)
                LabeledContent("Commit", value: Bundle.main.commit)
            }
            Section("Diagnostics") {
                Button("Add a local test domain") {
                    message = Configs.add([Configs.localTest()]) ?? ""
                    model.reload()
                }
                if let server = Configs.testServer() {
                    Button("Add the test server domain") {
                        message = Configs.add([server]) ?? ""
                        model.reload()
                    }
                }
                Button("Run self-test") { Task.detached { await SelfTest.run() } }
                Button("Refresh the memory log") { readFootprint() }
                Button("Clear the memory log", role: .destructive) {
                    try? FileManager.default.removeItem(at: Footprint.log)
                    readFootprint()
                }
                Text(footprint).font(.system(.caption2, design: .monospaced))
            }
        }
        .navigationTitle("tsync")
        .onAppear { readFootprint() }
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

    private func readFootprint() {
        SelfTest.copyLogsToDocuments()
        let text = (try? String(contentsOf: Footprint.log, encoding: .utf8)) ?? "no record yet"
        footprint = text.split(separator: "\n").suffix(60).joined(separator: "\n")
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
