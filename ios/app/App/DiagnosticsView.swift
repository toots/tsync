import SwiftUI

/// ios-app.md §5 Diagnostics.
struct DiagnosticsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var message = ""
    @State private var coreLog = ""
    @State private var footprint = ""
    @State private var shared: [URL] = []

    var body: some View {
        Form {
            Section {
                Button("Refresh") { readLogs() }
                if !shared.isEmpty { ShareLink("Share", items: shared) }
                Button("Clear", role: .destructive) {
                    for log in [Core.log, Core.oldLog, Footprint.log, Footprint.oldLog] {
                        try? FileManager.default.removeItem(at: log)
                    }
                    readLogs()
                }
            }
            Section("tsync log") { Text(coreLog).font(.system(.caption2, design: .monospaced)) }
            Section("Memory log") { Text(footprint).font(.system(.caption2, design: .monospaced)) }
            if Bundle.main.development {
                Section("Development") {
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
                    Button("Run browser test") { Task.detached { await BrowserTest.run() } }
                    Button("Walk every domain") { Task.detached { await SelfTest.walk() } }
                    if !message.isEmpty { Text(message).foregroundStyle(.red) }
                }
            }
        }
        .navigationTitle("Diagnostics")
        .onAppear { readLogs() }
    }

    private func readLogs() {
        shared = SelfTest.copyLogsToDocuments()
        coreLog = Self.tail(Core.log)
        footprint = Self.tail(Footprint.log)
    }

    private static func tail(_ log: URL) -> String {
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? "no record yet"
        return text.split(separator: "\n").suffix(60).joined(separator: "\n")
    }
}

extension Bundle {
    /// Set by run-device.sh; a release build has none (check-release.sh).
    var development: Bool { object(forInfoDictionaryKey: "TsyncDevelopment") as? String == "YES" }
}
