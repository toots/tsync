import Foundation

public struct AWSCredentials: Codable, Sendable {
    public let accessKeyId: String
    public let secretAccessKey: String
    public init(accessKeyId: String, secretAccessKey: String) {
        self.accessKeyId = accessKeyId
        self.secretAccessKey = secretAccessKey
    }
}

public enum KeychainCredentials {
    private static var credentialsURL: URL {
        Config.groupContainerURL.appendingPathComponent("credentials.json")
    }

    public static func store(_ credentials: AWSCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        try data.write(to: credentialsURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credentialsURL.path)
    }

    public static func load() throws -> AWSCredentials {
        guard let data = try? Data(contentsOf: credentialsURL),
              let creds = try? JSONDecoder().decode(AWSCredentials.self, from: data) else {
            throw CredentialsError.notFound
        }
        return creds
    }

    public enum CredentialsError: LocalizedError {
        case notFound
        public var errorDescription: String? {
            "AWS credentials not found. Run `tsync init` first."
        }
    }
}
