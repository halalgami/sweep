import Foundation

public enum DecisionKind: String, Codable, Sendable { case keep, neverAsk }

/// "Keep" (expires, default 90 days) or "Never ask" (no expiry) for one item.
public struct Decision: Codable, Sendable, Hashable {
    public var itemID: String
    public var kind: DecisionKind
    public var createdAt: Date
    public var expiresAt: Date?

    public init(itemID: String, kind: DecisionKind, createdAt: Date, expiresAt: Date?) {
        self.itemID = itemID; self.kind = kind; self.createdAt = createdAt; self.expiresAt = expiresAt
    }

    public static func keep(_ itemID: String, now: Date = Date(), days: Int = 90) -> Decision {
        Decision(itemID: itemID, kind: .keep, createdAt: now, expiresAt: now.addingTimeInterval(TimeInterval(days) * 86400))
    }
    public static func neverAsk(_ itemID: String, now: Date = Date()) -> Decision {
        Decision(itemID: itemID, kind: .neverAsk, createdAt: now, expiresAt: nil)
    }

    public func isActive(at now: Date) -> Bool { expiresAt.map { $0 > now } ?? true }
}
