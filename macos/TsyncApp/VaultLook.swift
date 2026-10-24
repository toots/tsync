import AppKit

/// vault §8.1: how a domain's vault looks in a picker: its icon when it has one,
/// in place of tsync's; otherwise tsync's icon in the vault's colour.
enum VaultLook {
    static let side: CGFloat = 16

    /// Off the main queue: one `vault_status` per call.
    static func image(domain: String) -> NSImage? {
        guard let reply = try? OwnerClient.call(["action": "vault_status", "domain": domain]),
            let look = reply["appearance"] as? [String: Any]
        else { return nil }
        if let icon = look["icon"] as? String, let data = Data(base64Encoded: icon), let image = NSImage(data: data) {
            image.size = NSSize(width: side, height: side)
            return image
        }
        guard let hex = look["color"] as? String, let color = color(hex) else { return nil }
        return tinted(color)
    }

    static func color(_ hex: String) -> NSColor? {
        guard hex.count == 7, hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }

    /// tsync's template glyph, filled with the colour.
    static func tinted(_ color: NSColor) -> NSImage? {
        guard let glyph = NSImage(named: "tsync-idle-symbolic") else { return nil }
        let size = NSSize(width: side, height: side)
        return NSImage(size: size, flipped: false) { rect in
            glyph.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}
