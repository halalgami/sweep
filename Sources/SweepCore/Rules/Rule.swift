import Foundation

public enum RuleKind: String, Codable, Sendable, CaseIterable {
    case pathCache, toolCache, libraryCaches, docker, vscodeExtensions, projectArtifacts, gitWorktrees
    case simRuntimes, vms, largeFiles, installers, sensitiveData, llmModels, conda, texlive
    case leftovers, protectedPaths, xcodeOldDerivedData
}

public struct RuleAction: Codable, Sendable, Hashable {
    /// tool | hardDelete | trash | reveal | none
    public var type: String
    /// For `tool`: arguments passed to the rule's tool binary (never a shell string).
    public var command: [String]?
    public init(type: String, command: [String]? = nil) { self.type = type; self.command = command }
}

/// One detector rule from rules.json. Detector *kinds* hold the logic; rules parameterize them.
public struct Rule: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var tier: Tier
    public var kind: RuleKind
    public var paths: [String]?
    public var tool: String?
    public var action: RuleAction
    public var rebuildCost: RebuildCost
    public var rebuildHint: String?
    public var explanation: String
    public var routine: Bool?
    public var defaultSelected: Bool?
    /// Regexes matched against running command lines; if any match, the item is shown but not actionable.
    public var requiresNoProcess: [String]?
    /// Same, but phrased as "quit <app> first".
    public var requiresAppQuit: [String]?
    public var minBytes: Int64?
    public var params: [String: String]?

    public init(id: String, title: String, tier: Tier, kind: RuleKind, paths: [String]? = nil, tool: String? = nil,
                action: RuleAction, rebuildCost: RebuildCost, rebuildHint: String? = nil, explanation: String,
                routine: Bool? = nil, defaultSelected: Bool? = nil, requiresNoProcess: [String]? = nil,
                requiresAppQuit: [String]? = nil, minBytes: Int64? = nil, params: [String: String]? = nil) {
        self.id = id; self.title = title; self.tier = tier; self.kind = kind; self.paths = paths; self.tool = tool
        self.action = action; self.rebuildCost = rebuildCost; self.rebuildHint = rebuildHint
        self.explanation = explanation; self.routine = routine; self.defaultSelected = defaultSelected
        self.requiresNoProcess = requiresNoProcess; self.requiresAppQuit = requiresAppQuit
        self.minBytes = minBytes; self.params = params
    }

    public var isRoutine: Bool { routine == true }
    /// High-rebuild items are never pre-selected, regardless of what the rule says.
    public var selectedByDefault: Bool { rebuildCost == .high ? false : (defaultSelected ?? true) }
}
