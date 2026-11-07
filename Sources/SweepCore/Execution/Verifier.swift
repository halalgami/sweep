import Foundation

public struct Verification: Codable, Sendable, Hashable {
    public var expectedBytes: Int64
    public var trashedBytes: Int64
    public var freedNowBytes: Int64
    public var lagLikely: Bool
}

/// Compares expected vs actual freed space. APFS often reports freed space with a delay.
public enum Verifier {
    public static func verification(before: VolumeSummary, after: VolumeSummary, results: [ItemResult]) -> Verification {
        let expected = results.filter { [.removed, .partial].contains($0.status) }.reduce(0) { $0 + $1.expectedBytes }
        let trashed = results.filter { $0.status == .trashed }.reduce(0) { $0 + $1.expectedBytes }
        let freed = after.freeBytes - before.freeBytes
        return Verification(expectedBytes: expected, trashedBytes: trashed, freedNowBytes: freed,
                            lagLikely: expected > 0 && freed < expected / 2)
    }

    public static let recheckDelay: Duration = .seconds(60)
}
