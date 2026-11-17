import SwiftUI

/// ios-app.md §5 Diagnostics.
struct DiagnosticsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var message = ""
    @State private var footprint = ""
    @State private var shared: [URL] = []

    var body: some View {
        Form {
            Section("Memory log") {
                Button("Refresh") { readFootprint() }
                if !shared.isEmpty { ShareLink("Share", items: shared) }
                Button("Clear", role: .destructive) {
                    try? FileManager.default.removeItem(at: Footprint.log)
                    readFootprint()
                }
                Text(footprint).font(.system(.caption2, design: .monospaced))
            }
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
                    Button("Walk every domain") { Task.detached { await SelfTest.walk() } }
                    if !message.isEmpty { Text(message).foregroundStyle(.red) }
                }
            }
        }
        .navigationTitle("Diagnostics")
        .onAppear { readFootprint() }
    }

    private func readFootprint() {
        shared = SelfTest.copyLogsToDocuments()
        let text = (try? String(contentsOf: Footprint.log, encoding: .utf8)) ?? "no record yet"
        footprint = text.split(separator: "\n").suffix(60).joined(separator: "\n")
    }
}

extension Bundle {
    /// Set by run-device.sh; a release build has none (check-release.sh).
    var development: Bool { object(forInfoDictionaryKey: "TsyncDevelopment") as? String == "YES" }
}
