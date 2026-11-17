import AppKit

/// passwords/macos: how the credential sheet is drawn on macOS. The requests
/// and their order are the controller's.
final class Sheet {
    typealias Image = NSImage

    static let device = "Mac"
    static let unlockPlace = "from the tsync menu"
    static let unansweredHint = "Check that tsync is running"

    /// A footer button: `main` answers Return, `cancel` Escape.
    struct Button {
        enum Role { case main, cancel }
        let title: String
        let role: Role
        let action: () -> Void

        init(_ title: String, _ role: Role, _ action: @escaping () -> Void) {
            self.title = title
            self.role = role
            self.action = action
        }
    }

    let root = NSView()
    private let stack = NSStackView()
    private let heading = NSTextField(labelWithString: "tsync")

    init() {
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
    }

    func reset(_ title: String, wrapping: Bool = false) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        heading.stringValue = title
        heading.lineBreakMode = wrapping ? .byWordWrapping : .byTruncatingTail
        add(heading)
        stack.setCustomSpacing(16, after: heading)
    }

    func note(_ text: String) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = .secondaryLabelColor
        add(label)
    }

    func row(title: String, detail: String, symbol: String, image: NSImage?, _ action: @escaping () -> Void) {
        add(RowButton(title: title, detail: detail, symbol: symbol, image: image, action))
    }

    func inert(title: String, detail: String, symbol: String) {
        let row = RowButton(title: title, detail: detail, symbol: symbol) {}
        row.isEnabled = false
        add(row)
    }

    /// The sheet's buttons, right-aligned below its rows.
    func footer(_ buttons: [Button]) {
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(20, after: last) }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bar = NSStackView(views: [spacer] + buttons.map(button))
        bar.orientation = .horizontal
        bar.spacing = 8
        add(bar)
    }

    /// A sheet waiting on the owner: a spinner, and Cancel.
    func working(_ title: String, cancel: @escaping () -> Void) {
        reset(title)
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        add(spinner, stretched: false)
        footer([Button("Cancel", .cancel, cancel)])
    }

    /// Adds a row spanning the sheet between its margins.
    private func add(_ row: NSView, stretched: Bool = true) {
        stack.addArrangedSubview(row)
        guard stretched else { return }
        let margins = stack.edgeInsets.left + stack.edgeInsets.right
        row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -margins).isActive = true
    }

    private func button(_ spec: Button) -> NSButton {
        let button = ClosureButton(title: spec.title, target: nil, action: nil)
        button.handler = spec.action
        button.target = button
        button.action = #selector(ClosureButton.fire)
        button.keyEquivalent = spec.role == .main ? "\r" : "\u{1b}"
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

    init(title: String, detail: String, symbol: String, image: NSImage? = nil, _ action: @escaping () -> Void) {
        handler = action
        super.init(frame: .zero)
        isBordered = false
        self.title = ""
        target = self
        self.action = #selector(fire)
        wantsLayer = true
        layer?.cornerRadius = 8

        // vault §8.1: the vault's mark when there is one, else the row's kind.
        let icon = NSImageView(image: image ?? NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        if image == nil { icon.contentTintColor = .secondaryLabelColor }
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
