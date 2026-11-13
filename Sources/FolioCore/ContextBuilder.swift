import Foundation

public struct OutlineEntry: Sendable, Equatable {
    public var title: String
    public var page: Int  // 1-based
    public var depth: Int

    public init(title: String, page: Int, depth: Int) {
        self.title = title
        self.page = page
        self.depth = depth
    }
}

/// Assembles the system prompt that grounds the model in the open PDF.
public struct ContextBuilder {
    public var documentTitle: String
    public var pages: [String]           // pages[i] = text of page i+1
    public var outline: [OutlineEntry]
    public var budgetChars: Int
    public var responseLanguage: String
    public var customPrompt: String

    public init(documentTitle: String, pages: [String], outline: [OutlineEntry], budgetChars: Int,
                responseLanguage: String, customPrompt: String) {
        self.documentTitle = documentTitle
        self.pages = pages
        self.outline = outline
        self.budgetChars = budgetChars
        self.responseLanguage = responseLanguage
        self.customPrompt = customPrompt
    }

    public var totalChars: Int { pages.reduce(0) { $0 + $1.count } }
    public var fitsWhole: Bool { totalChars <= budgetChars }

    static func pageBlock(_ n: Int, _ text: String) -> String {
        "[p.\(n)]\n\(text.trimmingCharacters(in: .whitespacesAndNewlines))\n"
    }

    /// - Parameters:
    ///   - currentPage: page the reader is looking at (1-based)
    ///   - relevantPages: pages ranked by relevance to the question (used only when the document doesn't fit)
    public func systemPrompt(currentPage: Int, relevantPages: [Int]) -> String {
        var s = """
        You are a reading assistant inside a PDF reader. The user is reading the document "\(documentTitle)" \
        (\(pages.count) pages). Answer questions about it accurately and concisely, grounded in the document text below. \
        When you use information from the document, cite the page as [p.N] (for example [p.12]) so the reader can jump there. \
        If the answer is not in the provided text, say so before using general knowledge. \
        Use Markdown; write math in LaTeX with $...$ or $$...$$. \
        Images the user attaches are usually figures or regions captured from this document. \
        Reply in \(responseLanguage) unless the user asks otherwise.

        """
        if !customPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            s += "\nAdditional instructions from the user:\n\(customPrompt)\n"
        }

        if !outline.isEmpty {
            s += "\n<table_of_contents>\n"
            for e in outline.prefix(400) {
                s += String(repeating: "  ", count: max(0, e.depth)) + "- \(e.title) [p.\(e.page)]\n"
            }
            s += "</table_of_contents>\n"
        }

        if fitsWhole {
            s += "\n<document>\n"
            for (i, t) in pages.enumerated() { s += Self.pageBlock(i + 1, t) }
            s += "</document>\n"
            return s
        }

        // Too long: include an excerpt around the current page plus the most relevant pages.
        var chosen: [Int] = []
        func add(_ p: Int) { if p >= 1, p <= pages.count, !chosen.contains(p) { chosen.append(p) } }
        add(currentPage)
        for d in 1...3 { add(currentPage - d); add(currentPage + d) }
        for p in relevantPages { add(p) }
        add(1)  // title/abstract page

        var used = 0
        var included: [Int] = []
        for p in chosen {
            let c = pages[p - 1].count
            if used + c > budgetChars { continue }
            used += c
            included.append(p)
        }
        included.sort()
        s += "\nThe document is too long to include in full. These excerpts were selected: pages "
        s += included.map(String.init).joined(separator: ", ")
        s += ". If you need other pages, tell the user which pages to look at.\n<document_excerpts>\n"
        for p in included { s += Self.pageBlock(p, pages[p - 1]) }
        s += "</document_excerpts>\n"
        return s
    }

    /// Short per-message context line.
    public static func messagePreamble(currentPage: Int, quoted: String?) -> String {
        var s = "(Currently viewing page \(currentPage).)\n"
        if let q = quoted?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty {
            s += "Selected passage:\n<quote>\n\(q)\n</quote>\n"
        }
        return s + "\n"
    }
}
