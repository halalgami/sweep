import Foundation

public protocol InsightsProvider: Sendable {
    /// Returns the model's raw answer, which must follow `schema`.
    func complete(system: String, user: String, schema: [String: Any]) async throws -> String
}

public extension InsightsProvider {
    func complete(system: String, user: String) async throws -> String {
        try await complete(system: system, user: user, schema: InsightsContract.jsonSchema)
    }
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

    static func requestBody(model: String, system: String, user: String, schema: [String: Any] = InsightsContract.jsonSchema,
                            withFallbacks: Bool) throws -> Data {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "system": system,
            "messages": [["role": "user", "content": user]],
            "output_config": ["effort": "medium", "format": ["type": "json_schema", "schema": schema]],
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

    public func complete(system: String, user: String, schema: [String: Any]) async throws -> String {
        do { return try await send(system: system, user: user, schema: schema, withFallbacks: true) }
        catch let InsightsError.http(code, msg) where code == 400 && msg.lowercased().contains("fallback") {
            return try await send(system: system, user: user, schema: schema, withFallbacks: false)
        }
    }

    func send(system: String, user: String, schema: [String: Any], withFallbacks: Bool) async throws -> String {
        var req = URLRequest(url: Self.endpoint, timeoutInterval: 180)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        if withFallbacks { req.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta") }
        req.httpBody = try Self.requestBody(model: model, system: system, user: user, schema: schema, withFallbacks: withFallbacks)
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

/// Which AI explains the scan. Raw values are what Settings stores ("claude" is the 0.1.0 name for the API provider).
public enum InsightsProviderKind: String, CaseIterable, Identifiable, Sendable {
    case claudeCode, ollama, anthropicAPI = "claude"
    public var id: String { rawValue }
    public static let `default`: InsightsProviderKind = .claudeCode

    public init?(cliName: String) {
        switch cliName.lowercased() {
        case "claude-code", "claudecode", "cc": self = .claudeCode
        case "ollama", "local": self = .ollama
        case "anthropic", "api", "anthropic-api": self = .anthropicAPI
        default: return nil
        }
    }

    public var title: String {
        switch self {
        case .claudeCode: "Claude Code (your Claude account)"
        case .ollama: "Ollama (local model, stays on this Mac)"
        case .anthropicAPI: "Anthropic API (API key)"
        }
    }

    /// Whether the redacted summary stays on this Mac.
    public var isLocal: Bool { self == .ollama }
}

/// A local model through Ollama's native chat API (nothing leaves the Mac).
public struct OllamaProvider: InsightsProvider {
    public static let defaultBaseURL = URL(string: "http://127.0.0.1:11434")!
    public let baseURL: URL
    public let model: String
    public init(baseURL: URL = OllamaProvider.defaultBaseURL, model: String) { self.baseURL = baseURL; self.model = model }

    /// Model names from `GET /api/tags`.
    static func parseTags(_ data: Data) throws -> [String] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { throw InsightsError.notJSON }
        return models.compactMap { $0["name"] as? String }
    }

    /// Installed models, or an error if Ollama isn't running.
    public static func installedModels(baseURL: URL = OllamaProvider.defaultBaseURL) async throws -> [String] {
        let req = URLRequest(url: baseURL.appendingPathComponent("api/tags"), timeoutInterval: 5)
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw InsightsError.transport("Ollama isn't running at \(baseURL.absoluteString). Open the Ollama app or run `ollama serve`.") }
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw InsightsError.http((resp as? HTTPURLResponse)?.statusCode ?? 0, "Ollama /api/tags") }
        return try parseTags(data)
    }

    public func complete(system: String, user: String, schema: [String: Any]) async throws -> String {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/chat"), timeoutInterval: 600)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "stream": false, "format": schema, "options": ["temperature": 0.2],
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
            let known = Set(summary.items.map(\.id))
            let raw = try await provider.complete(system: InsightsPrompt.system, user: InsightsPrompt.user(summary: summary),
                                                  schema: InsightsContract.jsonSchema(knownIDs: known))
            return InsightsContract.validate(raw, knownIDs: known)
        } catch let e as InsightsError { return .failure(e) }
        catch { return .failure(.transport(error.localizedDescription)) }
    }
}
