import AppKit
import AuthenticationServices
import LocalAuthentication
import os

/// §3: entry points and row counts only, never a value.
private let trace = Logger(subsystem: "org.feverdreamtv.tsync.credentials", category: "requests")

/// passwords/macos: the sheet macOS shows for tsync. Every completion follows a
/// pick or an approval; nothing completes without the user (§3).
final class CredentialProviderViewController: ASCredentialProviderViewController {
    private let stack = NSStackView()
    private let heading = NSTextField(labelWithString: "tsync")

    override func loadView() {
        let root = NSView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        heading.lineBreakMode = .byTruncatingTail
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 400),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    // MARK: requests the system hands over

    /// §3: never without the sheet.
    override func provideCredentialWithoutUserInteraction(for credentialRequest: ASCredentialRequest)
    {
        trace.info("without interaction: \(credentialRequest.type.rawValue)")
        cancel(.userInteractionRequired)
    }

    /// §3: a remembered credential shows its kind's sheet for its service.
    override func prepareInterfaceToProvideCredential(for credentialRequest: ASCredentialRequest) {
        trace.info("interface for a remembered credential: \(credentialRequest.type.rawValue)")
        if let request = credentialRequest as? ASPasskeyCredentialRequest,
            let identity = request.credentialIdentity as? ASPasskeyCredentialIdentity
        {
            let verify = request.userVerificationPreference != .discouraged
            if let record = identity.recordIdentifier, let slash = record.firstIndex(of: "/") {
                return signIn(
                    Choice(
                        domain: String(record[..<slash]), id: String(record[record.index(after: slash)...]),
                        title: identity.userName, detail: "", passkey: true),
                    rpId: identity.relyingPartyIdentifier, hash: request.clientDataHash, verify: verify)
            }
            passkeyList(
                rpId: identity.relyingPartyIdentifier, hash: request.clientDataHash, verify: verify,
                allow: [])
        } else if #available(macOS 15.0, *), credentialRequest.type == .oneTimeCode {
            prepareOneTimeCodeCredentialList(for: [credentialRequest.credentialIdentity.serviceIdentifier])
        } else {
            prepareCredentialList(for: [credentialRequest.credentialIdentity.serviceIdentifier])
        }
    }

    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        trace.info("login list for \(serviceIdentifiers.count) services")
        let origins = serviceIdentifiers.map(origin)
        show("Choose a login") { Requests.logins(origins: origins) } pick: { choice in
            try self.fill(choice)
        }
    }

    private func fill(_ choice: Choice) throws {
        let reply = try Requests.call(choice.domain, "get", ["id": choice.id])
        let credential = ASPasswordCredential(
            user: reply["username"] as? String ?? "", password: reply["password"] as? String ?? "")
        finish { $0.completeRequest(withSelectedCredential: credential) }
    }

    @available(macOS 15.0, *)
    override func prepareOneTimeCodeCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier])
    {
        trace.info("code list for \(serviceIdentifiers.count) services")
        let origins = serviceIdentifiers.map(origin)
        show("Choose a one-time code") { Requests.logins(origins: origins, codesOnly: true) } pick: {
            choice in
            let reply = try Requests.call(choice.domain, "get", ["id": choice.id])
            guard let code = reply["code"] as? String else {
                throw OwnerFailure.refused(code: "not_found", message: "no code is linked", item: nil)
            }
            self.finish { $0.completeOneTimeCodeRequest(using: ASOneTimeCodeCredential(code: code)) }
        }
    }

    override func prepareCredentialList(
        for serviceIdentifiers: [ASCredentialServiceIdentifier],
        requestParameters: ASPasskeyCredentialRequestParameters
    ) {
        passkeyList(
            rpId: requestParameters.relyingPartyIdentifier, hash: requestParameters.clientDataHash,
            verify: requestParameters.userVerificationPreference != .discouraged,
            allow: requestParameters.allowedCredentials,
            origins: serviceIdentifiers.map(origin))
    }

    /// §4: the passkeys of `rpId`, then the logins of `origins` when the page takes one.
    private func passkeyList(
        rpId: String, hash: Data, verify: Bool, allow: [Data], origins: [String] = []
    ) {
        trace.info("passkey list, \(origins.count) login services")
        let title = origins.isEmpty ? "Sign in to \(rpId) with a passkey" : "Sign in to \(rpId)"
        show(title) {
            var listed = Requests.passkeys(rpId: rpId, allow: allow)
            if !origins.isEmpty { listed.merge(Requests.logins(origins: origins)) }
            return listed
        } pick: { choice in
            guard choice.passkey else { return try self.fill(choice) }
            try self.signAssertion(choice, rpId: rpId, hash: hash, verify: verify)
        }
    }

    /// §4.1: a passkey Safari's own list named, signed without another list. The
    /// owner is asked first, so a locked vault or a gone record is told before
    /// any verification.
    private func signIn(_ choice: Choice, rpId: String, hash: Data, verify: Bool) {
        trace.info("passkey named by an entry")
        run("Signing in to \(rpId)") {
            do {
                _ = try Requests.call(choice.domain, "get", ["id": choice.id])
            } catch let failure as OwnerFailure where failure.code == "not_found" {
                return DispatchQueue.main.async {
                    self.passkeyList(rpId: rpId, hash: hash, verify: verify, allow: [])
                }
            } catch let failure as OwnerFailure where failure.code == "locked" {
                return DispatchQueue.main.async { self.lockedSheet("Signing in to \(rpId)", choice.domain) }
            }
            try self.signAssertion(choice, rpId: rpId, hash: hash, verify: verify)
        }
    }

    private func signAssertion(_ choice: Choice, rpId: String, hash: Data, verify: Bool) throws {
        let verified = try self.verify(verify, reason: "sign in to \(rpId)")
        var args: [String: Any] = [
            "origin": "https://" + rpId, "rpId": rpId, "id": choice.id,
            "clientDataHash": hash.base64URL,
        ]
        if verified { args["verified"] = true }
        let reply = try Requests.call(choice.domain, "passkey_assert", args)
        let credential = ASPasskeyAssertionCredential(
            userHandle: try Requests.data(reply, "userHandle"),
            relyingParty: rpId,
            signature: try Requests.data(reply, "signature"),
            clientDataHash: hash,
            authenticatorData: try Requests.data(reply, "authenticatorData"),
            credentialID: try Requests.data(reply, "credentialId"))
        finish { $0.completeAssertionRequest(using: credential) }
    }

    override func prepareInterface(forPasskeyRegistration registrationRequest: ASCredentialRequest) {
        trace.info("passkey registration")
        guard let request = registrationRequest as? ASPasskeyCredentialRequest,
            let identity = request.credentialIdentity as? ASPasskeyCredentialIdentity
        else { return cancel(.failed) }
        let rpId = identity.relyingPartyIdentifier
        let title = "Save a passkey for \(identity.userName) on \(rpId)"
        working(title)
        DispatchQueue.global().async {
            let target = Requests.creationDomain()
            DispatchQueue.main.async {
                switch target {
                case .locked(let domain):
                    self.lockedSheet(title, domain)
                case .none:
                    self.reset(title)
                    self.add(self.note("No domain on this Mac uses passwords."))
                    self.footer([self.defaultButton("Close") { self.cancel(.failed) }])
                case .domain(let domain):
                    self.approve("\(title) in \(domain)?") {
                        try self.register(request, identity, in: domain)
                    }
                }
            }
        }
    }

    private func register(
        _ request: ASPasskeyCredentialRequest, _ identity: ASPasskeyCredentialIdentity, in domain: String
    ) throws {
        let rpId = identity.relyingPartyIdentifier
        let verified = try verify(
            request.userVerificationPreference != .discouraged, reason: "save a passkey for \(rpId)")
        var args: [String: Any] = [
            "origin": "https://" + rpId, "rpId": rpId,
            "userHandle": identity.userHandle.base64URL,
            "userName": identity.userName, "userDisplayName": identity.userName,
            "algorithms": request.supportedAlgorithms.map { $0.rawValue },
            "clientDataHash": request.clientDataHash.base64URL,
        ]
        if #available(macOS 15.0, *), let excluded = request.excludedCredentials, !excluded.isEmpty {
            args["exclude"] = excluded.map { $0.credentialID.base64URL }
        }
        if verified { args["verified"] = true }
        // A cancel during verification leaves nothing to write.
        guard !DispatchQueue.main.sync(execute: { finished }) else { return }
        let reply: [String: Any]
        do {
            reply = try Requests.call(domain, "passkey_create", args)
        } catch let failure as OwnerFailure where failure.code == "exists" {
            if #available(macOS 15.0, *) { return cancel(.matchedExcludedCredential) }
            return cancel(.failed)
        }
        let credential = ASPasskeyRegistrationCredential(
            relyingParty: rpId, clientDataHash: request.clientDataHash,
            credentialID: try Requests.data(reply, "credentialId"),
            attestationObject: try Requests.data(reply, "attestationObject"))
        finish { $0.completeRegistrationRequest(using: credential) }
    }

    override func prepareInterfaceForExtensionConfiguration() {
        reset("tsync fills logins and passkeys from your vault")
        add(note("Unlock a domain's vault from the tsync menu."))
        footer([defaultButton("Done") { self.finish { $0.completeExtensionConfigurationRequest() } }])
    }

    // MARK: completing

    /// Main queue only: set by the first completion or cancel, so a request
    /// completes once.
    private var finished = false

    /// Completes the request on the main queue, once.
    private func finish(_ complete: @escaping (ASCredentialProviderExtensionContext) -> Void) {
        DispatchQueue.main.async {
            guard !self.finished else { return }
            self.finished = true
            complete(self.extensionContext)
        }
    }

    private func cancel(_ code: ASExtensionError.Code) {
        finish { $0.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: code.rawValue)) }
    }

    // MARK: the sheet

    private func origin(_ identifier: ASCredentialServiceIdentifier) -> String {
        identifier.type == .URL ? identifier.identifier : "https://" + identifier.identifier
    }

    private func reset(_ title: String) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        heading.stringValue = title
        heading.lineBreakMode = .byTruncatingTail
        add(heading)
        stack.setCustomSpacing(16, after: heading)
    }

    /// Adds a row spanning the sheet between its margins.
    private func add(_ row: NSView, stretched: Bool = true) {
        stack.addArrangedSubview(row)
        if stretched { fill(width: row) }
    }

    private func fill(width row: NSView) {
        let margins = stack.edgeInsets.left + stack.edgeInsets.right
        row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -margins).isActive = true
    }

    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// The sheet's buttons, right-aligned below its rows.
    private func footer(_ buttons: [NSButton]) {
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(20, after: last) }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bar = NSStackView(views: [spacer] + buttons)
        bar.orientation = .horizontal
        bar.spacing = 8
        add(bar)
    }

    private func cancelButton() -> NSButton {
        let cancel = button("Cancel") { self.cancel(.userCanceled) }
        cancel.keyEquivalent = "\u{1b}"
        return cancel
    }

    private func defaultButton(_ title: String, _ action: @escaping () -> Void) -> NSButton {
        let button = button(title, action)
        button.keyEquivalent = "\r"
        return button
    }

    /// A sheet waiting on the owner: a spinner, and Cancel.
    private func working(_ title: String) {
        reset(title)
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        add(spinner, stretched: false)
        footer([cancelButton()])
    }

    /// Lists what `fetch` finds off the main queue; a pick runs `pick` off it too.
    private func show(
        _ title: String, fetch: @escaping () -> Listed, pick: @escaping (Choice) throws -> Void
    ) {
        working(title)
        DispatchQueue.global().async {
            let listed = fetch()
            trace.info(
                "listed \(listed.choices.count) rows, \(listed.locked.count) locked, \(listed.unanswered.count) unanswered")
            DispatchQueue.main.async {
                guard !self.finished else { return }
                self.reset(title)
                if listed.choices.isEmpty && listed.locked.isEmpty && listed.unanswered.isEmpty {
                    self.add(self.note("Nothing in tsync for this site."))
                }
                for choice in listed.choices {
                    self.add(
                        RowButton(
                            title: choice.title, detail: choice.detail,
                            symbol: choice.passkey ? "person.badge.key" : "key"
                        ) { self.run(title) { try pick(choice) } })
                }
                for domain in listed.locked { self.add(self.lockedRow(domain)) }
                for domain in listed.unanswered { self.add(self.unansweredRow(domain)) }
                self.footer([self.cancelButton()])
            }
        }
    }

    private func approve(_ question: String, _ action: @escaping () throws -> Void) {
        reset(question)
        heading.lineBreakMode = .byWordWrapping
        footer([cancelButton(), defaultButton("Save") { self.run(question, action) }])
    }

    /// §6: a locked domain, pointing to the menu; it does nothing.
    private func lockedRow(_ domain: String) -> NSView {
        inertRow(title: "\(domain) is locked", detail: "Unlock it from the tsync menu", symbol: "lock")
    }

    /// §2: a domain whose owner did not answer, so its absence is not taken for
    /// an empty list.
    private func unansweredRow(_ domain: String) -> NSView {
        inertRow(
            title: "\(domain) did not answer", detail: "Check that tsync is running",
            symbol: "exclamationmark.triangle")
    }

    private func inertRow(title: String, detail: String, symbol: String) -> NSView {
        let row = RowButton(title: title, detail: detail, symbol: symbol) {}
        row.isEnabled = false
        return row
    }

    private func lockedSheet(_ title: String, _ domain: String) {
        reset(title)
        add(lockedRow(domain))
        footer([defaultButton("Close") { self.cancel(.userCanceled) }])
    }

    /// Runs a pick or an approval off the main queue, the sheet waiting with
    /// only Cancel, so a second click cannot run it again. A refusal is shown;
    /// a verification the user cancelled cancels the request.
    private func run(_ title: String, _ action: @escaping () throws -> Void) {
        guard !finished else { return }
        working(title)
        DispatchQueue.global().async {
            do {
                try action()
            } catch let error as LAError where [.userCancel, .appCancel, .systemCancel].contains(error.code) {
                self.cancel(.userCanceled)
            } catch {
                let reason = (error as? OwnerFailure)?.message ?? error.localizedDescription
                DispatchQueue.main.async {
                    guard !self.finished else { return }
                    self.reset("tsync could not do it")
                    self.add(self.note(reason))
                    self.footer([self.defaultButton("Close") { self.cancel(.failed) }])
                }
            }
        }
    }

    /// §5: LocalAuthentication when the relying party asks; false when not asked.
    private func verify(_ asked: Bool, reason: String) throws -> Bool {
        guard asked else { return false }
        let context = LAContext()
        let done = DispatchSemaphore(value: 0)
        var outcome: Error?
        var ok = false
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
            ok = success
            outcome = error
            done.signal()
        }
        done.wait()
        if !ok {
            throw outcome
                ?? OwnerFailure.refused(code: "denied", message: "the user was not verified", item: nil)
        }
        return true
    }

    private func button(_ title: String, _ action: @escaping () -> Void) -> NSButton {
        let button = ClosureButton(title: title, target: nil, action: nil)
        button.handler = action
        button.target = button
        button.action = #selector(ClosureButton.fire)
        return button
    }
}

/// An NSButton whose action is a closure.
final class ClosureButton: NSButton {
    var handler: () -> Void = {}
    @objc func fire() { handler() }
}

/// A list row: an icon, the record's title, and its username below.
final class RowButton: NSButton {
    private let handler: () -> Void
    private var hovered = false { didSet { needsDisplay = true } }

    init(title: String, detail: String, symbol: String, _ action: @escaping () -> Void) {
        handler = action
        super.init(frame: .zero)
        isBordered = false
        self.title = ""
        target = self
        self.action = #selector(fire)
        wantsLayer = true
        layer?.cornerRadius = 8

        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        let below = NSTextField(labelWithString: detail)
        below.font = .systemFont(ofSize: 12)
        below.textColor = .secondaryLabelColor
        below.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: detail.isEmpty ? [name] : [name, below])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let row = NSStackView(views: [icon, text])
        row.orientation = .horizontal
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
        ])
        setAccessibilityLabel(detail.isEmpty ? title : "\(title), \(detail)")
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self))
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func updateLayer() {
        layer?.backgroundColor =
            (hovered ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.18)
                : NSColor.quaternaryLabelColor.withAlphaComponent(0.08)).cgColor
    }

    override var wantsUpdateLayer: Bool { true }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    @objc private func fire() { handler() }
}
