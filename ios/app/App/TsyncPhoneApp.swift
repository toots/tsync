import FileProvider
import SwiftUI

@main
struct TsyncPhoneApp: App {
    init() {
        Core.start(bounded: false)
        if CommandLine.arguments.contains("-selftest") { Task.detached { await SelfTest.run() } }
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

/// Joins domains from a setup link (setup-link §6.3), registers them with
/// the File Provider, and shows the extension's footprint log.
struct ContentView: View {
    @State private var link = ""
    @State private var message = ""
    @State private var domains = Tsync.domainNames(Tsync.configFile)
    @State private var footprint = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Domains") {
                    if domains.isEmpty { Text("None yet") }
                    ForEach(domains, id: \.self) { Text($0) }
                }
                Section("Join") {
                    TextField("Setup link", text: $link, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Join") { join() }.disabled(link.isEmpty)
                    Button("Add a local test domain") { addLocalTest() }
                    Button("Remove every domain", role: .destructive) { removeAll() }
                    if !message.isEmpty { Text(message).font(.footnote) }
                }
                Section("Self-test") {
                    Text("Creates \(SelfTest.files) files and a \(SelfTest.bigBytes >> 20) MiB file in the Test domain, lists them, evicts the large one and reads it back, all through the Files extension.")
                        .font(.footnote)
                    Button("Run self-test") {
                        message = "Self-test running; refresh the memory log"
                        Task.detached { await SelfTest.run() }
                    }
                }
                Section("Extension memory") {
                    Button("Refresh") { readFootprint() }
                    Button("Clear", role: .destructive) {
                        try? FileManager.default.removeItem(at: Footprint.log)
                        readFootprint()
                    }
                    Text(footprint).font(.system(.caption2, design: .monospaced))
                }
            }
            .navigationTitle("tsync")
            .onAppear {
                Configs.registerAll()
                readFootprint()
            }
        }
    }

    private func join() {
        guard let reply = Core.text("setup_link", Data(link.utf8)),
            let json = try? JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any]
        else { return message = "the core gave no answer" }
        if let error = json["error"] as? String { return message = error }
        let joined = (json["domains"] as? [[String: Any]] ?? []).compactMap { d -> [String: Any]? in
            guard let name = d["name"] as? String, let url = d["url"] as? String,
                let secret = d["secret"] as? String
            else { return nil }
            return Configs.server(name: name, url: url, secret: secret)
        }
        finish(Configs.add(joined))
    }

    private func addLocalTest() {
        finish(Configs.add([Configs.localTest()]))
    }

    private func finish(_ refusal: String?) {
        message = refusal ?? "Joined; open the Files app"
        domains = Tsync.domainNames(Tsync.configFile)
        if refusal == nil { link = "" }
        Configs.registerAll()
    }

    private func removeAll() {
        NSFileProviderManager.removeAllDomains { error in
            DispatchQueue.main.async {
                if let error = error { return message = error.localizedDescription }
                try? FileManager.default.removeItem(at: Tsync.configFile)
                domains = []
                message = "Removed; restart the app to join again"
            }
        }
    }

    private func readFootprint() {
        let text = (try? String(contentsOf: Footprint.log, encoding: .utf8)) ?? "no record yet"
        footprint = text.split(separator: "\n").suffix(60).joined(separator: "\n")
    }
}
