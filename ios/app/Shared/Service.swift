import FileProvider
import Foundation
import Security

/// ios.md §5.4: the owner's requests, carried from a process that cannot own
/// the domain to the File Provider extension that does.
@objc protocol OwnerService {
    /// The bridge's `request`: one JSON request, one JSON reply.
    func request(_ token: Data, _ json: Data, reply: @escaping (Data) -> Void)
}

enum Service {
    static var name: NSFileProviderServiceName { NSFileProviderServiceName(Tsync.appID + ".owner") }

    static var interface: NSXPCInterface { NSXPCInterface(with: OwnerService.self) }

    private static var tokenFile: URL { Tsync.groupContainer.appendingPathComponent("service.token") }

    /// The 32 bytes every call carries. The extension makes it when none
    /// exists: written aside, then linked into place, which fails when another
    /// process got there first, so every process reads the same bytes.
    static func token(create: Bool) -> Data? {
        if let token = try? Data(contentsOf: tokenFile), token.count == 32 { return token }
        guard create else { return nil }
        var bytes = Data(count: 32)
        let drawn = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        guard drawn == errSecSuccess else { return nil }
        let aside = tokenFile.deletingLastPathComponent()
            .appendingPathComponent("service.token.\(getpid())")
        try? FileManager.default.removeItem(at: aside)
        guard FileManager.default.createFile(
            atPath: aside.path, contents: bytes, attributes: [.posixPermissions: 0o600])
        else { return nil }
        link(aside.path, tokenFile.path)
        unlink(aside.path)
        return try? Data(contentsOf: tokenFile)
    }

    /// A refusal in the owner's reply shape.
    static func refusal(_ code: String, _ message: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["ok": false, "code": code, "error": message]))
            ?? Data()
    }
}
