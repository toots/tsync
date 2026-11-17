import FileProvider
import Foundation

/// ios.md §5.4: the service on the domain's root item.
extension TsyncExtension: NSFileProviderServicing {
    func supportedServiceSources(
        for itemIdentifier: NSFileProviderItemIdentifier,
        completionHandler: @escaping ([NSFileProviderServiceSource]?, Error?) -> Void
    ) -> Progress {
        completionHandler(
            itemIdentifier == .rootContainer ? [OwnerServiceSource.of(domain.displayName)] : [], nil)
        return Progress()
    }
}

/// One listener per domain for the process's life; each call runs on a thread
/// of its own, as a callback does (ios.md §4).
final class OwnerServiceSource: NSObject, NSFileProviderServiceSource, NSXPCListenerDelegate,
    OwnerService
{
    let serviceName = Service.name
    private let owner: Owner
    private let token: Data?
    private let listener = NSXPCListener.anonymous()

    private static let lock = NSLock()
    private static var sources: [String: OwnerServiceSource] = [:]

    static func of(_ domain: String) -> OwnerServiceSource {
        lock.lock()
        defer { lock.unlock() }
        if let source = sources[domain] { return source }
        let source = OwnerServiceSource(owner: Owner(domain: domain))
        sources[domain] = source
        return source
    }

    private init(owner: Owner) {
        self.owner = owner
        token = Service.token(create: true)
        super.init()
        listener.delegate = self
        listener.resume()
    }

    func makeListenerEndpoint() throws -> NSXPCListenerEndpoint { listener.endpoint }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = Service.interface
        connection.exportedObject = self
        connection.resume()
        return true
    }

    /// ios.md §5.4: in constant time.
    private static func same(_ a: Data, _ b: Data) -> Bool {
        a.count == b.count && zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    func request(_ token: Data, _ json: Data, reply: @escaping (Data) -> Void) {
        // Only a holder of the App Group reads the token.
        guard let mine = self.token, Self.same(token, mine) else {
            reply(Service.refusal("denied", "this caller does not hold the app group"))
            NSXPCConnection.current()?.invalidate()
            return
        }
        Thread.detachNewThread { [owner] in reply(Self.serve(owner, json)) }
    }

    private static func serve(_ owner: Owner, _ json: Data) -> Data {
        guard var request = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
            let action = request.removeValue(forKey: "action") as? String
        else { return Service.refusal("invalid", "the request is not a JSON object with an action") }
        request.removeValue(forKey: "domain")
        let reply: [String: Any]
        do {
            reply = try owner.answer(action, request)
        } catch let failure as OwnerFailure {
            return Service.refusal(failure.code, failure.message)
        } catch {
            return Service.refusal("internal", error.localizedDescription)
        }
        return (try? JSONSerialization.data(withJSONObject: reply))
            ?? Service.refusal("internal", "the reply does not encode")
    }
}
