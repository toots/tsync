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
            if let record = identity.recordIdentifier, let slash = record.firstIndex(of: "/") {
                return signIn(
                    Choice(
                        domain: String(record[..<slash]), id: String(record[record.index(after: slash)...]),
                        title: identity.userName, detail: "", passkey: true),
                    rpId: identity.relyingPartyIdentifier, hash: request.clientDataHash,
                    verify: request.userVerificationPreference != .discouraged)
            }
            passkeyList(
                rpId: identity.relyingPartyIdentifier, hash: request.clientDataHash,
                verify: request.userVerificationPreference != .discouraged, allow: [])
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
        extensionContext.completeRequest(withSelectedCredential: credential)
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
            self.extensionContext.completeOneTimeCodeRequest(using: ASOneTimeCodeCredential(code: code))
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
            if !origins.isEmpty {
                let logins = Requests.logins(origins: origins)
                listed.choices += logins.choices
                listed.locked += logins.locked.filter { !listed.locked.contains($0) }
            }
            return listed
        } pick: { choice in
            guard choice.passkey else { return try self.fill(choice) }
            try self.signAssertion(choice, rpId: rpId, hash: hash, verify: verify)
        }
    }

    /// §4.1: a passkey Safari's own list named, signed without another list.
    private func signIn(_ choice: Choice, rpId: String, hash: Data, verify: Bool) {
        trace.info("passkey named by an entry")
        reset("Signing in to \(rpId)")
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        add(spinner, stretched: false)
        run {
            do {
                try self.signAssertion(choice, rpId: rpId, hash: hash, verify: verify)
            } catch let failure as OwnerFailure where failure.code == "not_found" {
                DispatchQueue.main.async {
                    self.passkeyList(rpId: rpId, hash: hash, verify: verify, allow: [])
                }
            }
        }
    }

    private func signAssertion(_ choice: Choice, rpId: String, hash: Data, verify: Bool) throws {
        let verified = try self.verify(verify, reason: "sign in to \(rpId)")
        var args: [String: Any] = [
            "origin": "https://" + rpId, "rpId": rpId, "id": choice.id,
            "clientDataHash": base64URL(hash),
        ]
        if verified { args["verified"] = true }
        let reply = try Requests.call(choice.domain, "passkey_assert", args)
        let credential = ASPasskeyAssertionCredential(
            userHandle: fromBase64URL(reply["userHandle"] as? String ?? "") ?? Data(),
            relyingParty: rpId,
            signature: fromBase64URL(reply["signature"] as? String ?? "") ?? Data(),
            clientDataHash: hash,
            authenticatorData: fromBase64URL(reply["authenticatorData"] as? String ?? "") ?? Data(),
            credentialID: fromBase64URL(reply["credentialId"] as? String ?? "") ?? Data())
        self.extensionContext.completeAssertionRequest(using: credential)
    }

    override func prepareInterface(forPasskeyRegistration registrationRequest: ASCredentialRequest) {
        trace.info("passkey registration")
        guard let request = registrationRequest as? ASPasskeyCredentialRequest,
            let identity = request.credentialIdentity as? ASPasskeyCredentialIdentity
        else { return cancel(.failed) }
        let rpId = identity.relyingPartyIdentifier
        let verify = request.userVerificationPreference != .discouraged
        approve("Save a passkey for \(identity.userName) on \(rpId)?") {
            guard let domain = Requests.creationDomain() else {
                throw OwnerFailure.refused(
                    code: "invalid", message: "no domain uses passwords", item: nil)
            }
            let verified = try self.verify(verify, reason: "save a passkey for \(rpId)")
            var args: [String: Any] = [
                "origin": "https://" + rpId, "rpId": rpId,
                "userHandle": base64URL(identity.userHandle),
                "userName": identity.userName, "userDisplayName": identity.userName,
                "algorithms": request.supportedAlgorithms.map { $0.rawValue },
                "clientDataHash": base64URL(request.clientDataHash),
            ]
            if verified { args["verified"] = true }
            let reply = try Requests.call(domain, "passkey_create", args)
            let credential = ASPasskeyRegistrationCredential(
                relyingParty: rpId, clientDataHash: request.clientDataHash,
                credentialID: fromBase64URL(reply["credentialId"] as? String ?? "") ?? Data(),
                attestationObject: fromBase64URL(reply["attestationObject"] as? String ?? "") ?? Data())
            self.extensionContext.completeRegistrationRequest(using: credential)
        }
    }

    override func prepareInterfaceForExtensionConfiguration() {
        reset("tsync fills logins and passkeys from your vault")
        add(
            note("Unlock a domain's vault from the tsync menu, or here when a sheet asks."))
        footer([defaultButton("Done") { self.extensionContext.completeExtensionConfigurationRequest() }])
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

    /// Lists what `fetch` finds off the main queue; a pick runs `pick` off it too.
    private func show(
        _ title: String, fetch: @escaping () -> Listed, pick: @escaping (Choice) throws -> Void
    ) {
        reset(title)
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        add(spinner, stretched: false)
        DispatchQueue.global().async {
            let listed = fetch()
            trace.info("listed \(listed.choices.count) rows, \(listed.locked.count) locked")
            DispatchQueue.main.async {
                self.reset(title)
                if listed.choices.isEmpty && listed.locked.isEmpty {
                    self.add(self.note("Nothing in tsync for this site."))
                }
                for choice in listed.choices {
                    self.add(
                        RowButton(
                            title: choice.title, detail: choice.detail,
                            symbol: choice.passkey ? "person.badge.key" : "key"
                        ) { self.run { try pick(choice) } })
                }
                for domain in listed.locked {
                    self.add(
                        RowButton(title: "\(domain) is locked", detail: "Unlock…", symbol: "lock") {
                            self.unlockForm(domain) { self.show(title, fetch: fetch, pick: pick) }
                        })
                }
                self.footer([self.cancelButton()])
            }
        }
    }

    private func approve(_ question: String, _ action: @escaping () throws -> Void) {
        reset(question)
        heading.lineBreakMode = .byWordWrapping
        footer([cancelButton(), defaultButton("Save") { self.run(action) }])
    }

    /// file-provider §10.1's form, in the sheet (passwords/macos §6).
    private func unlockForm(_ domain: String, then: @escaping () -> Void) {
        reset("Unlock the vault of \(domain)")
        let passphrase = SecretField(placeholder: "Passphrase")
        let secretKey = SecretField(placeholder: "Secret key")
        let message = note("")
        message.textColor = .systemRed
        add(passphrase)
        DispatchQueue.global().async {
            let enrolled = Requests.enrolled(domain)
            DispatchQueue.main.async {
                if !enrolled {
                    self.stack.insertArrangedSubview(secretKey, at: 2)
                    self.fill(width: secretKey)
                }
            }
        }
        add(message)
        let unlock = defaultButton("Unlock") {
                let typed = passphrase.stringValue
                let key = secretKey.superview == nil ? nil : secretKey.stringValue
                passphrase.stringValue = ""
                secretKey.stringValue = ""
                DispatchQueue.global().async {
                    do {
                        try Requests.unlock(domain, passphrase: typed, secretKey: key)
                        DispatchQueue.main.async(execute: then)
                    } catch {
                        let reason = (error as? OwnerFailure)?.message ?? "\(error)"
                        DispatchQueue.main.async { message.stringValue = reason }
                    }
                }
            }
        footer([cancelButton(), unlock])
        view.window?.makeFirstResponder(passphrase.input)
    }

    /// Runs a completion off the main queue; a refusal is shown, not swallowed.
    private func run(_ action: @escaping () throws -> Void) {
        DispatchQueue.global().async {
            do {
                try action()
            } catch {
                let reason = (error as? OwnerFailure)?.message ?? "\(error)"
                DispatchQueue.main.async {
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

    private func cancel(_ code: ASExtensionError.Code) {
        extensionContext.cancelRequest(
            withError: NSError(domain: ASExtensionErrorDomain, code: code.rawValue))
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
