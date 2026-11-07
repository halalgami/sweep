import Foundation

public protocol InsightsProvider: Sendable {
    func complete(system: String, user: String) async throws -> String
}

/// Claude via the Messages API (raw HTTP; there is no official Swift SDK).
public struct AnthropicProvider: InsightsProvider {
    public static let defaultModel = "claude-sonnet-5-5"
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let apiVersion = "2026-10-21"
    public static let fallbackBeta = "server-side-fallback-2026-07-01"

    public let apiKey: String
    public let model: String
    public let session: URLSession

    public init(apiKey: String, model: String = AnthropicProvider.defaultModel, session: URLSession = .shared) {
        self.apiKey = apiKey; self.model = model; self.session = session
    }

    static func requestBody(model: String, system: String, user: String, withFallbacks: Bool) throws -> Data {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "system": system,
            "messages": [["role": "user", "content": user]],
            "output_config": ["effort": "medium", "format": ["type": "json_schema", "schema": InsightsContract.jsonSchema]],
        ]
        if withFallbacks { body["fallbacks"] = "default" }
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// Joins text blocks; skips thinking blocks; turns refusals and truncation into errors.
    static func extractText(_ data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw InsightsError.notJSON }
        let stop = json["stop_reason"] as? String
        if stop == "refusal" {
            let cat = (json["stop_details"] as? [String: Any])?["category"] as? String ?? "policy"
            throw InsightsError.refused(cat)
        }
        if stop == "max_tokens" { throw InsightsError.schema("answer was cut off") }
        let blocks = json["content"] as? [[String: Any]] ?? []
        return blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
    }

    public func complete(system: String, user: String) async throws -> String {
        do { return try await send(system: system, user: user, withFallbacks: true) }
        catch let InsightsError.http(code, msg) where code == 400 && msg.lowercased().contains("fallback") {
            return try await send(system: system, user: user, withFallbacks: false)
        }
    }

    func send(system: String, user: String, withFallbacks: Bool) async throws -> String {
        var req = URLRequest(url: Self.endpoint, timeoutInterval: 180)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        if withFallbacks { req.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta") }
        req.httpBody = try Self.requestBody(model: model, system: system, user: user, withFallbacks: withFallbacks)
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await session.data(for: req) } catch { throw InsightsError.transport(error.localizedDescription) }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let msg = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any])?["message"] as? String
            throw InsightsError.http(code, msg ?? String(decoding: data.prefix(300), as: UTF8.self))
        }
        return try Self.extractText(data)
    }
}

/// A local model through Ollama's native chat API (nothing leaves the Mac).
public struct OllamaProvider: InsightsProvider {
    public let baseURL: URL
    public let model: String
    public init(baseURL: URL = URL(string: "http://127.0.0.1:11434")!, model: String) { self.baseURL = baseURL; self.model = model }

    public func complete(system: String, user: String) async throws -> String {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/chat"), timeoutInterval: 600)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "stream": false, "format": InsightsContract.jsonSchema,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ] as [String: Any])
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await URLSession.shared.data(for: req) } catch { throw InsightsError.transport(error.localizedDescription) }
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg = (json["message"] as? [String: Any])?["content"] as? String else {
            throw InsightsError.http((resp as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data.prefix(300), as: UTF8.self))
        }
        return msg
    }
}

/// End-to-end: summary → provider → validated response. Failures never throw past here.
public enum InsightsService {
    public static func run(summary: InsightsSummary, provider: InsightsProvider) async -> Result<InsightsResponse, InsightsError> {
        do {
            let raw = try await provider.complete(system: InsightsPrompt.system, user: InsightsPrompt.user(summary: summary))
            return InsightsContract.validate(raw, knownIDs: Set(summary.items.map(\.id)))
        } catch let e as InsightsError { return .failure(e) }
        catch { return .failure(.transport(error.localizedDescription)) }
    }
}
