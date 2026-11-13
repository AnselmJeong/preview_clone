import Foundation

/// Any OpenAI-compatible Chat Completions endpoint. Defaults target ollama.com (cloud);
/// `http://localhost:11434/v1` works for a local Ollama.
public final class OpenAICompatibleProvider: ChatProvider, @unchecked Sendable {
    public let kind: ProviderKind = .ollama
    public var baseURL: URL
    public var apiKey: String?
    private let session: URLSession

    public init(baseURL: URL, apiKey: String?, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    private func request(_ path: String) -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        if let key = apiKey, !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    public func listModels() async throws -> [String] {
        let (data, response) = try await session.data(for: request("models"))
        if let err = httpError(response, body: String(decoding: data, as: UTF8.self)) { throw err }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { $0["id"] as? String }.sorted()
    }

    static func body(for request: ChatRequest) -> [String: Any] {
        var messages: [[String: Any]] = []
        if !request.system.isEmpty {
            messages.append(["role": "system", "content": request.system])
        }
        for turn in request.turns {
            if turn.images.isEmpty {
                messages.append(["role": turn.role.rawValue, "content": turn.text])
            } else {
                var parts: [[String: Any]] = [["type": "text", "text": turn.text]]
                for img in turn.images {
                    parts.append(["type": "image_url", "image_url": ["url": img.dataURL]])
                }
                messages.append(["role": turn.role.rawValue, "content": parts])
            }
        }
        return ["model": request.model, "messages": messages, "stream": true]
    }

    /// Extracts the content delta from one streamed chunk.
    static func parseChunk(_ json: String) -> (text: String?, usage: String?) {
        guard let obj = jsonObject(json) else { return (nil, nil) }
        var text: String?
        if let choices = obj["choices"] as? [[String: Any]], let first = choices.first,
           let delta = first["delta"] as? [String: Any], let content = delta["content"] as? String, !content.isEmpty {
            text = content
        }
        var usage: String?
        if let u = obj["usage"] as? [String: Any],
           let p = u["prompt_tokens"] as? Int, let c = u["completion_tokens"] as? Int {
            usage = "입력 \(p) · 출력 \(c) 토큰"
        }
        return (text, usage)
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        var req = self.request("chat/completions")
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.httpBody = try? JSONSerialization.data(withJSONObject: Self.body(for: request))
        req.timeoutInterval = 300
        let session = self.session

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: req)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        let body = await readBody(bytes)
                        throw httpError(response, body: body) ?? ProviderError("HTTP \(http.statusCode)")
                    }
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard let payload = sseData(line) else { continue }
                        if payload == "[DONE]" { break }
                        if let obj = jsonObject(payload), let err = obj["error"] {
                            let msg = (err as? [String: Any])?["message"] as? String ?? "\(err)"
                            throw ProviderError(msg)
                        }
                        let (text, usage) = Self.parseChunk(payload)
                        if let text { continuation.yield(.text(text)) }
                        if let usage { continuation.yield(.usage(usage)) }
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
