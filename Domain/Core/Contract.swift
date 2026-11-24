public import Foundation

/// Version of the frozen domain contracts. Bump on any incompatible change to a persisted or IPC type,
/// and add a migration. Decoders reject newer major versions rather than guessing.
public enum ContractVersion {
    public static let current = 1
}

public enum DomainError: Error, Equatable, Sendable {
    case invalidInterval(start: Int64, end: Int64)
    case unsupportedContractVersion(found: Int, supported: Int)
    case invalidReference(String)
    case invariantViolated(String)
}

/// Envelope used for every persisted/exported/IPC JSON document so readers can detect the schema.
public struct Versioned<Payload: Codable & Sendable>: Codable, Sendable {
    public let contractVersion: Int
    public let payload: Payload

    public init(_ payload: Payload) {
        contractVersion = ContractVersion.current
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey { case contractVersion, payload }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let v = try c.decode(Int.self, forKey: .contractVersion)
        guard v <= ContractVersion.current else {
            throw DomainError.unsupportedContractVersion(found: v, supported: ContractVersion.current)
        }
        contractVersion = v
        payload = try c.decode(Payload.self, forKey: .payload)
    }
}

public enum ContractCoding {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public static func encode<T: Codable & Sendable>(_ value: T) throws -> Data {
        try encoder().encode(Versioned(value))
    }

    public static func decode<T: Codable & Sendable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder().decode(Versioned<T>.self, from: data).payload
    }
}
