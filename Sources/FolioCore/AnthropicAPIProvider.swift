import Foundation

/// Claude Messages API with a Console API key (pay-as-you-go). Fallback when the Claude Code CLI is unavailable.
public final class AnthropicAPIProvider: ChatProvider, @unchecked Sendable {
    public let kind: ProviderKind = .anthropicAPI
    public var apiKey: String
    public var maxTokens: Int
    private let session: URLSession
    private let baseURL = URL(string: "https://api.anthropic.com/v1")!

    public static let defaultModels = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]

    public init(apiKey: String, maxTokens: Int = 8192, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.maxTokens = maxTokens
        self.session = session
    }

    private func request(_ path: String) -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        return req
    }

    public func listModels() async throws -> [String] {
        guard !apiKey.isEmpty else { return Self.defaultModels }
        do {
            let (data, response) = try await session.data(for: request("models"))
            if httpError(response, body: "") != nil { return Self.defaultModels }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = obj["data"] as? [[String: Any]] else { return Self.defaultModels }
            let ids = list.compactMap { $0["id"] as? String }
            return ids.isEmpty ? Self.defaultModels : ids
        } catch {
            return Self.defaultModels
        }
    }

    static func body(for request: ChatRequest, maxTokens: Int) -> [String: Any] {
        var messages: [[String: Any]] = []
        for turn in request.turns {
            var content: [[String: Any]] = []
            for img in turn.images {
                content.append(["type": "image",
                                "source": ["type": "base64", "media_type": img.mediaType, "data": img.base64]])
            }
            content.append(["type": "text", "text": turn.text.isEmpty ? " " : turn.text])
            messages.append(["role": turn.role.rawValue, "content": content])
        }
        var body: [String: Any] = [
            "model": request.model,
            "max_tokens": maxTokens,
            "stream": true,
            "messages": messages,
        ]
        if !request.system.isEmpty {
            // The system prompt carries the PDF text; cache it so follow-up questions are cheap.
            body["system"] = [["type": "text", "text": request.system, "cache_control": ["type": "ephemeral"]]]
        }
        return body
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        var req = self.request("messages")
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: Self.body(for: request, maxTokens: maxTokens))
        req.timeoutInterval = 600
        let session = self.session

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !self.apiKey.isEmpty else { throw ProviderError("설정에서 Claude API 키를 입력하세요.") }
                    let (bytes, response) = try await session.bytes(for: req)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        let body = await readBody(bytes)
                        throw httpError(response, body: body) ?? ProviderError("HTTP \(http.statusCode)")
                    }
                    var inputTokens = 0
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard let payload = sseData(line), let obj = jsonObject(payload),
                              let type = obj["type"] as? String else { continue }
                        switch type {
                        case "message_start":
                            if let msg = obj["message"] as? [String: Any], let u = msg["usage"] as? [String: Any] {
                                inputTokens = (u["input_tokens"] as? Int ?? 0)
                                    + (u["cache_read_input_tokens"] as? Int ?? 0)
                                    + (u["cache_creation_input_tokens"] as? Int ?? 0)
                            }
                        case "content_block_delta":
                            if let d = obj["delta"] as? [String: Any], d["type"] as? String == "text_delta",
                               let t = d["text"] as? String {
                                continuation.yield(.text(t))
                            }
                        case "message_delta":
                            if let u = obj["usage"] as? [String: Any], let out = u["output_tokens"] as? Int {
                                continuation.yield(.usage("입력 \(inputTokens) · 출력 \(out) 토큰"))
                            }
                        case "error":
                            let msg = (obj["error"] as? [String: Any])?["message"] as? String ?? "알 수 없는 오류"
                            throw ProviderError(msg)
                        default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
