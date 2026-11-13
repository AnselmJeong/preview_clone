import Foundation

/// Exports conversations to Markdown. Images are copied next to the file in `<name>_assets/`.
public enum MarkdownExporter {
    public struct Conversation {
        public var record: ConversationRecord
        public var messages: [MessageRecord]
        public init(record: ConversationRecord, messages: [MessageRecord]) {
            self.record = record
            self.messages = messages
        }
    }

    static let timestamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    static func yamlEscape(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Builds the Markdown text. `assetLink` maps an attachment to the relative link to use (nil = omit).
    public static func render(title: String, sourcePath: String?, sha256: String?,
                              conversations: [Conversation],
                              exportedAt: Date = Date(),
                              assetLink: (AttachmentRecord) -> String?) -> String {
        var out = "---\n"
        out += "title: \(yamlEscape(title))\n"
        if let sourcePath { out += "source: \(yamlEscape(sourcePath))\n" }
        if let sha256 { out += "sha256: \(sha256)\n" }
        out += "exported: \(ISO8601DateFormatter().string(from: exportedAt))\n"
        if conversations.count == 1, let c = conversations.first {
            out += "model: \(yamlEscape(c.record.provider + " / " + c.record.model))\n"
        }
        out += "---\n\n"

        let multiple = conversations.count > 1
        for c in conversations {
            if multiple {
                out += "# \(c.record.title)\n\n"
                out += "_\(c.record.provider) / \(c.record.model)_\n\n"
            }
            let h = multiple ? "###" : "##"
            for m in c.messages {
                let who = m.role == .user ? "User" : "Assistant"
                let when = timestamp.string(from: Date(timeIntervalSince1970: m.createdAt))
                out += "\(h) \(who) — \(when)\n\n"
                if let page = m.pageRef, m.role == .user {
                    out += "_p.\(page)_\n\n"
                }
                if let q = m.quotedText, !q.isEmpty {
                    out += q.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
                    out += "\n\n"
                }
                for a in m.attachments {
                    if let link = assetLink(a) {
                        let label = a.page.map { "p.\($0) capture" } ?? "image"
                        out += "![\(label)](\(link))\n\n"
                    }
                }
                out += m.content.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
            }
        }
        return out
    }

    /// Writes `fileURL` and copies attachments into `<basename>_assets/`.
    public static func export(to fileURL: URL, title: String, sourcePath: String?, sha256: String?,
                              conversations: [Conversation]) throws {
        let base = fileURL.deletingPathExtension().lastPathComponent
        let assetsName = "\(base)_assets"
        let assetsDir = fileURL.deletingLastPathComponent().appendingPathComponent(assetsName, isDirectory: true)
        let fm = FileManager.default
        var copied = false
        let text = render(title: title, sourcePath: sourcePath, sha256: sha256, conversations: conversations) { a in
            let src = URL(fileURLWithPath: a.filePath)
            guard fm.fileExists(atPath: src.path) else { return nil }
            if !copied {
                try? fm.createDirectory(at: assetsDir, withIntermediateDirectories: true)
                copied = true
            }
            let dst = assetsDir.appendingPathComponent(src.lastPathComponent)
            if !fm.fileExists(atPath: dst.path) { try? fm.copyItem(at: src, to: dst) }
            let encoded = assetsName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? assetsName
            return "\(encoded)/\(src.lastPathComponent)"
        }
        try text.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
