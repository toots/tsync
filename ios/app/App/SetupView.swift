import SwiftUI
import VisionKit

/// android-app §10.7's Setup, joining over the registration pass
/// (ios-app.md §4).
struct SetupView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var failure: String?
    var dismissible = false

    @State private var link = ""
    @State private var offer: Offer?
    @State private var picked: Set<String> = []
    @State private var message = ""
    @State private var scanning = false
    @State private var busy = false

    var body: some View {
        Form {
            if let failure = failure {
                Section { Text(failure).foregroundStyle(.red) }
            }
            Section("Setup link") {
                TextField("Paste a setup link", text: $link, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Open link") { open(link) }.disabled(link.isEmpty || busy)
                if Scanner.usable {
                    Button("Scan setup code") { scanning = true }.disabled(busy)
                }
                if busy { ProgressView() }
            }
            if let offer = offer {
                Section("Offered by \(offer.from)") {
                    if offer.joinable.isEmpty { Text("Nothing here can be joined") }
                    ForEach(offer.joinable) { domain in
                        Toggle(isOn: binding(domain.name)) {
                            HStack {
                                Mark(about: offer.about[domain.name])
                                Text(domain.name)
                            }
                        }
                    }
                    ForEach(offer.skipped, id: \.name) { skipped in
                        Text("\(skipped.name): \(skipped.reason)").foregroundStyle(.secondary)
                    }
                    Button("Join") { join(offer) }.disabled(picked.isEmpty)
                }
            }
            if !message.isEmpty { Section { Text(message) } }
        }
        .navigationTitle("Set up tsync")
        .sheet(isPresented: $scanning) {
            Scanner { payload in
                scanning = false
                link = payload
                open(payload)
            }
            .ignoresSafeArea()
        }
    }

    private func binding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { picked.contains(name) },
            set: { on in if on { picked.insert(name) } else { picked.remove(name) } })
    }

    private func open(_ link: String) {
        busy = true
        message = ""
        let configured = Set(model.entries.map(\.name))
        Task.detached {
            let result = Offer.open(link, leaving: configured)
            await MainActor.run {
                busy = false
                switch result {
                case .success(let opened):
                    offer = opened
                    picked = Set(opened.joinable.prefix(1).map(\.name))
                case .failure(let why):
                    offer = nil
                    message = why.sentence
                }
            }
        }
    }

    private func join(_ offer: Offer) {
        let joined = offer.joinable.filter { picked.contains($0.name) }.map {
            Configs.server(name: $0.name, url: $0.url, secret: $0.secret)
        }
        if let refusal = Configs.add(joined) { return message = refusal }
        let restart = Configs.waitsForRestart(joined)
        let names = joined.compactMap { $0["name"] as? String }.joined(separator: ", ")
        var text = "Joined \(names). Turn it on in Files: Browse, then More, then Edit."
        if !restart.isEmpty {
            text += " \(restart.joined(separator: ", ")) may keep its previous settings until tsync's Files extension restarts; restarting the iPhone applies the new ones now."
        }
        message = text
        self.offer = nil
        link = ""
        model.reload()
        if dismissible && restart.isEmpty { dismiss() }
    }
}

/// An opened setup link (android.md §5 `setup_link`).
struct Offer {
    struct Domain: Identifiable {
        let name, url, secret: String
        var id: String { name }
    }

    struct About {
        let color: Color?
        let icon: UIImage?
    }

    struct Failure: Error { let sentence: String }

    let from: String
    let joinable: [Domain]
    let skipped: [(name: String, reason: String)]
    let about: [String: About]

    /// Fetching the link is the core's; domains already configured are left out.
    static func open(_ link: String, leaving configured: Set<String>) -> Result<Offer, Failure> {
        guard let reply = Core.text("setup_link", Data(link.utf8)),
            let json = try? JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any]
        else { return .failure(Failure(sentence: "The core gave no answer.")) }
        if let error = json["error"] as? String { return .failure(Failure(sentence: error)) }
        let domains = (json["domains"] as? [[String: Any]] ?? []).compactMap { d -> Domain? in
            guard let name = d["name"] as? String, let url = d["url"] as? String,
                let secret = d["secret"] as? String
            else { return nil }
            return Domain(name: name, url: url, secret: secret)
        }
        let skipped = (json["skipped"] as? [[String: Any]] ?? []).map {
            (name: $0["name"] as? String ?? "?", reason: $0["reason"] as? String ?? "")
        }
        var about: [String: About] = [:]
        for entry in json["about"] as? [[String: Any]] ?? [] {
            guard let name = entry["name"] as? String else { continue }
            let vault = entry["vault"] as? [String: Any]
            about[name] = About(
                color: (vault?["color"] as? String).flatMap(Color.init(hex:)),
                icon: (vault?["icon"] as? String)
                    .flatMap { Data(base64Encoded: $0) }.flatMap(UIImage.init(data:)))
        }
        return .success(
            Offer(
                from: json["from"] as? String ?? "a setup link",
                joinable: domains.filter { !configured.contains($0.name) },
                skipped: skipped, about: about))
    }
}

/// A domain's mark: its vault's icon or colour, when it has a vault.
struct Mark: View {
    let about: Offer.About?

    var body: some View {
        if let icon = about?.icon {
            Image(uiImage: icon).resizable().frame(width: 24, height: 24)
                .accessibilityHidden(true)
        } else if let color = about?.color {
            Circle().fill(color).frame(width: 16, height: 16).accessibilityHidden(true)
        }
    }
}

extension Color {
    /// `#rrggbb`.
    init?(hex: String) {
        guard hex.hasPrefix("#"), hex.count == 7, let value = UInt32(hex.dropFirst(), radix: 16)
        else { return nil }
        self.init(
            red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255)
    }
}

/// The system's live QR scanner; not offered where the device lacks it.
struct Scanner: UIViewControllerRepresentable {
    let found: (String) -> Void

    static var usable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])], isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        if !scanner.isScanning { try? scanner.startScanning() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        private var done = false

        init(found: @escaping (String) -> Void) { self.found = found }

        func dataScanner(
            _ scanner: DataScannerViewController, didAdd added: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            for case .barcode(let code) in added {
                guard !done, let payload = code.payloadStringValue else { continue }
                done = true
                scanner.stopScanning()
                found(payload)
                return
            }
        }
    }
}
