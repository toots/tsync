import AppKit

/// security-model §10.6: a secret's field, masked until its Show box is
/// checked; the box starts unchecked each time the field is made.
final class SecretField: NSView {
    static let fieldHeight: CGFloat = 24
    static let height: CGFloat = fieldHeight + 22

    let masked = NSSecureTextField()
    private let clear = NSTextField()
    private let show = NSButton(checkboxWithTitle: "Show", target: nil, action: nil)

    init(placeholder: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: Self.height))
        for field in [masked, clear] as [NSTextField] {
            field.placeholderString = placeholder
            field.isAutomaticTextCompletionEnabled = false
            field.autoresizingMask = [.width]
            addSubview(field)
        }
        clear.isHidden = true
        show.target = self
        show.action = #selector(toggle)
        addSubview(show)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let width = bounds.width
        masked.frame = NSRect(x: 0, y: bounds.height - Self.fieldHeight, width: width, height: Self.fieldHeight)
        clear.frame = masked.frame
        show.frame = NSRect(x: 0, y: 0, width: width, height: 18)
    }

    var stringValue: String {
        get { show.state == .on ? clear.stringValue : masked.stringValue }
        set {
            masked.stringValue = newValue
            clear.stringValue = newValue
        }
    }

    /// The field typed into now, for the dialog's first responder.
    var input: NSTextField { show.state == .on ? clear : masked }

    @objc private func toggle() {
        let shown = show.state == .on
        let value = shown ? masked.stringValue : clear.stringValue
        stringValue = value
        masked.isHidden = shown
        clear.isHidden = show.state != .on
        window?.makeFirstResponder(input)
    }
}
