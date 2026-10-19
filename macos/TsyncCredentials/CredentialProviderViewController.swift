import AppKit
import AuthenticationServices
import LocalAuthentication

/// passwords/macos: the sheet macOS shows for tsync. Every completion follows a
/// pick or an approval; nothing completes without the user (§3).
final class CredentialProviderViewController: ASCredentialProviderViewController {
    private let stack = NSStackView()
    private let heading = NSTextField(labelWithString: "tsync")

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 320))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        heading.font = .boldSystemFont(ofSize: 14)
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor),
        ])
        view = root
    }

    // MARK: requests the system hands over

    /// §3: never without the sheet.
    override func provideCredentialWithoutUserInteraction(for credentialRequest: ASCredentialRequest)
    {
        cancel(.userInteractionRequired)
    }

    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        let origins = serviceIdentifiers.map(origin)
        show("Choose a login") { Requests.logins(origins: origins) } pick: { choice in
            let reply = try Requests.call(choice.domain, "get", ["id": choice.id])
            let credential = ASPasswordCredential(
                user: reply["username"] as? String ?? "", password: reply["password"] as? String ?? "")
            self.extensionContext.completeRequest(withSelectedCredential: credential)
        }
    }

    @available(macOS 15.0, *)
    override func prepareOneTimeCodeCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier])
    {
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
        let rpId = requestParameters.relyingPartyIdentifier
        let hash = requestParameters.clientDataHash
        let verify = requestParameters.userVerificationPreference != .discouraged
        let allow = requestParameters.allowedCredentials
        show("Sign in to \(rpId) with a passkey") { Requests.passkeys(rpId: rpId, allow: allow) } pick: {
            choice in
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
    }

    override func prepareInterface(forPasskeyRegistration registrationRequest: ASCredentialRequest) {
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
        stack.addArrangedSubview(
            NSTextField(wrappingLabelWithString: "Unlock a domain's vault from the tsync menu, or here when a sheet asks."))
        stack.addArrangedSubview(button("Done") { self.extensionContext.completeExtensionConfigurationRequest() })
    }

    // MARK: the sheet

    private func origin(_ identifier: ASCredentialServiceIdentifier) -> String {
        identifier.type == .URL ? identifier.identifier : "https://" + identifier.identifier
    }

    private func reset(_ title: String) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        heading.stringValue = title
        stack.addArrangedSubview(heading)
    }

    /// Lists what `fetch` finds off the main queue; a pick runs `pick` off it too.
    private func show(
        _ title: String, fetch: @escaping () -> Listed, pick: @escaping (Choice) throws -> Void
    ) {
        reset(title)
        stack.addArrangedSubview(NSTextField(labelWithString: "Reading…"))
        DispatchQueue.global().async {
            let listed = fetch()
            DispatchQueue.main.async {
                self.reset(title)
                for domain in listed.locked {
                    self.stack.addArrangedSubview(
                        self.button("\(domain) is locked — Unlock…") {
                            self.unlockForm(domain) { self.show(title, fetch: fetch, pick: pick) }
                        })
                }
                if listed.choices.isEmpty && listed.locked.isEmpty {
                    self.stack.addArrangedSubview(NSTextField(labelWithString: "Nothing in tsync for this site."))
                }
                for choice in listed.choices {
                    let label = choice.detail.isEmpty ? choice.title : "\(choice.title) — \(choice.detail)"
                    self.stack.addArrangedSubview(
                        self.button(label) { self.run { try pick(choice) } })
                }
                self.stack.addArrangedSubview(self.button("Cancel") { self.cancel(.userCanceled) })
            }
        }
    }

    private func approve(_ question: String, _ action: @escaping () throws -> Void) {
        reset(question)
        stack.addArrangedSubview(button("Save") { self.run(action) })
        stack.addArrangedSubview(button("Cancel") { self.cancel(.userCanceled) })
    }

    /// file-provider §10.1's form, in the sheet (passwords/macos §6).
    private func unlockForm(_ domain: String, then: @escaping () -> Void) {
        reset("Unlock the vault of \(domain)")
        let passphrase = SecretField(placeholder: "Passphrase")
        let secretKey = SecretField(placeholder: "Secret key")
        let message = NSTextField(wrappingLabelWithString: "")
        stack.addArrangedSubview(passphrase)
        DispatchQueue.global().async {
            let enrolled = Requests.enrolled(domain)
            DispatchQueue.main.async {
                if !enrolled { self.stack.insertArrangedSubview(secretKey, at: 2) }
            }
        }
        stack.addArrangedSubview(message)
        stack.addArrangedSubview(
            button("Unlock") {
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
            })
        stack.addArrangedSubview(button("Cancel") { self.cancel(.userCanceled) })
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
                    self.stack.addArrangedSubview(NSTextField(wrappingLabelWithString: reason))
                    self.stack.addArrangedSubview(self.button("Close") { self.cancel(.failed) })
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
