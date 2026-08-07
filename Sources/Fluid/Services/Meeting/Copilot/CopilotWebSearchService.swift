import Foundation

/// Grounded answers, via Gemini's native `google_search` tool.
///
/// This is the one copilot path that reaches the open internet, so it is
/// deliberately separate from `CopilotInsightEngine` rather than another branch
/// inside it: a reader can see exactly what leaves the machine and when.
///
/// Why its own request path: the app talks to Gemini through the
/// OpenAI-compatible endpoint (`/v1beta/openai`), and search grounding does not
/// exist there. It requires the native `generateContent` API, which speaks a
/// different request and response shape.
nonisolated struct CopilotWebSearchService: Sendable {
    struct Result: Sendable {
        let text: String
        let sources: [CopilotWebSource]
    }

    enum Failure: Error, Equatable {
        /// The configured provider has no grounded-search capability.
        case unsupportedProvider
        case emptyResponse
        case requestFailed(String)
    }

    private static let nativeBaseURL = "https://generativelanguage.googleapis.com/v1beta"

    let model: String
    let apiKey: String

    /// Grounded search is Gemini-only for now. Everything else must say so
    /// rather than quietly answering from model memory and looking like a
    /// search.
    static func isSupported(route: CopilotProviderRoute) -> Bool {
        route.baseURL.contains("generativelanguage.googleapis.com")
            && !route.apiKey.isEmpty
            && !route.model.isEmpty
    }

    static func make(route: CopilotProviderRoute) -> Self? {
        guard self.isSupported(route: route) else { return nil }
        // The OpenAI-compat layer prefixes model ids with "models/".
        let bareModel = route.model.hasPrefix("models/")
            ? String(route.model.dropFirst("models/".count))
            : route.model
        return Self(model: bareModel, apiKey: route.apiKey)
    }

    func search(systemPrompt: String, question: String) async throws -> Result {
        guard let url = URL(string: "\(Self.nativeBaseURL)/models/\(self.model):generateContent") else {
            throw Failure.requestFailed("Invalid Gemini endpoint")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(self.apiKey, forHTTPHeaderField: "x-goog-api-key")

        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": systemPrompt]]],
            "contents": [["role": "user", "parts": [["text": question]]]],
            "tools": [["google_search": [String: Any]()]],
            "generationConfig": ["temperature": 0.2, "maxOutputTokens": 700],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw Failure.requestFailed("Search failed (HTTP \(http.statusCode))")
        }

        return try Self.parse(data)
    }

    // MARK: - Parsing

    static func parse(_ data: Data) throws -> Result {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let candidate = candidates.first
        else { throw Failure.emptyResponse }

        let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        let text = parts
            .compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Failure.emptyResponse }

        return Result(text: text, sources: self.sources(from: candidate))
    }

    /// Extracts the pages behind the answer, deduplicated by URI.
    ///
    /// Sources are the point of grounded search: without them the user cannot
    /// tell a verified claim from a fluent guess.
    private static func sources(from candidate: [String: Any]) -> [CopilotWebSource] {
        guard let metadata = candidate["groundingMetadata"] as? [String: Any],
              let chunks = metadata["groundingChunks"] as? [[String: Any]]
        else { return [] }

        var seen = Set<String>()
        var sources: [CopilotWebSource] = []
        for chunk in chunks {
            guard let web = chunk["web"] as? [String: Any],
                  let uri = web["uri"] as? String,
                  !seen.contains(uri)
            else { continue }
            seen.insert(uri)
            sources.append(
                CopilotWebSource(uri: uri, title: web["title"] as? String ?? uri)
            )
        }
        return sources
    }
}
