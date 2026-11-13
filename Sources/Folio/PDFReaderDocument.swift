import AppKit
import PDFKit
import FolioCore

/// One open PDF. Highlights are written back into the file as standard PDF annotations
/// (autosaved in place, like Preview), so other apps see them too.
@objc(PDFReaderDocument)
final class PDFReaderDocument: NSDocument {
    private(set) var pdf: PDFDocument?
    private var reloadWork: DispatchWorkItem?

    override class var autosavesInPlace: Bool { true }
    override class var readableTypes: [String] { ["com.adobe.pdf"] }
    override class var writableTypes: [String] { ["com.adobe.pdf"] }
    override class func isNativeType(_ type: String) -> Bool { type == "com.adobe.pdf" }

    var readerController: ReaderWindowController? {
        windowControllers.first as? ReaderWindowController
    }

    override func makeWindowControllers() {
        addWindowController(ReaderWindowController())
    }

    override func read(from url: URL, ofType typeName: String) throws {
        guard let doc = PDFDocument(url: url) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError,
                          userInfo: [NSLocalizedDescriptionKey: "PDF를 열 수 없습니다: \(url.lastPathComponent)"])
        }
        pdf = doc
    }

    override func data(ofType typeName: String) throws -> Data {
        guard let data = pdf?.dataRepresentation() else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                          userInfo: [NSLocalizedDescriptionKey: "PDF를 저장할 수 없습니다."])
        }
        return data
    }

    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                       completionHandler: @escaping (Error?) -> Void) {
        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
            completionHandler(error)
            if error == nil { self?.readerController?.documentDidSave() }
        }
    }

    // MARK: External changes (e.g. LaTeX recompiles the PDF)

    override func presentedItemDidChange() {
        // Not calling super: we reload ourselves (keeping the current page) instead of
        // NSDocument's revert, and only when there are no unsaved highlights.
        DispatchQueue.main.async { [weak self] in self?.scheduleReload() }
    }

    private func scheduleReload() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reloadFromDisk(attempt: 0) }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func reloadFromDisk(attempt: Int) {
        guard let url = fileURL, !isDocumentEdited else { return }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let mdate = attrs?[.modificationDate] as? Date else { return }
        if let known = fileModificationDate, abs(known.timeIntervalSince(mdate)) < 0.001 { return }
        guard let doc = PDFDocument(url: url), doc.pageCount > 0 else {
            // Probably still being written; try again shortly.
            if attempt < 5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.reloadFromDisk(attempt: attempt + 1) }
            }
            return
        }
        fileModificationDate = mdate
        pdf = doc
        readerController?.documentReloaded(doc)
    }

    /// Called by the window controller when it swaps in an unlocked/replaced document.
    func replacePDF(_ doc: PDFDocument) {
        pdf = doc
    }
}
