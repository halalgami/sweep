import Foundation
import Testing
@testable import SweepCore

@Suite struct InsightsContractTests {
    let known: Set<String> = ["a1", "b2"]
    let valid = """
    {"headline":"uv cache regrew 30 GB","insights":[{"title":"uv churn","detail":"9 plugins use uvx @latest","evidenceItemIds":["a1"]}],
     "recommendations":[{"itemIds":["a1"],"action":"Prune weekly","expectedBytes":30000000000,"risk":"low","why":"regrows"}],
     "maintenanceSuggestions":["weekly uv cache prune"],"questionsForUser":["Still using the Windows VM?"]}
    """

    @Test func validResponsePasses() throws {
        let r = try InsightsContract.validate(valid, knownIDs: known).get()
        #expect(r.headline == "uv cache regrew 30 GB")
        #expect(r.recommendations.first?.itemIds == ["a1"])
    }

    @Test func fencedOrProseWrappedJSONPasses() throws {
        let wrapped = "Here you go:\n```json\n\(valid)\n```\nThanks"
        #expect(throws: Never.self) { try InsightsContract.validate(wrapped, knownIDs: known).get() }
    }

    @Test func unknownItemIDsRejected() {
        let bad = valid.replacingOccurrences(of: #""itemIds":["a1"]"#, with: #""itemIds":["a1","zzz"]"#)
        guard case let .failure(.unknownItemIDs(ids)) = InsightsContract.validate(bad, knownIDs: known) else { Issue.record("expected unknownItemIDs"); return }
        #expect(ids == ["zzz"])
    }

    @Test func unknownEvidenceIDsRejected() {
        let bad = valid.replacingOccurrences(of: #""evidenceItemIds":["a1"]"#, with: #""evidenceItemIds":["nope"]"#)
        guard case .failure(.unknownItemIDs) = InsightsContract.validate(bad, knownIDs: known) else { Issue.record("expected rejection"); return }
    }

    @Test func nonJSONRejected() {
        guard case .failure(.notJSON) = InsightsContract.validate("I think you should delete stuff.", knownIDs: known) else { Issue.record("expected notJSON"); return }
    }

    @Test func missingHeadlineRejected() {
        guard case .failure(.schema) = InsightsContract.validate(#"{"insights":[],"recommendations":[],"maintenanceSuggestions":[],"questionsForUser":[]}"#, knownIDs: known) else {
            Issue.record("expected schema error"); return
        }
    }

    @Test func tooManyRecommendationsRejected() {
        let recs = Array(repeating: #"{"itemIds":["a1"],"action":"x","expectedBytes":1,"risk":"low","why":"y"}"#, count: 11).joined(separator: ",")
        let s = #"{"headline":"h","insights":[],"recommendations":[\#(recs)],"maintenanceSuggestions":[],"questionsForUser":[]}"#
        guard case .failure(.schema) = InsightsContract.validate(s, knownIDs: known) else { Issue.record("expected schema"); return }
    }

    @Test func anthropicRequestBodyShape() throws {
        let body = try AnthropicProvider.requestBody(model: "claude-sonnet-5-5", system: "sys", user: "{}", withFallbacks: true)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "claude-sonnet-5-5")
        #expect(json["fallbacks"] as? String == "default")
        let format = (json["output_config"] as? [String: Any])?["format"] as? [String: Any]
        #expect(format?["type"] as? String == "json_schema")
        #expect(json["thinking"] == nil)
        #expect(json["temperature"] == nil)
    }

    @Test func anthropicResponseTextAndRefusal() throws {
        let ok = #"{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"{\"a\":1}"}],"stop_reason":"end_turn"}"#
        #expect(try AnthropicProvider.extractText(Data(ok.utf8)) == #"{"a":1}"#)
        let refusal = #"{"content":[],"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber"}}"#
        #expect(throws: InsightsError.self) { try AnthropicProvider.extractText(Data(refusal.utf8)) }
    }

    @Test func promptPayloadIsTheSummaryOnly() {
        let s = InsightsSummary(totalBytes: 1, freeBytes: 1, unaccountedBytes: 0, fullDiskAccess: true, buckets: [], items: [], rootCauses: [], priorDecisions: [:])
        #expect(InsightsPrompt.user(summary: s) == s.json())
    }
}
