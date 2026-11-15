import UIKit

/// vault §8.1: how a domain's vault looks in a list: its icon when it has one,
/// otherwise tsync's glyph in the vault's colour.
enum VaultLook {
    static let side: CGFloat = 18

    /// Off the main queue: one `vault_status` through the service.
    static func image(domain: String) -> UIImage? {
        guard let reply = try? OwnerClient.call(["action": "vault_status", "domain": domain]),
            let look = reply["appearance"] as? [String: Any]
        else { return nil }
        return image(look)
    }

    /// From a `vault_status` reply's `appearance`.
    static func image(_ look: [String: Any]) -> UIImage? {
        let size = CGSize(width: side, height: side)
        if let icon = look["icon"] as? String, let data = Data(base64Encoded: icon), let image = UIImage(data: data) {
            return UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        }
        guard let hex = look["color"] as? String, let color = color(hex),
            let glyph = UIImage(named: "tsync-idle-symbolic")
        else { return nil }
        return glyph.withTintColor(color, renderingMode: .alwaysOriginal)
    }

    static func color(_ hex: String) -> UIColor? {
        guard hex.count == 7, hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return UIColor(
            red: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }
}
