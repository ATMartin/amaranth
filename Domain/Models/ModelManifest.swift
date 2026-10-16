public import Foundation

public enum ModelRole: String, Hashable, Sendable, Codable {
    case asr, vad, diarizationSegmentation, diarizationEmbedding, summary
}

public struct ModelFile: Hashable, Sendable, Codable {
    /// Relative to the manifest root.
    public var path: String
    public var sha256: String
    public var byteSize: Int64
    /// Download URL, pinned to an immutable revision. Used only by explicit install, never at inference time.
    public var sourceURL: URL?

    public init(path: String, sha256: String, byteSize: Int64, sourceURL: URL? = nil) {
        self.path = path
        self.sha256 = sha256
        self.byteSize = byteSize
        self.sourceURL = sourceURL
    }
}

public struct ModelLicense: Hashable, Sendable, Codable {
    /// SPDX identifier where one exists, e.g. "CC-BY-4.0", "Apache-2.0".
    public var identifier: String
    public var noticePath: String?
    public var attribution: String
    public init(identifier: String, noticePath: String? = nil, attribution: String) {
        self.identifier = identifier
        self.noticePath = noticePath
        self.attribution = attribution
    }
}

/// Exact provenance of one model asset set (plan §5 "Model supply chain").
public struct ModelManifest: Hashable, Sendable, Codable, Identifiable {
    public var id: ModelManifestID
    public var version: String
    public var role: ModelRole
    public var family: String
    public var sourceRepository: String
    /// Immutable commit/revision hash. Never "main" or "latest".
    public var sourceRevision: String
    public var conversionProvenance: String
    public var tokenizerIdentity: String?
    public var promptTemplateIdentity: String?
    public var files: [ModelFile]
    public var license: ModelLicense
    public var minimumOS: String
    public var measuredPeakFootprintBytes: Int64?

    public init(id: ModelManifestID, version: String, role: ModelRole, family: String, sourceRepository: String,
                sourceRevision: String, conversionProvenance: String, tokenizerIdentity: String? = nil,
                promptTemplateIdentity: String? = nil, files: [ModelFile], license: ModelLicense,
                minimumOS: String, measuredPeakFootprintBytes: Int64? = nil) {
        self.id = id
        self.version = version
        self.role = role
        self.family = family
        self.sourceRepository = sourceRepository
        self.sourceRevision = sourceRevision
        self.conversionProvenance = conversionProvenance
        self.tokenizerIdentity = tokenizerIdentity
        self.promptTemplateIdentity = promptTemplateIdentity
        self.files = files
        self.license = license
        self.minimumOS = minimumOS
        self.measuredPeakFootprintBytes = measuredPeakFootprintBytes
    }

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.byteSize } }

    /// Rejects floating revisions such as "main"/"latest"; requires hashes on every file.
    public func validatePinning() throws {
        let floating: Set<String> = ["main", "master", "latest", "head", ""]
        guard !floating.contains(sourceRevision.lowercased()) else {
            throw DomainError.invariantViolated("manifest \(id) uses floating revision '\(sourceRevision)'")
        }
        for f in files where f.sha256.count != 64 {
            throw DomainError.invariantViolated("manifest \(id) file \(f.path) lacks sha256")
        }
    }
}

public struct ModelPack: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var version: String
    public var profile: HardwareProfile
    public var manifests: [ModelManifest]
    public init(id: String, version: String, profile: HardwareProfile, manifests: [ModelManifest]) {
        self.id = id
        self.version = version
        self.profile = profile
        self.manifests = manifests
    }
}

public enum HardwareProfile: String, Hashable, Sendable, Codable {
    /// Base M2 / 16 GB reference.
    case standard16GB
    /// Experimental 8 GB profile, only once its gates pass.
    case experimental8GB
}

public struct ResolvedModel: Sendable {
    public var manifest: ModelManifest
    public var rootURL: URL
    public init(manifest: ModelManifest, rootURL: URL) {
        self.manifest = manifest
        self.rootURL = rootURL
    }
    public func url(for path: String) -> URL { rootURL.appending(path: path) }
}

public enum ModelRegistryError: Error, Hashable, Sendable {
    case notInstalled(ModelManifestID)
    case corrupt(ModelManifestID, path: String)
    case incompatible(ModelManifestID, reason: String)
}

/// Resolves verified local assets. **Never** downloads implicitly.
public protocol ModelRegistry: Sendable {
    func resolve(_ id: ModelManifestID) throws -> ResolvedModel
}
