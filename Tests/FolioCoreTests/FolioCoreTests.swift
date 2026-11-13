import XCTest
@testable import FolioCore

final class StoreTests: XCTestCase {
    func makeStore() throws -> Store {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("folio-tests-\(UUID().uuidString)")
        return try Store(inMemoryWithAttachments: dir)
    }

    func fp(sha: String, pdfID: String? = nil, text: String? = nil, pages: Int = 10) -> DocumentFingerprint {
        DocumentFingerprint(sha256: sha, pdfID: pdfID, textFingerprint: text, pageCount: pages, fileSize: 100, fileMTime: 1)
    }

    func testResolveByHashThenPdfIDThenText() throws {
        let store = try makeStore()
        let a = try store.resolveDocument(fp(sha: "h1", pdfID: "id1", text: "t1"), path: "/a.pdf", title: "A")
        // Same bytes moved elsewhere.
        let moved = try store.resolveDocument(fp(sha: "h1", pdfID: "id1", text: "t1"), path: "/b/a.pdf", title: "A")
        XCTAssertEqual(a.id, moved.id)
        XCTAssertEqual(moved.lastPath, "/b/a.pdf")
        // Re-saved with highlights: new hash, same /ID.
        let saved = try store.resolveDocument(fp(sha: "h2", pdfID: "id1", text: "t1"), path: "/b/a.pdf", title: "A")
        XCTAssertEqual(a.id, saved.id)
        // Rewritten by another tool: new hash and /ID, same text.
        let rewritten = try store.resolveDocument(fp(sha: "h3", pdfID: "id9", text: "t1"), path: "/c.pdf", title: "A")
        XCTAssertEqual(a.id, rewritten.id)
        XCTAssertEqual(Set(try store.hashes(for: a.id)), ["h1", "h2", "h3"])
        // A different document.
        let other = try store.resolveDocument(fp(sha: "x", pdfID: "id2", text: "t2"), path: "/d.pdf", title: "D")
        XCTAssertNotEqual(a.id, other.id)
    }

    func testConversationsAndSearch() throws {
        let store = try makeStore()
        let doc = try store.resolveDocument(fp(sha: "h"), path: "/a.pdf", title: "Paper")
        let conv = ConversationRecord(documentID: doc.id, title: "질문", provider: "claudeCode", model: "sonnet")
        try store.save(conv)
        try store.save(MessageRecord(conversationID: conv.id, role: .user, content: "What is predictive coding?", pageRef: 3))
        try store.save(MessageRecord(conversationID: conv.id, role: .assistant, content: "It is a theory [p.3]."))
        XCTAssertEqual(try store.messages(conversationID: conv.id).count, 2)
        XCTAssertEqual(try store.conversations(documentID: doc.id).count, 1)
        let hits = try store.searchMessages("predictive")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.documentTitle, "Paper")
        try store.deleteConversation(id: conv.id)
        XCTAssertTrue(try store.conversations(documentID: doc.id).isEmpty)
        XCTAssertTrue(try store.searchMessages("predictive").isEmpty)
    }

    func testPageTextSearch() throws {
        let store = try makeStore()
        let doc = try store.resolveDocument(fp(sha: "h"), path: "/a.pdf", title: "Paper")
        try store.savePageText(documentID: doc.id, pages: ["intro text", "methods with bayesian inference", "results"])
        XCTAssertEqual(try store.searchPages(documentID: doc.id, query: "Bayesian?", limit: 3), [2])
        XCTAssertEqual(try store.pageText(documentID: doc.id).count, 3)
    }
}

final class IdentityTests: XCTestCase {
    func testTrailerID() {
        let tail = Data("xref\n0 1\ntrailer\n<< /Size 1 /ID [<AbCd1234EF> <00ff>] >>\nstartxref\n".utf8)
        XCTAssertEqual(DocumentIdentity.pdfTrailerID(inTail: tail), "abcd1234ef")
        XCTAssertNil(DocumentIdentity.pdfTrailerID(inTail: Data("/ID [<00000000>]".utf8)))
    }

    func testTextFingerprint() {
        XCTAssertNil(DocumentIdentity.textFingerprint(firstPages: ["short"], pageCount: 1))
        let long = String(repeating: "Lorem ipsum dolor ", count: 30)
        let a = DocumentIdentity.textFingerprint(firstPages: [long], pageCount: 5)
        let b = DocumentIdentity.textFingerprint(firstPages: [long.uppercased() + "  \n"], pageCount: 5)
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, DocumentIdentity.textFingerprint(firstPages: [long], pageCount: 6))
    }

    func testSHA256() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("folio-sha-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: url)
        XCTAssertEqual(try DocumentIdentity.sha256(of: url), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

final class ProviderParsingTests: XCTestCase {
    func testClaudeCodeParsing() {
        XCTAssertEqual(ClaudeCodeProvider.parseLine(#"{"type":"system","subtype":"init","session_id":"s1"}"#), .session("s1"))
        XCTAssertEqual(ClaudeCodeProvider.parseLine(#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}}"#), .delta("Hi"))
        XCTAssertEqual(ClaudeCodeProvider.parseLine(#"{"type":"assistant","message":{"content":[{"type":"text","text":"Hello"}]}}"#), .assistantText("Hello"))
        if case let .result(text, isError, sid, usage) = ClaudeCodeProvider.parseLine(#"{"type":"result","subtype":"success","is_error":false,"result":"Hello","session_id":"s1","usage":{"input_tokens":3,"output_tokens":5}}"#) {
            XCTAssertEqual(text, "Hello")
            XCTAssertFalse(isError)
            XCTAssertEqual(sid, "s1")
            XCTAssertEqual(usage, "입력 3 · 출력 5 토큰")
        } else {
            XCTFail("expected result")
        }
        XCTAssertEqual(ClaudeCodeProvider.parseLine("not json"), .ignored)
    }

    func testClaudeCodeUserLine() throws {
        let line = ClaudeCodeProvider.userMessageLine(text: "hi", images: [ChatImage(data: Data([1, 2]), mediaType: "image/png")])
        let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        XCTAssertEqual(obj["type"] as? String, "user")
        let content = (obj["message"] as! [String: Any])["content"] as! [[String: Any]]
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[0]["type"] as? String, "image")
        XCTAssertFalse(line.contains("\n"))
    }

    func testClaudeCodeArguments() {
        let p = ClaudeCodeProvider(executablePath: nil, extraArguments: [], workingDirectory: URL(fileURLWithPath: "/tmp"))
        let args = p.arguments(model: "sonnet", systemPromptFile: URL(fileURLWithPath: "/tmp/s.txt"), resume: "abc")
        XCTAssertTrue(args.contains("--resume"))
        XCTAssertEqual(args[args.firstIndex(of: "--tools")! + 1], "")
    }

    func testOpenAIChunk() {
        let (t, u) = OpenAICompatibleProvider.parseChunk(#"{"choices":[{"delta":{"content":"안녕"}}]}"#)
        XCTAssertEqual(t, "안녕")
        XCTAssertNil(u)
        XCTAssertEqual(sseData("data: [DONE]"), "[DONE]")
        XCTAssertNil(sseData("event: ping"))
    }

    func testOpenAIBodyWithImage() {
        let req = ChatRequest(system: "sys", turns: [ChatTurn(role: .user, text: "q", images: [ChatImage(data: Data([0]), mediaType: "image/png")])], model: "m")
        let body = OpenAICompatibleProvider.body(for: req)
        let messages = body["messages"] as! [[String: Any]]
        XCTAssertEqual(messages.count, 2)
        let parts = messages[1]["content"] as! [[String: Any]]
        XCTAssertEqual(parts[1]["type"] as? String, "image_url")
    }
}

final class ContextAndExportTests: XCTestCase {
    func testContextWholeAndExcerpt() {
        let pages = (1...20).map { "page \($0) " + String(repeating: "x", count: 100) }
        var b = ContextBuilder(documentTitle: "T", pages: pages, outline: [OutlineEntry(title: "Intro", page: 1, depth: 0)],
                               budgetChars: 100_000, responseLanguage: "한국어", customPrompt: "")
        let whole = b.systemPrompt(currentPage: 5, relevantPages: [])
        XCTAssertTrue(whole.contains("[p.20]"))
        XCTAssertTrue(whole.contains("<document>"))
        b.budgetChars = 1_000
        let excerpt = b.systemPrompt(currentPage: 10, relevantPages: [18])
        XCTAssertTrue(excerpt.contains("[p.10]"))
        XCTAssertFalse(excerpt.contains("[p.20]\n"))
        XCTAssertTrue(excerpt.contains("<document_excerpts>"))
    }

    func testMarkdownExport() {
        let conv = ConversationRecord(documentID: "d", title: "c", provider: "claudeCode", model: "sonnet")
        let msgs = [
            MessageRecord(conversationID: conv.id, role: .user, content: "Explain", quotedText: "line1\nline2", pageRef: 4,
                          attachments: [AttachmentRecord(filePath: "/x/a.png", mediaType: "image/png", page: 4)]),
            MessageRecord(conversationID: conv.id, role: .assistant, content: "Sure [p.4]"),
        ]
        let md = MarkdownExporter.render(title: "Paper \"X\"", sourcePath: "/p.pdf", sha256: "abc",
                                         conversations: [.init(record: conv, messages: msgs)]) { _ in "assets/a.png" }
        XCTAssertTrue(md.hasPrefix("---\ntitle: \"Paper \\\"X\\\"\""))
        XCTAssertTrue(md.contains("> line1\n> line2"))
        XCTAssertTrue(md.contains("![p.4 capture](assets/a.png)"))
        XCTAssertTrue(md.contains("## Assistant"))
    }
}
