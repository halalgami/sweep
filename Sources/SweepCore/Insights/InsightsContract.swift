import Foundation

public struct InsightsResponse: Codable, Sendable, Hashable {
    public struct Insight: Codable, Sendable, Hashable { public var title: String; public var detail: String; public var evidenceItemIds: [String] }
    public struct Recommendation: Codable, Sendable, Hashable {
        public var itemIds: [String]; public var action: String; public var expectedBytes: Int64; public var risk: String; public var why: String
    }
    public var headline: String
    public var insights: [Insight]
    public var recommendations: [Recommendation]
    public var maintenanceSuggestions: [String]
    public var questionsForUser: [String]
}

public enum InsightsError: Error, Hashable, CustomStringConvertible {
    case notJSON, schema(String), unknownItemIDs([String]), refused(String), http(Int, String), transport(String), notConfigured
    public var description: String {
        switch self {
        case .notJSON: "The AI didn't return JSON"
        case let .schema(s): "The AI's answer didn't match the expected format (\(s))"
        case let .unknownItemIDs(ids): "The AI referred to items that aren't in your scan (\(ids.joined(separator: ", "))), so its answer was discarded"
        case let .refused(c): "The AI declined to answer (\(c))"
        case let .http(code, msg): "The AI service returned \(code): \(msg)"
        case let .transport(s): "Couldn't reach the AI service: \(s)"
        case .notConfigured: "Insights aren't set up. Add an API key in Settings."
        }
    }
}

/// Validates the LLM output. Anything referencing unknown item IDs is rejected wholesale.
/// Note: the UI never shows `expectedBytes`; byte totals are always computed by the app from item IDs.
public enum InsightsContract {
    public static let maxRecommendations = 10

    public static func validate(_ raw: String, knownIDs: Set<String>) -> Result<InsightsResponse, InsightsError> {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end else { return .failure(.notJSON) }
        let data = Data(raw[start...end].utf8)
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else { return .failure(.notJSON) }
        let r: InsightsResponse
        do { r = try JSONDecoder().decode(InsightsResponse.self, from: data) } catch { return .failure(.schema("\(error)")) }
        if r.headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .failure(.schema("empty headline")) }
        if r.recommendations.count > maxRecommendations { return .failure(.schema("too many recommendations")) }
        let referenced = r.recommendations.flatMap(\.itemIds) + r.insights.flatMap(\.evidenceItemIds)
        let unknown = referenced.filter { !knownIDs.contains($0) }
        if !unknown.isEmpty { return .failure(.unknownItemIDs(Array(NSOrderedSet(array: unknown)) as? [String] ?? unknown)) }
        return .success(r)
    }

    /// JSON schema sent as `output_config.format` (strict objects).
    public static var jsonSchema: [String: Any] {
        func obj(_ props: [String: Any]) -> [String: Any] {
            ["type": "object", "properties": props, "required": Array(props.keys).sorted(), "additionalProperties": false]
        }
        let strings: [String: Any] = ["type": "array", "items": ["type": "string"]]
        return obj([
            "headline": ["type": "string"],
            "insights": ["type": "array", "items": obj(["title": ["type": "string"], "detail": ["type": "string"], "evidenceItemIds": strings])],
            "recommendations": ["type": "array", "items": obj([
                "itemIds": strings, "action": ["type": "string"], "expectedBytes": ["type": "integer"],
                "risk": ["type": "string", "enum": ["low", "medium", "high"]], "why": ["type": "string"]])],
            "maintenanceSuggestions": strings,
            "questionsForUser": strings,
        ])
    }
}

public enum InsightsPrompt {
    public static let system = """
    You help a developer understand where their Mac's disk space went. You receive a JSON summary of a disk scan that \
    was produced by deterministic code. Explain it in plain, friendly, non-alarmist language and rank what to do.

    Rules:
    - Only reference item ids that appear in the input's `items`. Never invent ids.
    - Don't do arithmetic for the user: the app shows its own byte totals. Use `expectedBytes` only to echo an item's physicalBytes.
    - You never delete anything and never run commands; you only suggest. Prefer the tool's own cleanup and regenerable caches.
    - Use root-cause hints (e.g. MCP servers using `@latest`) to explain regrowth and suggest maintenance that fixes the cause.
    - Respect prior decisions: if the user declined an item several times, don't push it again; ask instead if useful.
    - Paths are redacted on purpose (project_NN, [redacted]); don't ask for real names.
    - Keep `headline` under 90 characters. At most 6 insights and 10 recommendations.
    """

    public static func user(summary: InsightsSummary) -> String { summary.json() }
}
