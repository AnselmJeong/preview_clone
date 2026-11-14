import Foundation
import Testing
@testable import FolioCore

@Suite struct StoreTests {
    func makeStore() throws -> Store {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("folio-tests-\(UUID().uuidString)")
        return try Store(inMemoryWithAttachments: dir)
    }

    func fp(sha: String, pdfID: String? = nil, text: String? = nil, pages: Int = 10) -> DocumentFingerprint {
        DocumentFingerprint(sha256: sha, pdfID: pdfID, textFingerprint: text, pageCount: pages, fileSize: 100, fileMTime: 1)
    }

    @Test func resolveByHashThenPdfIDThenText() throws {
        let store = try makeStore()
        let a = try store.resolveDocument(fp(sha: "h1", pdfID: "id1", text: "t1"), path: "/a.pdf", title: "A")
        // Same bytes moved elsewhere.
        let moved = try store.resolveDocument(fp(sha: "h1", pdfID: "id1", text: "t1"), path: "/b/a.pdf", title: "A")
        #expect(a.id == moved.id)
        #expect(moved.lastPath == "/b/a.pdf")
        // Re-saved with highlights: new hash, same /ID.
        let saved = try store.resolveDocument(fp(sha: "h2", pdfID: "id1", text: "t1"), path: "/b/a.pdf", title: "A")
        #expect(a.id == saved.id)
        // Rewritten by another tool: new hash and /ID, same text.
        let rewritten = try store.resolveDocument(fp(sha: "h3", pdfID: "id9", text: "t1"), path: "/c.pdf", title: "A")
        #expect(a.id == rewritten.id)
        #expect(Set(try store.hashes(for: a.id)) == ["h1", "h2", "h3"])
        // A different document.
        let other = try store.resolveDocument(fp(sha: "x", pdfID: "id2", text: "t2"), path: "/d.pdf", title: "D")
        #expect(a.id != other.id)
    }

    @Test func conversationsAndSearch() throws {
        let store = try makeStore()
        let doc = try store.resolveDocument(fp(sha: "h"), path: "/a.pdf", title: "Paper")
        let conv = ConversationRecord(documentID: doc.id, title: "질문", provider: "claudeCode", model: "sonnet")
        try store.save(conv)
        try store.save(MessageRecord(conversationID: conv.id, role: .user, content: "What is predictive coding?", pageRef: 3))
        try store.save(MessageRecord(conversationID: conv.id, role: .assistant, content: "It is a theory [p.3]."))
        #expect(try store.messages(conversationID: conv.id).count == 2)
        #expect(try store.conversations(documentID: doc.id).count == 1)
        let hits = try store.searchMessages("predictive")
        #expect(hits.count == 1)
        #expect(hits.first?.documentTitle == "Paper")
        try store.deleteConversation(id: conv.id)
        #expect(try store.conversations(documentID: doc.id).isEmpty)
        #expect(try store.searchMessages("predictive").isEmpty)
    }

    @Test func pageTextSearch() throws {
        let store = try makeStore()
        let doc = try store.resolveDocument(fp(sha: "h"), path: "/a.pdf", title: "Paper")
        try store.savePageText(documentID: doc.id, pages: ["intro text", "methods with bayesian inference", "results"])
        #expect(try store.searchPages(documentID: doc.id, query: "Bayesian?", limit: 3) == [2])
        #expect(try store.pageText(documentID: doc.id).count == 3)
    }
}

@Suite struct IdentityTests {
    @Test func trailerID() {
        let tail = Data("xref\n0 1\ntrailer\n<< /Size 1 /ID [<AbCd1234EF> <00ff>] >>\nstartxref\n".utf8)
        #expect(DocumentIdentity.pdfTrailerID(inTail: tail) == "abcd1234ef")
        #expect(DocumentIdentity.pdfTrailerID(inTail: Data("/ID [<00000000>]".utf8)) == nil)
    }

    @Test func textFingerprint() {
        #expect(DocumentIdentity.textFingerprint(firstPages: ["short"], pageCount: 1) == nil)
        let long = String(repeating: "Lorem ipsum dolor ", count: 30)
        let a = DocumentIdentity.textFingerprint(firstPages: [long], pageCount: 5)
        let b = DocumentIdentity.textFingerprint(firstPages: [long.uppercased() + "  \n"], pageCount: 5)
        #expect(a != nil)
        #expect(a == b)
        #expect(a != DocumentIdentity.textFingerprint(firstPages: [long], pageCount: 6))
    }

    @Test func sha256() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("folio-sha-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: url)
        #expect(try DocumentIdentity.sha256(of: url) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

@Suite struct ProviderParsingTests {
    @Test func claudeCodeParsing() {
        #expect(ClaudeCodeProvider.parseLine(#"{"type":"system","subtype":"init","session_id":"s1"}"#) == .session("s1"))
        #expect(ClaudeCodeProvider.parseLine(#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}}"#) == .delta("Hi"))
        #expect(ClaudeCodeProvider.parseLine(#"{"type":"assistant","message":{"content":[{"type":"text","text":"Hello"}]}}"#) == .assistantText("Hello"))
        if case let .result(text, isError, sid, usage) = ClaudeCodeProvider.parseLine(#"{"type":"result","subtype":"success","is_error":false,"result":"Hello","session_id":"s1","usage":{"input_tokens":3,"output_tokens":5}}"#) {
            #expect(text == "Hello")
            #expect(!(isError))
            #expect(sid == "s1")
            #expect(usage == "입력 3 · 출력 5 토큰")
        } else {
            Issue.record("expected result")
        }
        #expect(ClaudeCodeProvider.parseLine("not json") == .ignored)
    }

    @Test func claudeCodeUserLine() throws {
        let line = ClaudeCodeProvider.userMessageLine(text: "hi", images: [ChatImage(data: Data([1, 2]), mediaType: "image/png")])
        let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        #expect(obj["type"] as? String == "user")
        let content = (obj["message"] as! [String: Any])["content"] as! [[String: Any]]
        #expect(content.count == 2)
        #expect(content[0]["type"] as? String == "image")
        #expect(!(line.contains("\n")))
    }

    @Test func claudeCodeArguments() {
        let p = ClaudeCodeProvider(executablePath: nil, extraArguments: [], workingDirectory: URL(fileURLWithPath: "/tmp"))
        let args = p.arguments(model: "sonnet", systemPromptFile: URL(fileURLWithPath: "/tmp/s.txt"), resume: "abc")
        #expect(args.contains("--resume"))
        #expect(args[args.firstIndex(of: "--tools")! + 1] == "")
    }

    @Test func openAIChunk() {
        let (t, u) = OpenAICompatibleProvider.parseChunk(#"{"choices":[{"delta":{"content":"안녕"}}]}"#)
        #expect(t == "안녕")
        #expect(u == nil)
        #expect(sseData("data: [DONE]") == "[DONE]")
        #expect(sseData("event: ping") == nil)
    }

    @Test func openAIBodyWithImage() {
        let req = ChatRequest(system: "sys", turns: [ChatTurn(role: .user, text: "q", images: [ChatImage(data: Data([0]), mediaType: "image/png")])], model: "m")
        let body = OpenAICompatibleProvider.body(for: req)
        let messages = body["messages"] as! [[String: Any]]
        #expect(messages.count == 2)
        let parts = messages[1]["content"] as! [[String: Any]]
        #expect(parts[1]["type"] as? String == "image_url")
    }
}

@Suite struct ContextAndExportTests {
    @Test func contextWholeAndExcerpt() {
        let pages = (1...20).map { "page \($0) " + String(repeating: "x", count: 100) }
        var b = ContextBuilder(documentTitle: "T", pages: pages, outline: [OutlineEntry(title: "Intro", page: 1, depth: 0)],
                               budgetChars: 100_000, responseLanguage: "한국어", customPrompt: "")
        let whole = b.systemPrompt(currentPage: 5, relevantPages: [])
        #expect(whole.contains("[p.20]"))
        #expect(whole.contains("<document>"))
        b.budgetChars = 1_000
        let excerpt = b.systemPrompt(currentPage: 10, relevantPages: [18])
        #expect(excerpt.contains("[p.10]"))
        #expect(!(excerpt.contains("[p.20]\n")))
        #expect(excerpt.contains("<document_excerpts>"))
    }

    @Test func markdownExport() {
        let conv = ConversationRecord(documentID: "d", title: "c", provider: "claudeCode", model: "sonnet")
        let msgs = [
            MessageRecord(conversationID: conv.id, role: .user, content: "Explain", quotedText: "line1\nline2", pageRef: 4,
                          attachments: [AttachmentRecord(filePath: "/x/a.png", mediaType: "image/png", page: 4)]),
            MessageRecord(conversationID: conv.id, role: .assistant, content: "Sure [p.4]"),
        ]
        let md = MarkdownExporter.render(title: "Paper \"X\"", sourcePath: "/p.pdf", sha256: "abc",
                                         conversations: [.init(record: conv, messages: msgs)]) { _ in "assets/a.png" }
        #expect(md.hasPrefix("---\ntitle: \"Paper \\\"X\\\"\""))
        #expect(md.contains("> line1\n> line2"))
        #expect(md.contains("![p.4 capture](assets/a.png)"))
        #expect(md.contains("## Assistant"))
    }
}

@Suite struct ClaudeAuthTests {
    @Test func parsesStatusJSON() {
        let out = """
        {
          "loggedIn": true,
          "authMethod": "claude.ai",
          "apiProvider": "firstParty",
          "email": "me@example.com",
          "subscriptionType": "max"
        }
        """
        let s = ClaudeAuthStatus.parse(out)
        #expect(s?.loggedIn == true)
        #expect(s?.email == "me@example.com")
        #expect(s?.summary == "me@example.com · Max")
        #expect(ClaudeAuthStatus.parse("{\"loggedIn\": false}")?.loggedIn == false)
        #expect(ClaudeAuthStatus.parse("Not logged in") == nil)
        #expect(ClaudeAuthStatus(loggedIn: true, authMethod: "oauth_token").summary == "Claude 구독")
    }

    @Test func readsLoginTerminalOutput() {
        let link = "https://claude.com/cai/oauth/authorize?code=true&client_id=abc&state=xyz"
        let raw = "Opening browser to sign in…\r\nIf the browser didn't open, visit: \u{1B}]8;;\(link)\u{07}\u{1B}[94m\(link)\u{1B}[39m\u{1B}]8;;\u{07}\r\nPaste code here if prompted > "
        let cleaned = ClaudeLoginOutput.clean(raw)
        #expect(!cleaned.contains("\u{1B}"))
        #expect(ClaudeLoginOutput.signInURL(in: cleaned)?.absoluteString == link)
        #expect(ClaudeLoginOutput.asksForCode(cleaned))
        #expect(ClaudeLoginOutput.reportsSuccess("Login successful."))
    }
}
