import Foundation

/// Uses the user's own, unmodified `claude` CLI (Claude Code) in headless mode, signed in with their
/// Claude subscription. The app never reads, stores, or forwards Claude credentials: sign-in happens
/// entirely in the CLI's own flow (`claude` → /login, or `claude auth login`).
public final class ClaudeCodeProvider: ChatProvider, @unchecked Sendable {
    public let kind: ProviderKind = .claudeCode
    public var executablePath: String?
    public var extraArguments: [String]
    public let workingDirectory: URL

    public static let modelAliases = ["sonnet", "opus", "haiku"]

    public init(executablePath: String?, extraArguments: [String], workingDirectory: URL) {
        self.executablePath = executablePath
        self.extraArguments = extraArguments
        self.workingDirectory = workingDirectory
    }

    public func listModels() async throws -> [String] { Self.modelAliases }

    // MARK: Locating the CLI

    public static let candidatePaths: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.bun/bin/claude",
        ]
    }()

    /// Finds `claude`: explicit setting, well-known locations, then the login shell's PATH.
    public static func locate(preferred: String?) -> String? {
        let fm = FileManager.default
        if let p = preferred, !p.isEmpty, fm.isExecutableFile(atPath: p) { return p }
        for p in candidatePaths where fm.isExecutableFile(atPath: p) { return p }
        // GUI apps don't inherit the shell PATH; ask a login shell once.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", "command -v claude"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty, fm.isExecutableFile(atPath: path) { return path }
        } catch {}
        return nil
    }

    // MARK: Building the invocation

    func arguments(model: String, systemPromptFile: URL, resume: String?) -> [String] {
        var args = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--model", model,
            "--system-prompt-file", systemPromptFile.path,
            // Reading a PDF needs no tools: no file edits, no shell, no MCP servers.
            "--tools", "",
            "--disallowedTools", "mcp__*",
            "--strict-mcp-config",
        ]
        if let resume { args += ["--resume", resume] }
        args += extraArguments
        return args
    }

    /// One stream-json user message line.
    static func userMessageLine(text: String, images: [ChatImage]) -> String {
        var content: [[String: Any]] = images.map {
            ["type": "image", "source": ["type": "base64", "media_type": $0.mediaType, "data": $0.base64]]
        }
        content.append(["type": "text", "text": text.isEmpty ? " " : text])
        let msg: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
        let data = (try? JSONSerialization.data(withJSONObject: msg)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Parsing output

    enum OutputEvent: Equatable {
        case session(String)
        case delta(String)
        case assistantText(String)
        case result(text: String?, isError: Bool, sessionID: String?, usage: String?)
        case ignored
    }

    static func parseLine(_ line: String) -> OutputEvent {
        guard let obj = jsonObject(line), let type = obj["type"] as? String else { return .ignored }
        switch type {
        case "system":
            if obj["subtype"] as? String == "init", let sid = obj["session_id"] as? String { return .session(sid) }
        case "stream_event":
            if let ev = obj["event"] as? [String: Any], ev["type"] as? String == "content_block_delta",
               let d = ev["delta"] as? [String: Any], d["type"] as? String == "text_delta", let t = d["text"] as? String {
                return .delta(t)
            }
        case "assistant":
            if let msg = obj["message"] as? [String: Any], let content = msg["content"] as? [[String: Any]] {
                let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
                if !text.isEmpty { return .assistantText(text) }
            }
        case "result":
            var usage: String?
            if let u = obj["usage"] as? [String: Any] {
                let inTok = (u["input_tokens"] as? Int ?? 0) + (u["cache_read_input_tokens"] as? Int ?? 0)
                    + (u["cache_creation_input_tokens"] as? Int ?? 0)
                let outTok = u["output_tokens"] as? Int ?? 0
                usage = "입력 \(inTok) · 출력 \(outTok) 토큰"
            }
            let isError = (obj["is_error"] as? Bool ?? false) || ((obj["subtype"] as? String).map { $0 != "success" } ?? false)
            var text = obj["result"] as? String
            if text == nil, let errors = obj["errors"] as? [String] { text = errors.joined(separator: "\n") }
            return .result(text: text, isError: isError, sessionID: obj["session_id"] as? String, usage: usage)
        default:
            break
        }
        return .ignored
    }

    // MARK: Streaming

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(request, resume: request.resumeSessionID, continuation: continuation)
                    continuation.finish()
                } catch let error as ResumeFailed {
                    _ = error
                    // The CLI no longer has that session: start over, replaying history as text.
                    do {
                        try await self.run(request, resume: nil, continuation: continuation)
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct ResumeFailed: Error {}

    private func run(_ request: ChatRequest, resume: String?,
                     continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation) async throws {
        guard let exe = Self.locate(preferred: executablePath) else {
            throw ProviderError("Claude Code(`claude`)를 찾을 수 없습니다. 터미널에서 설치하고 `claude`를 실행해 로그인한 뒤, 필요하면 설정에서 경로를 지정하세요.")
        }
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let promptFile = FileManager.default.temporaryDirectory.appendingPathComponent("folio-system-\(UUID().uuidString).txt")
        try request.system.write(to: promptFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: promptFile) }

        guard let last = request.turns.last else { return }
        var text = last.text
        if resume == nil, request.turns.count > 1 {
            text = transcriptPreamble(Array(request.turns.dropLast())) + text
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = arguments(model: request.model, systemPromptFile: promptFile, resume: resume)
        proc.currentDirectoryURL = workingDirectory
        var env = ProcessInfo.processInfo.environment
        let exeDir = (exe as NSString).deletingLastPathComponent
        env["PATH"] = [exeDir, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", env["PATH"] ?? ""].joined(separator: ":")
        proc.environment = env

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        let stderrBuffer = LockedData()
        stderr.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { stderrBuffer.append(d) }
        }

        try proc.run()
        let line = Self.userMessageLine(text: text, images: last.images) + "\n"
        stdin.fileHandleForWriting.write(Data(line.utf8))
        try? stdin.fileHandleForWriting.close()

        var sawDelta = false
        var emittedAny = false
        var finalResult: OutputEvent?

        do {
            try await withTaskCancellationHandler {
                for try await outLine in stdout.fileHandleForReading.bytes.lines {
                    switch Self.parseLine(outLine) {
                    case .session(let sid):
                        continuation.yield(.sessionID(sid))
                    case .delta(let t):
                        sawDelta = true
                        emittedAny = true
                        continuation.yield(.text(t))
                    case .assistantText(let t):
                        if !sawDelta {
                            emittedAny = true
                            continuation.yield(.text(t))
                        }
                    case let .result(text, isError, sid, usage):
                        finalResult = .result(text: text, isError: isError, sessionID: sid, usage: usage)
                        if let sid { continuation.yield(.sessionID(sid)) }
                        if let usage { continuation.yield(.usage(usage)) }
                        if !isError, !emittedAny, let text, !text.isEmpty {
                            continuation.yield(.text(text))
                        }
                    case .ignored:
                        break
                    }
                }
            } onCancel: {
                if proc.isRunning { proc.terminate() }
            }
        }
        proc.waitUntilExit()
        stderr.fileHandleForReading.readabilityHandler = nil
        try Task.checkCancellation()

        let errText = String(decoding: stderrBuffer.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if case let .result(text, isError, _, _)? = finalResult, isError {
            let msg = [text, errText].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
            if resume != nil, !emittedAny, msg.localizedCaseInsensitiveContains("session") || msg.localizedCaseInsensitiveContains("conversation") {
                throw ResumeFailed()
            }
            throw ProviderError(Self.friendly(msg))
        }
        if finalResult == nil {
            if resume != nil, !emittedAny, errText.localizedCaseInsensitiveContains("session") || errText.localizedCaseInsensitiveContains("conversation") {
                throw ResumeFailed()
            }
            throw ProviderError(Self.friendly(errText.isEmpty ? "Claude Code가 응답 없이 종료되었습니다 (코드 \(proc.terminationStatus))." : errText))
        }
    }

    static func friendly(_ msg: String) -> String {
        let lower = msg.lowercased()
        if lower.contains("login") || lower.contains("log in") || lower.contains("not authenticated") || lower.contains("oauth") {
            return "Claude Code 로그인이 필요합니다. 터미널에서 `claude`를 실행해 로그인하세요.\n\n\(msg)"
        }
        if lower.contains("limit") {
            return "Claude 사용 한도에 도달했습니다.\n\n\(msg)"
        }
        return msg
    }
}

final class LockedData: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()
    func append(_ d: Data) { lock.lock(); buffer.append(d); lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return buffer }
}
