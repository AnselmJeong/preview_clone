import Foundation

// MARK: - Records

public struct DocumentRecord: Equatable, Sendable {
    public var id: String
    public var title: String?
    public var pageCount: Int
    public var pdfID: String?
    public var textFingerprint: String?
    public var lastPath: String?
    public var fileSize: Int?
    public var fileMTime: Double?
    public var lastOpenedAt: Double?
    public var lastPage: Int?
    public var lastZoom: Double?
    public var displayMode: Int?
}

public struct ConversationRecord: Equatable, Sendable, Identifiable {
    public var id: String
    public var documentID: String
    public var title: String
    public var provider: String
    public var model: String
    public var cliSessionID: String?
    public var createdAt: Double
    public var updatedAt: Double

    public init(id: String = UUID().uuidString, documentID: String, title: String, provider: String,
                model: String, cliSessionID: String? = nil,
                createdAt: Double = Date().timeIntervalSince1970, updatedAt: Double = Date().timeIntervalSince1970) {
        self.id = id
        self.documentID = documentID
        self.title = title
        self.provider = provider
        self.model = model
        self.cliSessionID = cliSessionID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum ChatRole: String, Sendable, Codable {
    case user, assistant
}

public struct AttachmentRecord: Equatable, Sendable, Identifiable, Codable {
    public var id: String
    public var kind: String          // "image"
    public var filePath: String      // absolute path in the attachments folder
    public var mediaType: String     // image/png, image/jpeg
    public var page: Int?            // 1-based, when captured from the PDF

    public init(id: String = UUID().uuidString, kind: String = "image", filePath: String, mediaType: String, page: Int? = nil) {
        self.id = id
        self.kind = kind
        self.filePath = filePath
        self.mediaType = mediaType
        self.page = page
    }
}

public struct MessageRecord: Equatable, Sendable, Identifiable {
    public var id: String
    public var conversationID: String
    public var role: ChatRole
    public var content: String       // markdown
    public var quotedText: String?
    public var pageRef: Int?         // page the user was looking at (1-based)
    public var createdAt: Double
    public var attachments: [AttachmentRecord]
    public var isError: Bool

    public init(id: String = UUID().uuidString, conversationID: String, role: ChatRole, content: String,
                quotedText: String? = nil, pageRef: Int? = nil, createdAt: Double = Date().timeIntervalSince1970,
                attachments: [AttachmentRecord] = [], isError: Bool = false) {
        self.id = id
        self.conversationID = conversationID
        self.role = role
        self.content = content
        self.quotedText = quotedText
        self.pageRef = pageRef
        self.createdAt = createdAt
        self.attachments = attachments
        self.isError = isError
    }
}

public struct MessageSearchHit: Sendable, Identifiable {
    public var id: String { messageID }
    public var messageID: String
    public var conversationID: String
    public var conversationTitle: String
    public var documentID: String
    public var documentTitle: String?
    public var documentPath: String?
    public var snippet: String
}

// MARK: - Store

/// Persistent library: documents (by content identity), page text cache, conversations and messages.
public final class Store: @unchecked Sendable {
    public let db: Database
    public let attachmentsDirectory: URL

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        attachmentsDirectory = directory.appendingPathComponent("attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
        db = try Database(path: directory.appendingPathComponent("library.sqlite").path)
        try migrate()
    }

    /// In-memory store for tests.
    public init(inMemoryWithAttachments dir: URL) throws {
        attachmentsDirectory = dir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        db = try Database()
        try migrate()
    }

    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Folio", isDirectory: true)
    }

    private func migrate() throws {
        let version = try db.query("PRAGMA user_version;").first?["user_version"].int ?? 0
        if version < 1 {
            try db.execute("""
            CREATE TABLE IF NOT EXISTS documents(
                id TEXT PRIMARY KEY,
                title TEXT,
                page_count INTEGER NOT NULL DEFAULT 0,
                pdf_id TEXT,
                text_fp TEXT,
                last_path TEXT,
                file_size INTEGER,
                file_mtime REAL,
                last_opened_at REAL,
                last_page INTEGER,
                last_zoom REAL,
                display_mode INTEGER
            );
            CREATE INDEX IF NOT EXISTS documents_pdf_id ON documents(pdf_id);
            CREATE INDEX IF NOT EXISTS documents_text_fp ON documents(text_fp);
            CREATE INDEX IF NOT EXISTS documents_last_path ON documents(last_path);
            CREATE TABLE IF NOT EXISTS document_hashes(
                sha256 TEXT PRIMARY KEY,
                document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE
            );
            CREATE TABLE IF NOT EXISTS page_text(
                document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                page INTEGER NOT NULL,
                text TEXT NOT NULL,
                PRIMARY KEY(document_id, page)
            );
            CREATE VIRTUAL TABLE IF NOT EXISTS page_text_fts USING fts5(
                text, document_id UNINDEXED, page UNINDEXED, tokenize='unicode61'
            );
            CREATE TABLE IF NOT EXISTS conversations(
                id TEXT PRIMARY KEY,
                document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                title TEXT NOT NULL,
                provider TEXT NOT NULL,
                model TEXT NOT NULL,
                cli_session_id TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS conversations_doc ON conversations(document_id, updated_at);
            CREATE TABLE IF NOT EXISTS messages(
                id TEXT PRIMARY KEY,
                conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
                role TEXT NOT NULL,
                content_md TEXT NOT NULL,
                quoted_text TEXT,
                page_ref INTEGER,
                is_error INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS messages_conv ON messages(conversation_id, created_at);
            CREATE TABLE IF NOT EXISTS attachments(
                id TEXT PRIMARY KEY,
                message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
                kind TEXT NOT NULL,
                file_path TEXT NOT NULL,
                media_type TEXT NOT NULL,
                page INTEGER
            );
            CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
                content, message_id UNINDEXED, tokenize='unicode61'
            );
            PRAGMA user_version = 1;
            """)
        }
    }

    // MARK: Documents

    private func document(from row: Database.Row) -> DocumentRecord {
        DocumentRecord(
            id: row["id"].string ?? "",
            title: row["title"].string,
            pageCount: row["page_count"].int ?? 0,
            pdfID: row["pdf_id"].string,
            textFingerprint: row["text_fp"].string,
            lastPath: row["last_path"].string,
            fileSize: row["file_size"].int,
            fileMTime: row["file_mtime"].double,
            lastOpenedAt: row["last_opened_at"].double,
            lastPage: row["last_page"].int,
            lastZoom: row["last_zoom"].double,
            displayMode: row["display_mode"].int
        )
    }

    public func document(id: String) throws -> DocumentRecord? {
        try db.query("SELECT * FROM documents WHERE id = ?", [v(id)]).first.map(document(from:))
    }

    /// Fast path: same path, same size and modification time as last time.
    public func document(path: String, size: Int, mtime: Double) throws -> DocumentRecord? {
        try db.query("SELECT * FROM documents WHERE last_path = ? AND file_size = ? AND abs(file_mtime - ?) < 0.001 ORDER BY last_opened_at DESC LIMIT 1",
                     [v(path), v(size), v(mtime)]).first.map(document(from:))
    }

    public func document(sha256: String) throws -> DocumentRecord? {
        try db.query("SELECT d.* FROM documents d JOIN document_hashes h ON h.document_id = d.id WHERE h.sha256 = ?",
                     [v(sha256)]).first.map(document(from:))
    }

    public func document(pdfID: String) throws -> DocumentRecord? {
        try db.query("SELECT * FROM documents WHERE pdf_id = ? ORDER BY last_opened_at DESC LIMIT 1", [v(pdfID)]).first.map(document(from:))
    }

    public func document(textFingerprint: String) throws -> DocumentRecord? {
        try db.query("SELECT * FROM documents WHERE text_fp = ? ORDER BY last_opened_at DESC LIMIT 1", [v(textFingerprint)]).first.map(document(from:))
    }

    public func upsert(_ d: DocumentRecord) throws {
        try db.run("""
        INSERT INTO documents(id, title, page_count, pdf_id, text_fp, last_path, file_size, file_mtime, last_opened_at, last_page, last_zoom, display_mode)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
            title=excluded.title, page_count=excluded.page_count, pdf_id=excluded.pdf_id, text_fp=excluded.text_fp,
            last_path=excluded.last_path, file_size=excluded.file_size, file_mtime=excluded.file_mtime,
            last_opened_at=excluded.last_opened_at, last_page=excluded.last_page, last_zoom=excluded.last_zoom,
            display_mode=excluded.display_mode
        """, [v(d.id), v(d.title), v(d.pageCount), v(d.pdfID), v(d.textFingerprint), v(d.lastPath), v(d.fileSize),
              v(d.fileMTime), v(d.lastOpenedAt), v(d.lastPage), v(d.lastZoom), v(d.displayMode)])
    }

    public func addHash(_ sha256: String, to documentID: String) throws {
        try db.run("INSERT INTO document_hashes(sha256, document_id) VALUES(?, ?) ON CONFLICT(sha256) DO UPDATE SET document_id = excluded.document_id",
                   [v(sha256), v(documentID)])
    }

    public func hashes(for documentID: String) throws -> [String] {
        try db.query("SELECT sha256 FROM document_hashes WHERE document_id = ?", [v(documentID)]).compactMap { $0["sha256"].string }
    }

    public func saveReadingPosition(documentID: String, page: Int, zoom: Double?, displayMode: Int?) throws {
        try db.run("UPDATE documents SET last_page = ?, last_zoom = ?, display_mode = ? WHERE id = ?",
                   [v(page), v(zoom), v(displayMode), v(documentID)])
    }

    // MARK: Page text

    public func hasPageText(documentID: String) throws -> Bool {
        try !db.query("SELECT 1 FROM page_text WHERE document_id = ? LIMIT 1", [v(documentID)]).isEmpty
    }

    /// `pages[i]` is the text of page i+1.
    public func savePageText(documentID: String, pages: [String]) throws {
        try db.transaction {
            try db.run("DELETE FROM page_text WHERE document_id = ?", [v(documentID)])
            try db.run("DELETE FROM page_text_fts WHERE document_id = ?", [v(documentID)])
            for (i, text) in pages.enumerated() {
                try db.run("INSERT INTO page_text(document_id, page, text) VALUES(?,?,?)", [v(documentID), v(i + 1), v(text)])
                try db.run("INSERT INTO page_text_fts(text, document_id, page) VALUES(?,?,?)", [v(text), v(documentID), v(i + 1)])
            }
        }
    }

    public func pageText(documentID: String) throws -> [String] {
        try db.query("SELECT text FROM page_text WHERE document_id = ? ORDER BY page", [v(documentID)]).map { $0["text"].string ?? "" }
    }

    /// Pages (1-based) most relevant to `query`, best first.
    public func searchPages(documentID: String, query: String, limit: Int) throws -> [Int] {
        guard let match = Store.ftsQuery(query) else { return [] }
        return try db.query("SELECT page FROM page_text_fts WHERE page_text_fts MATCH ? AND document_id = ? ORDER BY bm25(page_text_fts) LIMIT ?",
                            [v(match), v(documentID), v(limit)]).compactMap { $0["page"].int }
    }

    /// Turns free text into a safe FTS5 OR-query of quoted terms.
    static func ftsQuery(_ text: String) -> String? {
        let terms = text
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
            .prefix(24)
            .map { "\"\($0)\"" }
        return terms.isEmpty ? nil : terms.joined(separator: " OR ")
    }

    // MARK: Conversations

    private func conversation(from row: Database.Row) -> ConversationRecord {
        ConversationRecord(
            id: row["id"].string ?? "",
            documentID: row["document_id"].string ?? "",
            title: row["title"].string ?? "",
            provider: row["provider"].string ?? "",
            model: row["model"].string ?? "",
            cliSessionID: row["cli_session_id"].string,
            createdAt: row["created_at"].double ?? 0,
            updatedAt: row["updated_at"].double ?? 0
        )
    }

    public func conversations(documentID: String) throws -> [ConversationRecord] {
        try db.query("SELECT * FROM conversations WHERE document_id = ? ORDER BY updated_at DESC", [v(documentID)]).map(conversation(from:))
    }

    public func conversation(id: String) throws -> ConversationRecord? {
        try db.query("SELECT * FROM conversations WHERE id = ?", [v(id)]).first.map(conversation(from:))
    }

    public func save(_ c: ConversationRecord) throws {
        try db.run("""
        INSERT INTO conversations(id, document_id, title, provider, model, cli_session_id, created_at, updated_at)
        VALUES(?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET title=excluded.title, provider=excluded.provider, model=excluded.model,
            cli_session_id=excluded.cli_session_id, updated_at=excluded.updated_at
        """, [v(c.id), v(c.documentID), v(c.title), v(c.provider), v(c.model), v(c.cliSessionID), v(c.createdAt), v(c.updatedAt)])
    }

    public func deleteConversation(id: String) throws {
        let messageIDs = try db.query("SELECT id FROM messages WHERE conversation_id = ?", [v(id)]).compactMap { $0["id"].string }
        let files = try db.query("SELECT a.file_path FROM attachments a JOIN messages m ON m.id = a.message_id WHERE m.conversation_id = ?",
                                 [v(id)]).compactMap { $0["file_path"].string }
        try db.transaction {
            for mid in messageIDs {
                try db.run("DELETE FROM messages_fts WHERE message_id = ?", [v(mid)])
            }
            try db.run("DELETE FROM conversations WHERE id = ?", [v(id)])
        }
        for f in files { try? FileManager.default.removeItem(atPath: f) }
    }

    // MARK: Messages

    public func messages(conversationID: String) throws -> [MessageRecord] {
        let rows = try db.query("SELECT * FROM messages WHERE conversation_id = ? ORDER BY created_at, rowid", [v(conversationID)])
        let attRows = try db.query("""
            SELECT a.* FROM attachments a JOIN messages m ON m.id = a.message_id WHERE m.conversation_id = ?
            """, [v(conversationID)])
        var byMessage: [String: [AttachmentRecord]] = [:]
        for r in attRows {
            let a = AttachmentRecord(id: r["id"].string ?? "", kind: r["kind"].string ?? "image",
                                     filePath: r["file_path"].string ?? "", mediaType: r["media_type"].string ?? "image/png",
                                     page: r["page"].int)
            byMessage[r["message_id"].string ?? "", default: []].append(a)
        }
        return rows.map { r in
            let id = r["id"].string ?? ""
            return MessageRecord(id: id, conversationID: conversationID,
                                 role: ChatRole(rawValue: r["role"].string ?? "user") ?? .user,
                                 content: r["content_md"].string ?? "",
                                 quotedText: r["quoted_text"].string,
                                 pageRef: r["page_ref"].int,
                                 createdAt: r["created_at"].double ?? 0,
                                 attachments: byMessage[id] ?? [],
                                 isError: (r["is_error"].int ?? 0) != 0)
        }
    }

    public func save(_ m: MessageRecord) throws {
        try db.transaction {
            try db.run("""
            INSERT INTO messages(id, conversation_id, role, content_md, quoted_text, page_ref, is_error, created_at)
            VALUES(?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET content_md=excluded.content_md, is_error=excluded.is_error
            """, [v(m.id), v(m.conversationID), v(m.role.rawValue), v(m.content), v(m.quotedText), v(m.pageRef),
                  v(Int(m.isError ? 1 : 0)), v(m.createdAt)])
            for a in m.attachments {
                try db.run("INSERT OR IGNORE INTO attachments(id, message_id, kind, file_path, media_type, page) VALUES(?,?,?,?,?,?)",
                           [v(a.id), v(m.id), v(a.kind), v(a.filePath), v(a.mediaType), v(a.page)])
            }
            try db.run("DELETE FROM messages_fts WHERE message_id = ?", [v(m.id)])
            let indexed = [m.quotedText, m.content].compactMap { $0 }.joined(separator: "\n")
            try db.run("INSERT INTO messages_fts(content, message_id) VALUES(?, ?)", [v(indexed), v(m.id)])
            try db.run("UPDATE conversations SET updated_at = ? WHERE id = ?", [v(m.createdAt), v(m.conversationID)])
        }
    }

    public func deleteMessage(id: String) throws {
        let files = try db.query("SELECT file_path FROM attachments WHERE message_id = ?", [v(id)]).compactMap { $0["file_path"].string }
        try db.transaction {
            try db.run("DELETE FROM messages_fts WHERE message_id = ?", [v(id)])
            try db.run("DELETE FROM messages WHERE id = ?", [v(id)])
        }
        for f in files { try? FileManager.default.removeItem(atPath: f) }
    }

    /// Full-text search over all conversations of all documents.
    public func searchMessages(_ text: String, limit: Int = 100) throws -> [MessageSearchHit] {
        guard let match = Store.ftsQuery(text) else { return [] }
        let rows = try db.query("""
            SELECT m.id AS message_id, c.id AS conversation_id, c.title AS conversation_title,
                   d.id AS document_id, d.title AS document_title, d.last_path AS document_path,
                   snippet(messages_fts, 0, '«', '»', '…', 16) AS snippet
            FROM messages_fts
            JOIN messages m ON m.id = messages_fts.message_id
            JOIN conversations c ON c.id = m.conversation_id
            JOIN documents d ON d.id = c.document_id
            WHERE messages_fts MATCH ?
            ORDER BY bm25(messages_fts)
            LIMIT ?
            """, [v(match), v(limit)])
        return rows.map { r in
            MessageSearchHit(messageID: r["message_id"].string ?? "",
                             conversationID: r["conversation_id"].string ?? "",
                             conversationTitle: r["conversation_title"].string ?? "",
                             documentID: r["document_id"].string ?? "",
                             documentTitle: r["document_title"].string,
                             documentPath: r["document_path"].string,
                             snippet: r["snippet"].string ?? "")
        }
    }

    // MARK: Attachments

    /// Stores image bytes under the attachments folder and returns the record (not yet linked to a message).
    public func storeAttachment(data: Data, mediaType: String, page: Int?) throws -> AttachmentRecord {
        let ext = mediaType == "image/jpeg" ? "jpg" : "png"
        let id = UUID().uuidString
        let url = attachmentsDirectory.appendingPathComponent("\(id).\(ext)")
        try data.write(to: url, options: .atomic)
        return AttachmentRecord(id: id, filePath: url.path, mediaType: mediaType, page: page)
    }
}
