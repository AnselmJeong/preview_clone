import Foundation
import CryptoKit

/// Content-based identity for a PDF, so history follows the file when it is moved, copied,
/// or re-saved with highlights.
public struct DocumentFingerprint: Equatable, Sendable {
    public var sha256: String
    public var pdfID: String?
    public var textFingerprint: String?
    public var pageCount: Int
    public var fileSize: Int
    public var fileMTime: Double

    public init(sha256: String, pdfID: String?, textFingerprint: String?, pageCount: Int, fileSize: Int, fileMTime: Double) {
        self.sha256 = sha256
        self.pdfID = pdfID
        self.textFingerprint = textFingerprint
        self.pageCount = pageCount
        self.fileSize = fileSize
        self.fileMTime = fileMTime
    }
}

public enum DocumentIdentity {
    /// Streams the file through SHA-256 (constant memory).
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func fileAttributes(of url: URL) -> (size: Int, mtime: Double) {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return (size, mtime)
    }

    /// First element of the trailer `/ID` array, read from the tail of the file.
    /// Works for classic trailers and for cross-reference stream dictionaries (which are not compressed).
    public static func pdfTrailerID(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let tail: UInt64 = 256 * 1024
        let start = size > tail ? size - tail : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        return pdfTrailerID(inTail: data)
    }

    static func pdfTrailerID(inTail data: Data) -> String? {
        // Replace non-ASCII bytes so binary stream content cannot break decoding.
        let text = String(decoding: data.map { $0 < 0x80 ? $0 : 0x3F }, as: UTF8.self)
        let pattern = #"/ID\s*\[\s*<([0-9A-Fa-f\s]+)>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.matches(in: text, range: range).last,
              let r = Range(match.range(at: 1), in: text) else { return nil }
        let hex = text[r].filter { !$0.isWhitespace }.lowercased()
        // Ignore degenerate IDs (all zeros or too short), which some generators emit.
        if hex.count < 8 || hex.allSatisfy({ $0 == "0" }) { return nil }
        return hex
    }

    /// Hash of normalized text of the first pages plus the page count. `nil` for (near) text-less PDFs,
    /// where it would not discriminate between documents.
    public static func textFingerprint(firstPages: [String], pageCount: Int) -> String? {
        let normalized = firstPages.joined(separator: "\n")
            .lowercased()
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        let s = String(String.UnicodeScalarView(normalized))
        guard s.count >= 200 else { return nil }
        let digest = SHA256.hash(data: Data("\(pageCount)|\(s)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public extension Store {
    /// Finds the document for a fingerprint (exact hash → PDF /ID → text fingerprint) or creates one,
    /// then records the current hash, path, and file attributes.
    func resolveDocument(_ fp: DocumentFingerprint, path: String, title: String?) throws -> DocumentRecord {
        var record: DocumentRecord?
        record = try document(sha256: fp.sha256)
        if record == nil, let pid = fp.pdfID {
            if let candidate = try document(pdfID: pid), candidate.pageCount == fp.pageCount || fp.textFingerprint == nil
                || candidate.textFingerprint == fp.textFingerprint {
                record = candidate
            }
        }
        if record == nil, let tfp = fp.textFingerprint {
            record = try document(textFingerprint: tfp)
        }
        var doc = record ?? DocumentRecord(id: UUID().uuidString, title: title, pageCount: fp.pageCount)
        doc.title = title ?? doc.title
        doc.pageCount = fp.pageCount
        doc.pdfID = fp.pdfID ?? doc.pdfID
        doc.textFingerprint = fp.textFingerprint ?? doc.textFingerprint
        doc.lastPath = path
        doc.fileSize = fp.fileSize
        doc.fileMTime = fp.fileMTime
        doc.lastOpenedAt = Date().timeIntervalSince1970
        try upsert(doc)
        try addHash(fp.sha256, to: doc.id)
        return doc
    }
}
