import Foundation

public struct ChatImage: Sendable, Equatable {
    public var data: Data
    public var mediaType: String  // image/png | image/jpeg

    public init(data: Data, mediaType: String) {
        self.data = data
        self.mediaType = mediaType
    }

    public var base64: String { data.base64EncodedString() }
    public var dataURL: String { "data:\(mediaType);base64,\(base64)" }
}

public struct ChatTurn: Sendable, Equatable {
    public var role: ChatRole
    public var text: String
    public var images: [ChatImage]

    public init(role: ChatRole, text: String, images: [ChatImage] = []) {
        self.role = role
        self.text = text
        self.images = images
    }
}

public struct ChatRequest: Sendable {
    public var system: String
    /// Full conversation, oldest first; the last turn is the new user message.
    public var turns: [ChatTurn]
    public var model: String
    /// Claude Code session to resume (Claude Code provider only).
    public var resumeSessionID: String?

    public init(system: String, turns: [ChatTurn], model: String, resumeSessionID: String? = nil) {
        self.system = system
        self.turns = turns
        self.model = model
        self.resumeSessionID = resumeSessionID
    }
}

public enum ChatEvent: Sendable, Equatable {
    case text(String)
    case sessionID(String)
    case usage(String)
}

public struct ProviderError: LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum ProviderKind: String, CaseIterable, Sendable, Identifiable {
    case claudeCode
    case ollama
    case anthropicAPI

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude (구독 · Claude Code)"
        case .ollama: return "Ollama (OpenAI 호환)"
        case .anthropicAPI: return "Claude API 키"
        }
    }

    public var shortName: String {
        switch self {
        case .claudeCode: return "Claude"
        case .ollama: return "Ollama"
        case .anthropicAPI: return "Claude API"
        }
    }
}

public protocol ChatProvider: AnyObject, Sendable {
    var kind: ProviderKind { get }
    func listModels() async throws -> [String]
    /// Streams the assistant's reply. Cancelling the consuming task cancels the request.
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error>
}

/// Formats earlier turns as plain text, for providers that cannot replay real history.
public func transcriptPreamble(_ turns: [ChatTurn]) -> String {
    guard !turns.isEmpty else { return "" }
    var s = "<previous_conversation>\n"
    for t in turns {
        s += t.role == .user ? "User: " : "Assistant: "
        s += t.text
        if !t.images.isEmpty { s += "\n[\(t.images.count) image(s) attached earlier]" }
        s += "\n\n"
    }
    s += "</previous_conversation>\n\n"
    return s
}

/// Parses a server-sent-events `data:` line. Returns nil for non-data lines.
public func sseData(_ line: String) -> String? {
    guard line.hasPrefix("data:") else { return nil }
    var payload = line.dropFirst(5)
    if payload.first == " " { payload = payload.dropFirst() }
    return String(payload)
}

func jsonObject(_ s: String) -> [String: Any]? {
    guard let data = s.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

func httpError(_ response: URLResponse, body: String) -> ProviderError? {
    guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return nil }
    var detail = body
    if let obj = jsonObject(body) {
        if let err = obj["error"] as? [String: Any], let msg = err["message"] as? String { detail = msg }
        else if let msg = obj["error"] as? String { detail = msg }
    }
    return ProviderError("HTTP \(http.statusCode): \(detail.prefix(500))")
}

func readBody(_ bytes: URLSession.AsyncBytes) async -> String {
    var data = Data()
    do {
        for try await b in bytes {
            data.append(b)
            if data.count > 64 * 1024 { break }
        }
    } catch {}
    return String(decoding: data, as: UTF8.self)
}
