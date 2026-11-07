import Foundation

public struct VolumeSummary: Codable, Sendable, Hashable {
    public var totalBytes: Int64
    public var availableBytes: Int64
    public var importantAvailableBytes: Int64
    public var usedBytes: Int64
    public init(totalBytes: Int64, availableBytes: Int64, importantAvailableBytes: Int64, usedBytes: Int64) {
        self.totalBytes = totalBytes; self.availableBytes = availableBytes
        self.importantAvailableBytes = importantAvailableBytes; self.usedBytes = usedBytes
    }
    /// Free space shown to the user (what macOS will make available for important use).
    public var freeBytes: Int64 { max(importantAvailableBytes, availableBytes) }
}

public struct APFSVolumeInfo: Codable, Sendable, Hashable {
    public var name: String
    public var role: String
    public var usedBytes: Int64
    public var container: String
    public var isSimulator: Bool
    public init(name: String, role: String, usedBytes: Int64, container: String, isSimulator: Bool) {
        self.name = name; self.role = role; self.usedBytes = usedBytes
        self.container = container; self.isSimulator = isSimulator
    }
}

public struct Bucket: Codable, Sendable, Identifiable, Hashable {
    public var id: String { path }
    public var path: String
    public var physicalBytes: Int64
    public var inaccessible: Int
    public var children: [Bucket]
    public init(path: String, physicalBytes: Int64, inaccessible: Int, children: [Bucket]) {
        self.path = path; self.physicalBytes = physicalBytes
        self.inaccessible = inaccessible; self.children = children
    }
}

public struct RootCauseHint: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: String
    public var detail: String
    public var relatedCategory: String
    public init(id: String, kind: String, detail: String, relatedCategory: String) {
        self.id = id; self.kind = kind; self.detail = detail; self.relatedCategory = relatedCategory
    }
}

public struct ScanReport: Codable, Sendable {
    public var scannedAt: Date
    public var volume: VolumeSummary
    public var apfs: [APFSVolumeInfo]
    public var buckets: [Bucket]
    public var unaccountedBytes: Int64
    public var fullDiskAccess: Bool
    public var snapshots: [String]
    public var items: [Item]
    public var rootCauses: [RootCauseHint]
    public var warnings: [String]

    public init(
        scannedAt: Date, volume: VolumeSummary, apfs: [APFSVolumeInfo], buckets: [Bucket],
        unaccountedBytes: Int64, fullDiskAccess: Bool, snapshots: [String], items: [Item],
        rootCauses: [RootCauseHint], warnings: [String]
    ) {
        self.scannedAt = scannedAt; self.volume = volume; self.apfs = apfs; self.buckets = buckets
        self.unaccountedBytes = unaccountedBytes; self.fullDiskAccess = fullDiskAccess
        self.snapshots = snapshots; self.items = items; self.rootCauses = rootCauses; self.warnings = warnings
    }

    /// Sum of physical bytes of actionable items in a tier.
    public func tierTotal(_ tier: Tier) -> Int64 {
        items.filter { $0.tier == tier }.reduce(0) { $0 + $1.physicalBytes }
    }

    public static var jsonEncoder: JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }
    public static var jsonDecoder: JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }
}
