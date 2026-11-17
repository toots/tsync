import AuthenticationServices
import SwiftUI

/// ios-app.md §5.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var vault: VaultModel
    @State private var autofillOff = false
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
                // passwords/ios §1: while AutoFill is off for tsync and a vault is here.
                if #available(iOS 17.0, *), autofillOff, !vault.domains.isEmpty {
                    Button("Turn on AutoFill for tsync") {
                        if #available(iOS 18.0, *) {
                            ASSettingsHelper.requestToTurnOnCredentialProviderExtension { _ in readAutofill() }
                        } else {
                            ASSettingsHelper.openCredentialProviderAppSettings { _ in }
                        }
                    }
                }
                Button("Add a domain") { adding = true }
                ForEach(model.passFailures, id: \.self) { Text($0).foregroundStyle(.red) }
                if !message.isEmpty { Text(message).foregroundStyle(.red) }
            }
            CameraBackupSection()
            Section("About") {
                LabeledContent("Version", value: Bundle.main.version)
                LabeledContent("Commit", value: Bundle.main.commit)
            }
            Section {
                NavigationLink("Diagnostics") { DiagnosticsView() }
            }
        }
        .navigationTitle("tsync")
        .onAppear { readAutofill() }
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

    private func readAutofill() {
        ASCredentialIdentityStore.shared.getState { state in
            Task { @MainActor in autofillOff = !state.isEnabled }
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

/// ios-app.md §8.6 Controls.
struct CameraBackupSection: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var backup = CameraBackup.shared
    @State private var asking = false
    @State private var refusal: String?

    var body: some View {
        Section("Camera backup") {
            Toggle("Back up photos and videos", isOn: Binding(
                get: { backup.enabled },
                set: { on in if on { asking = true } else { backup.disable() } }))
            if backup.enabled {
                Picker("Back up to", selection: Binding(get: { backup.domain ?? "" }, set: { backup.domain = $0 })) {
                    if backup.domain == nil { Text("Choose").tag("") }
                    ForEach(model.entries) { Text($0.name).tag($0.name) }
                }
                Toggle("Only over wifi", isOn: Binding(get: { backup.wifiOnly }, set: { backup.wifiOnly = $0 }))
                Toggle("Not when the battery is low", isOn: Binding(get: { backup.batteryOk }, set: { backup.batteryOk = $0 }))
                Button(backup.running ? "Backing up…" : "Back up now") { backup.request(now: true) }
                    .disabled(backup.running)
            }
            Text(backup.status).font(.footnote).foregroundStyle(.secondary)
            if let refusal { Text(refusal).font(.footnote).foregroundStyle(.red) }
        }
        .onAppear { backup.refreshStatus() }
        .confirmationDialog("Back up which photos?", isPresented: $asking, titleVisibility: .visible) {
            Button("Everything") { enable(everything: true) }
            Button("From now on") { enable(everything: false) }
        }
    }

    private func enable(everything: Bool) {
        Task { refusal = await backup.enable(everything: everything) }
    }
}
