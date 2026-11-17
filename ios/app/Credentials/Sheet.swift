import UIKit

/// passwords/ios: how the credential sheet is drawn on iOS. The requests and
/// their order are the controller's, shared with macOS.
final class Sheet {
    typealias Image = UIImage

    static let device = "iPhone"
    static let unlockPlace = "in the tsync app"
    static let unansweredHint = "Open tsync"

    /// A footer button: `main` is the prominent one.
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

    let root = UIView()
    private let stack = UIStackView()

    init() {
        root.backgroundColor = .systemGroupedBackground
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 10
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 24, leading: 20, bottom: 24, trailing: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor),
        ])
    }

    func reset(_ title: String, wrapping: Bool = false) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let heading = UILabel()
        heading.text = title
        heading.font = .preferredFont(forTextStyle: .headline)
        heading.numberOfLines = wrapping ? 0 : 1
        stack.addArrangedSubview(heading)
        stack.setCustomSpacing(16, after: heading)
    }

    func note(_ text: String) {
        let label = UILabel()
        label.text = text
        label.numberOfLines = 0
        label.textColor = .secondaryLabel
        stack.addArrangedSubview(label)
    }

    func row(title: String, detail: String, symbol: String, image: UIImage?, _ action: @escaping () -> Void) {
        stack.addArrangedSubview(rowButton(title: title, detail: detail, symbol: symbol, image: image, action))
    }

    func inert(title: String, detail: String, symbol: String) {
        let row = rowButton(title: title, detail: detail, symbol: symbol, image: nil) {}
        row.isEnabled = false
        stack.addArrangedSubview(row)
    }

    func footer(_ buttons: [Button]) {
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(20, after: last) }
        for spec in buttons {
            var configuration: UIButton.Configuration = spec.role == .main ? .borderedProminent() : .bordered()
            configuration.title = spec.title
            stack.addArrangedSubview(UIButton(configuration: configuration, primaryAction: UIAction { _ in spec.action() }))
        }
    }

    func working(_ title: String, cancel: @escaping () -> Void) {
        reset(title)
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        stack.addArrangedSubview(spinner)
        footer([Button("Cancel", .cancel, cancel)])
    }

    /// vault §8.1: the vault's mark when there is one, else the row's kind.
    private func rowButton(
        title: String, detail: String, symbol: String, image: UIImage?, _ action: @escaping () -> Void
    ) -> UIButton {
        var configuration = UIButton.Configuration.gray()
        configuration.title = title
        configuration.subtitle = detail.isEmpty ? nil : detail
        configuration.image = image ?? UIImage(systemName: symbol)
        configuration.imagePadding = 10
        configuration.titleAlignment = .leading
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
        button.contentHorizontalAlignment = .leading
        return button
    }
}
