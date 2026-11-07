import CryptoKit
import Foundation

/// Risk tier of a finding. Lower is safer.
public enum Tier: Int, Codable, Sendable, CaseIterable, Comparable {
    case safe = 1
    case idleArtifact = 2
    case needsDecision = 3
    case protected = 4

    public static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .safe: "Safe to sweep"
        case .idleArtifact: "Idle build artifacts"
        case .needsDecision: "Needs your decision"
        case .protected: "Protected (shown for transparency)"
        }
    }
}

public enum RebuildCost: String, Codable, Sendable, CaseIterable {
    case none, low, medium, high
}

/// What an executor would do with an item. Never a shell string.
public enum ItemAction: Codable, Sendable, Hashable {
    case toolCommand(executable: String, arguments: [String])
    case hardDelete
    case trash
    case revealInFinder
    case gitWorktreeRemove(repo: String)
    case dockerCommand(arguments: [String])
    case none(reason: String)

    public var isActionable: Bool {
        switch self {
        case .none, .revealInFinder: false
        default: true
        }
    }

    /// Human-readable preview of exactly what will run.
    public func preview(path: String) -> String {
        func q(_ s: String) -> String { s.contains(" ") ? "'\(s)'" : s }
        switch self {
        case let .toolCommand(exe, args): return ([exe] + args).map(q).joined(separator: " ")
        case .hardDelete: return "delete permanently: \(path)"
        case .trash: return "move to Trash: \(path)"
        case .revealInFinder: return "reveal in Finder (remove it yourself): \(path)"
        case let .gitWorktreeRemove(repo): return "git -C \(q(repo)) worktree remove \(q(path))"
        case let .dockerCommand(args): return (["docker"] + args).map(q).joined(separator: " ")
        case let .none(reason): return "no action: \(reason)"
        }
    }
}

public struct Item: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var category: String
    public var title: String
    public var path: String
    public var logicalBytes: Int64
    public var physicalBytes: Int64
    public var lastModified: Date?
    public var lastUsedSignal: Date?
    public var tier: Tier
    public var action: ItemAction
    public var rebuildCost: RebuildCost
    public var rebuildHint: String?
    public var evidence: [String]
    public var routine: Bool
    public var defaultSelected: Bool
    public var sensitive: Bool

    public init(
        id: String, category: String, title: String, path: String,
        logicalBytes: Int64, physicalBytes: Int64, lastModified: Date?, lastUsedSignal: Date?,
        tier: Tier, action: ItemAction, rebuildCost: RebuildCost, rebuildHint: String?,
        evidence: [String], routine: Bool, defaultSelected: Bool, sensitive: Bool
    ) {
        self.id = id; self.category = category; self.title = title; self.path = path
        self.logicalBytes = logicalBytes; self.physicalBytes = physicalBytes
        self.lastModified = lastModified; self.lastUsedSignal = lastUsedSignal
        self.tier = tier; self.action = action; self.rebuildCost = rebuildCost
        self.rebuildHint = rebuildHint; self.evidence = evidence; self.routine = routine
        self.defaultSelected = defaultSelected; self.sensitive = sensitive
    }

    /// Stable id: first 16 hex chars of SHA256(category + "|" + key).
    public static func makeID(category: String, key: String) -> String {
        let digest = SHA256.hash(data: Data("\(category)|\(key)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }
}
