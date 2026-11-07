import Foundation

public struct PlanEntry: Codable, Sendable, Identifiable, Hashable {
    public var id: String { item.id }
    public var item: Item
    public var selected: Bool
    public var commandPreview: String
    public init(item: Item, selected: Bool) {
        self.item = item; self.selected = selected; self.commandPreview = item.action.preview(path: item.path)
    }
}

/// Dry-run plan. Tier 1 is confirmed as a batch (pre-selected unless high rebuild cost); Tier 2/3 start unselected.
public struct Plan: Codable, Sendable, Hashable {
    public var entries: [PlanEntry]
    public init(entries: [PlanEntry]) { self.entries = entries }

    public static func build(from report: ScanReport, routineOnly: Bool, decisions: [String: Decision], now: Date = Date()) -> Plan {
        let items = report.items.filter { item in
            guard item.tier != .protected, item.action.isActionable else { return false }
            if let d = decisions[item.id], d.isActive(at: now) { return false }
            if routineOnly { return item.routine && item.tier == .safe }
            return true
        }
        let entries = items.sorted { ($0.tier, -$0.physicalBytes, $0.path) < ($1.tier, -$1.physicalBytes, $1.path) }.map { item in
            PlanEntry(item: item, selected: routineOnly ? true : (item.tier == .safe && item.defaultSelected))
        }
        return Plan(entries: entries)
    }

    public var selected: [PlanEntry] { entries.filter(\.selected) }
    public var expectedFreedBytes: Int64 { selected.filter { $0.item.action != .trash }.reduce(0) { $0 + $1.item.physicalBytes } }
    public var toTrashBytes: Int64 { selected.filter { $0.item.action == .trash }.reduce(0) { $0 + $1.item.physicalBytes } }
}
