import AppKit
import PDFKit
import SwiftUI
import FolioCore

/// Builds a view the first time it is needed, so hidden sidebars cost nothing at launch.
final class LazyHostingViewController: NSViewController {
    private let make: () -> NSView
    private(set) var isLoaded = false

    init(make: @escaping () -> NSView) {
        self.make = make
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView()
    }

    func ensureLoaded() {
        guard !isLoaded else { return }
        isLoaded = true
        let content = make()
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.topAnchor.constraint(equalTo: view.topAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}

private extension NSToolbarItem.Identifier {
    static let leftSidebar = NSToolbarItem.Identifier("folio.leftSidebar")
    static let displayMode = NSToolbarItem.Identifier("folio.displayMode")
    static let zoomOut = NSToolbarItem.Identifier("folio.zoomOut")
    static let zoomIn = NSToolbarItem.Identifier("folio.zoomIn")
    static let highlight = NSToolbarItem.Identifier("folio.highlight")
    static let capture = NSToolbarItem.Identifier("folio.capture")
    static let search = NSToolbarItem.Identifier("folio.search")
    static let ai = NSToolbarItem.Identifier("folio.ai")
}

private enum Defaults {
    static let leftOpen = "ui.leftSidebarOpen"
    static let aiOpen = "ui.aiSidebarOpen"
    static let displayMode = "view.displayMode"
    static let nightMode = "view.nightMode"
}

@MainActor
final class ReaderWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSSearchFieldDelegate,
    NSMenuItemValidation, ReaderPDFViewDelegate, PDFDocumentDelegate {

    let pdfView = ReaderPDFView()
    let sidebarModel = SidebarModel()
    private(set) lazy var chatModel = ChatViewModel(host: self)

    private let splitVC = NSSplitViewController()
    private var leftItem: NSSplitViewItem!
    private var aiItem: NSSplitViewItem!
    private var leftVC: LazyHostingViewController!
    private var chatVC: LazyHostingViewController!
    private weak var searchField: NSSearchField?

    private(set) var documentRecord: DocumentRecord?
    private(set) var currentSHA: String?
    private var didRestorePosition = false
    private var positionSaveWork: DispatchWorkItem?
    private var pendingConversationID: String?
    private var configured = false

    // Find state
    private var pendingHits: [PDFSelection] = []
    private var hits: [PDFSelection] = []

    var readerDocument: PDFReaderDocument? { document as? PDFReaderDocument }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.minSize = NSSize(width: 520, height: 400)
        window.toolbarStyle = .unified
        window.tabbingMode = .preferred
        super.init(window: window)
        window.delegate = self
        buildLayout()
        buildToolbar()
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged(_:)), name: .PDFViewPageChanged, object: pdfView)
        NotificationCenter.default.addObserver(self, selector: #selector(scaleChanged(_:)), name: .PDFViewScaleChanged, object: pdfView)
        NotificationCenter.default.addObserver(self, selector: #selector(openConversationRequested(_:)), name: .folioOpenConversation, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var document: AnyObject? {
        didSet {
            if document != nil, !configured { configureForDocument() }
        }
    }

    // MARK: - Layout

    private func buildLayout() {
        pdfView.autoScales = true
        pdfView.displaysPageBreaks = true
        pdfView.displayMode = PDFDisplayMode(rawValue: UserDefaults.standard.integer(forKey: Defaults.displayMode)) ?? .singlePageContinuous
        if UserDefaults.standard.object(forKey: Defaults.displayMode) == nil { pdfView.displayMode = .singlePageContinuous }
        pdfView.readerDelegate = self
        pdfView.nightMode = UserDefaults.standard.bool(forKey: Defaults.nightMode)
        sidebarModel.pdfView = pdfView
        sidebarModel.onSelectTOC = { [weak self] node in self?.go(to: node) }
        sidebarModel.onSelectHighlight = { [weak self] item in self?.go(to: item) }
        sidebarModel.onSelectHit = { [weak self] index in self?.selectHit(index) }

        leftVC = LazyHostingViewController { [unowned self] in
            NSHostingView(rootView: LeftSidebarView(model: self.sidebarModel))
        }
        leftItem = NSSplitViewItem(sidebarWithViewController: leftVC)
        leftItem.minimumThickness = 180
        leftItem.maximumThickness = 420
        leftItem.canCollapse = true
        leftItem.isCollapsed = !UserDefaults.standard.bool(forKey: Defaults.leftOpen)

        let viewerVC = NSViewController()
        viewerVC.view = pdfView
        let viewerItem = NSSplitViewItem(viewController: viewerVC)
        viewerItem.minimumThickness = 300
        viewerItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: 249)

        chatVC = LazyHostingViewController { [unowned self] in
            NSHostingView(rootView: ChatSidebarView(model: self.chatModel))
        }
        aiItem = NSSplitViewItem(inspectorWithViewController: chatVC)
        aiItem.minimumThickness = 280
        aiItem.maximumThickness = 1000
        aiItem.canCollapse = true
        aiItem.isCollapsed = !UserDefaults.standard.bool(forKey: Defaults.aiOpen)

        splitVC.addSplitViewItem(leftItem)
        splitVC.addSplitViewItem(viewerItem)
        splitVC.addSplitViewItem(aiItem)
        splitVC.splitView.autosaveName = "FolioMainSplit"

        if !leftItem.isCollapsed { leftVC.ensureLoaded() }
        if !aiItem.isCollapsed { chatVC.ensureLoaded() }

        window?.contentViewController = splitVC
        window?.setContentSize(NSSize(width: 1100, height: 820))
        windowFrameAutosaveName = "FolioReaderWindow"
    }

    private func buildToolbar() {
        let toolbar = NSToolbar(identifier: "FolioToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window?.toolbar = toolbar
    }

    // MARK: - Document

    private func configureForDocument() {
        guard let doc = readerDocument?.pdf else { return }
        configured = true
        if doc.isLocked && !unlock(doc) {
            DispatchQueue.main.async { [weak self] in self?.readerDocument?.close() }
            return
        }
        pdfView.document = doc
        doc.delegate = self
        sidebarModel.toc = TOCNode.build(from: doc.outlineRoot, in: doc)
        if sidebarModel.toc.isEmpty { sidebarModel.tab = .thumbnails }
        refreshHighlights()
        updateSubtitle()
        resolveIdentity()
    }

    private func unlock(_ doc: PDFDocument) -> Bool {
        while true {
            let alert = NSAlert()
            alert.messageText = "암호로 보호된 PDF"
            alert.informativeText = "\(readerDocument?.displayName ?? "")을(를) 열려면 암호를 입력하세요."
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            alert.accessoryView = field
            alert.addButton(withTitle: "열기")
            alert.addButton(withTitle: "취소")
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            if doc.unlock(withPassword: field.stringValue) { return true }
        }
    }

    var documentTitle: String {
        if let t = readerDocument?.pdf?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String,
           !t.trimmingCharacters(in: .whitespaces).isEmpty {
            return t
        }
        return readerDocument?.displayName ?? "Untitled"
    }

    /// Fast path by path+size+mtime, then full content identity in the background.
    private func resolveIdentity() {
        guard let url = readerDocument?.fileURL, let store = AppServices.shared.store else { return }
        let attrs = DocumentIdentity.fileAttributes(of: url)
        let title = documentTitle
        if let rec = try? store.document(path: url.path, size: attrs.size, mtime: attrs.mtime) {
            applyRecord(rec)
        }
        Task.detached(priority: .utility) { [weak self] in
            guard let bg = PDFDocument(url: url) else { return }
            if bg.isLocked { return }  // encrypted: identity by hash only would need the password; skip
            let count = bg.pageCount
            let first = (0..<min(3, count)).map { bg.page(at: $0)?.string ?? "" }
            let fp = DocumentFingerprint(
                sha256: (try? DocumentIdentity.sha256(of: url)) ?? UUID().uuidString,
                pdfID: DocumentIdentity.pdfTrailerID(of: url),
                textFingerprint: DocumentIdentity.textFingerprint(firstPages: first, pageCount: count),
                pageCount: count, fileSize: attrs.size, fileMTime: attrs.mtime)
            guard let rec = try? store.resolveDocument(fp, path: url.path, title: title) else { return }
            await MainActor.run {
                self?.currentSHA = fp.sha256
                self?.applyRecord(rec)
            }
            let cached = (try? store.pageText(documentID: rec.id)) ?? []
            if cached.count != count {
                let pages = (0..<count).map { bg.page(at: $0)?.string ?? "" }
                try? store.savePageText(documentID: rec.id, pages: pages)
            }
        }
    }

    private func applyRecord(_ rec: DocumentRecord) {
        let first = documentRecord == nil
        documentRecord = rec
        if first { chatModel.documentResolved(rec) }
        if let pending = pendingConversationID {
            pendingConversationID = nil
            openAISidebar()
            chatModel.selectConversation(id: pending)
        }
        guard !didRestorePosition else { return }
        didRestorePosition = true
        guard let doc = pdfView.document, (pdfView.currentPage.map { doc.index(for: $0) } ?? 0) == 0 else { return }
        if let mode = rec.displayMode, let m = PDFDisplayMode(rawValue: mode) { pdfView.displayMode = m }
        if let z = rec.lastZoom, z > 0 {
            pdfView.autoScales = false
            pdfView.scaleFactor = CGFloat(z)
        }
        if let p = rec.lastPage, p > 0, p < doc.pageCount, let page = doc.page(at: p) {
            pdfView.go(to: page)
        }
    }

    func documentDidSave() {
        guard let url = readerDocument?.fileURL, let store = AppServices.shared.store, let rec = documentRecord else { return }
        Task.detached(priority: .utility) { [weak self] in
            guard let sha = try? DocumentIdentity.sha256(of: url) else { return }
            let attrs = DocumentIdentity.fileAttributes(of: url)
            try? store.addHash(sha, to: rec.id)
            if var updated = try? store.document(id: rec.id) {
                updated.fileSize = attrs.size
                updated.fileMTime = attrs.mtime
                updated.lastPath = url.path
                if let pid = DocumentIdentity.pdfTrailerID(of: url) { updated.pdfID = pid }
                try? store.upsert(updated)
            }
            await MainActor.run { self?.currentSHA = sha }
        }
    }

    /// The file changed on disk (e.g. recompiled). Keep page, zoom, and the same conversation history.
    func documentReloaded(_ doc: PDFDocument) {
        let pageIndex = pdfView.currentPage.map { pdfView.document?.index(for: $0) ?? 0 } ?? 0
        let scale = pdfView.scaleFactor
        let auto = pdfView.autoScales
        pdfView.document = doc
        doc.delegate = self
        if !auto { pdfView.scaleFactor = scale }
        if let page = doc.page(at: min(pageIndex, max(0, doc.pageCount - 1))) { pdfView.go(to: page) }
        sidebarModel.toc = TOCNode.build(from: doc.outlineRoot, in: doc)
        refreshHighlights()
        updateSubtitle()
        if !sidebarModel.searchQuery.isEmpty { performSearch(sidebarModel.searchQuery) }

        guard let url = readerDocument?.fileURL, let store = AppServices.shared.store, let rec = documentRecord else { return }
        Task.detached(priority: .utility) {
            guard let bg = PDFDocument(url: url) else { return }
            let count = bg.pageCount
            let pages = (0..<count).map { bg.page(at: $0)?.string ?? "" }
            let attrs = DocumentIdentity.fileAttributes(of: url)
            if let sha = try? DocumentIdentity.sha256(of: url) { try? store.addHash(sha, to: rec.id) }
            if var updated = try? store.document(id: rec.id) {
                updated.pageCount = count
                updated.fileSize = attrs.size
                updated.fileMTime = attrs.mtime
                updated.textFingerprint = DocumentIdentity.textFingerprint(firstPages: Array(pages.prefix(3)), pageCount: count) ?? updated.textFingerprint
                updated.pdfID = DocumentIdentity.pdfTrailerID(of: url) ?? updated.pdfID
                try? store.upsert(updated)
            }
            try? store.savePageText(documentID: rec.id, pages: pages)
        }
    }

    // MARK: - Chat host

    var currentPageNumber: Int {
        guard let doc = pdfView.document, let page = pdfView.currentPage else { return 1 }
        return doc.index(for: page) + 1
    }

    var outlineEntries: [OutlineEntry] {
        var out: [OutlineEntry] = []
        func walk(_ nodes: [TOCNode], _ depth: Int) {
            for n in nodes {
                out.append(OutlineEntry(title: n.title, page: (n.pageIndex ?? 0) + 1, depth: depth))
                if let c = n.children { walk(c, depth + 1) }
            }
        }
        walk(sidebarModel.toc, 0)
        return out
    }

    /// Page texts, from the cache when available.
    func pageTexts() -> [String] {
        if let store = AppServices.shared.store, let id = documentRecord?.id,
           let cached = try? store.pageText(documentID: id), cached.count == pdfView.document?.pageCount {
            return cached
        }
        guard let doc = pdfView.document else { return [] }
        return (0..<doc.pageCount).map { doc.page(at: $0)?.string ?? "" }
    }

    func goToPage(_ number: Int) {
        guard let doc = pdfView.document, number >= 1, number <= doc.pageCount, let page = doc.page(at: number - 1) else { return }
        pdfView.go(to: page)
    }

    // MARK: - Notifications

    @objc private func pageChanged(_ note: Notification) {
        updateSubtitle()
        schedulePositionSave()
    }

    @objc private func scaleChanged(_ note: Notification) {
        schedulePositionSave()
    }

    @objc private func openConversationRequested(_ note: Notification) {
        guard let docID = note.userInfo?["documentID"] as? String,
              let convID = note.userInfo?["conversationID"] as? String else { return }
        if documentRecord?.id == docID {
            openAISidebar()
            chatModel.selectConversation(id: convID)
            window?.makeKeyAndOrderFront(nil)
        } else if documentRecord == nil, let path = note.userInfo?["path"] as? String, path == readerDocument?.fileURL?.path {
            pendingConversationID = convID
        }
    }

    private func updateSubtitle() {
        guard let doc = pdfView.document else { return }
        window?.subtitle = doc.pageCount > 0 ? "\(currentPageNumber) / \(doc.pageCount)" : ""
    }

    private func schedulePositionSave() {
        positionSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.savePosition() }
        positionSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func savePosition() {
        guard let rec = documentRecord, let store = AppServices.shared.store else { return }
        let zoom: Double? = pdfView.autoScales ? 0 : Double(pdfView.scaleFactor)
        try? store.saveReadingPosition(documentID: rec.id, page: currentPageNumber - 1, zoom: zoom,
                                       displayMode: pdfView.displayMode.rawValue)
    }

    func windowWillClose(_ notification: Notification) {
        positionSaveWork?.cancel()
        savePosition()
        chatModel.stop()
        readerDocument?.pdf?.cancelFindString()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.leftSidebar, .sidebarTrackingSeparator, .displayMode, .zoomOut, .zoomIn, .flexibleSpace,
         .highlight, .capture, .search, .ai]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func button(_ id: NSToolbarItem.Identifier, _ label: String, _ symbol: String, _ action: Selector) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = label
            item.paletteLabel = label
            item.toolTip = label
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            item.action = action
            item.target = self
            item.isBordered = true
            return item
        }
        switch id {
        case .displayMode:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.label = "보기"
            item.paletteLabel = "보기 모드"
            item.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: "보기 모드")
            let menu = NSMenu()
            for (title, tag) in [("단일 페이지", 0), ("단일 페이지 연속", 1), ("두 페이지", 2), ("두 페이지 연속", 3)] {
                let mi = NSMenuItem(title: title, action: #selector(setDisplayModeFromMenu(_:)), keyEquivalent: "")
                mi.tag = tag
                mi.target = self
                menu.addItem(mi)
            }
            menu.addItem(.separator())
            let book = NSMenuItem(title: "책 모드 (표지 단독)", action: #selector(toggleBookMode(_:)), keyEquivalent: "")
            book.target = self
            menu.addItem(book)
            let night = NSMenuItem(title: "야간 모드", action: #selector(toggleNightMode(_:)), keyEquivalent: "")
            night.target = self
            menu.addItem(night)
            item.menu = menu
            item.showsIndicator = true
            return item
        case .leftSidebar: return button(id, "사이드바", "sidebar.left", #selector(toggleLeftSidebar(_:)))
        case .zoomOut: return button(id, "축소", "minus.magnifyingglass", #selector(zoomOut(_:)))
        case .zoomIn: return button(id, "확대", "plus.magnifyingglass", #selector(zoomIn(_:)))
        case .highlight:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.label = "하이라이트"
            item.paletteLabel = "하이라이트"
            item.toolTip = "선택한 텍스트 하이라이트 (⌃⌘H)"
            item.image = NSImage(systemSymbolName: "highlighter", accessibilityDescription: "하이라이트")
            item.action = #selector(highlightSelection(_:))
            item.target = self
            let menu = NSMenu()
            for c in HighlightColor.allCases {
                let mi = NSMenuItem(title: c.name, action: #selector(highlightWithColorItem(_:)), keyEquivalent: "")
                mi.tag = c.rawValue
                mi.image = c.swatch
                mi.target = self
                menu.addItem(mi)
            }
            item.menu = menu
            item.showsIndicator = true
            return item
        case .capture: return button(id, "영역 캡처", "viewfinder", #selector(startRegionCapture(_:)))
        case .search:
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.label = "검색"
            item.paletteLabel = "검색"
            item.searchField.delegate = self
            item.searchField.target = self
            item.searchField.action = #selector(searchFieldAction(_:))
            item.searchField.sendsSearchStringImmediately = false
            item.searchField.sendsWholeSearchString = true
            item.searchField.placeholderString = "검색"
            item.preferredWidthForSearchField = 200
            searchField = item.searchField
            return item
        case .ai: return button(id, "AI", "sparkles", #selector(toggleAISidebar(_:)))
        default: return nil
        }
    }

    // MARK: - Find

    @objc func focusFind(_ sender: Any?) {
        guard let field = searchField else { return }
        window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    @objc private func searchFieldAction(_ sender: NSSearchField) {
        let q = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if q == sidebarModel.searchQuery, !hits.isEmpty {
            findNext(nil)
        } else {
            performSearch(q)
        }
    }

    func performSearch(_ query: String) {
        guard let doc = pdfView.document else { return }
        doc.cancelFindString()
        pendingHits = []
        hits = []
        sidebarModel.searchHits = []
        sidebarModel.currentHit = nil
        sidebarModel.searchQuery = query
        pdfView.highlightedSelections = nil
        guard !query.isEmpty else {
            sidebarModel.searching = false
            return
        }
        sidebarModel.searching = true
        showLeftTab(.search)
        doc.delegate = self
        doc.beginFindString(query, withOptions: [.caseInsensitive, .diacriticInsensitive])
    }

    nonisolated func didMatchString(_ instance: PDFSelection) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingHits.append(instance)
            if self.pendingHits.count % 100 == 0 { self.publishHits(final: false) }
        }
    }

    nonisolated func documentDidEndDocumentFind(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.publishHits(final: true) }
    }

    private func publishHits(final: Bool) {
        guard let doc = pdfView.document else { return }
        hits = pendingHits
        sidebarModel.searchHits = hits.enumerated().map { i, sel in
            let page = sel.pages.first.map { doc.index(for: $0) } ?? 0
            let ctx = (sel.copy() as? PDFSelection) ?? sel
            ctx.extend(atStart: 30)
            ctx.extend(atEnd: 50)
            let text = (ctx.string ?? sel.string ?? "")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            return SearchHit(id: i, selection: sel, pageIndex: page, context: text)
        }
        for s in hits { s.color = NSColor.systemYellow.withAlphaComponent(0.45) }
        pdfView.highlightedSelections = hits
        if final {
            sidebarModel.searching = false
            if !hits.isEmpty, sidebarModel.currentHit == nil { selectHit(0) }
            if hits.isEmpty { NSSound.beep() }
        }
    }

    private func selectHit(_ index: Int) {
        guard index >= 0, index < hits.count else { return }
        sidebarModel.currentHit = index
        let sel = hits[index]
        pdfView.setCurrentSelection(sel, animate: true)
        pdfView.go(to: sel)
    }

    @objc func findNext(_ sender: Any?) {
        guard !hits.isEmpty else { return focusFind(nil) }
        selectHit(((sidebarModel.currentHit ?? -1) + 1) % hits.count)
    }

    @objc func findPrevious(_ sender: Any?) {
        guard !hits.isEmpty else { return focusFind(nil) }
        selectHit(((sidebarModel.currentHit ?? 0) - 1 + hits.count) % hits.count)
    }

    @objc func useSelectionForFind(_ sender: Any?) {
        guard let s = pdfView.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return }
        searchField?.stringValue = s
        performSearch(s)
    }

    // MARK: - Navigation

    private func go(to node: TOCNode) {
        if let dest = node.destination {
            pdfView.go(to: dest)
        } else if let p = node.pageIndex, let page = pdfView.document?.page(at: p) {
            pdfView.go(to: page)
        }
    }

    private func go(to item: HighlightItem) {
        guard let page = item.annotation.page else { return }
        pdfView.go(to: item.annotation.bounds, on: page)
    }

    @objc func goPreviousPage(_ sender: Any?) { pdfView.goToPreviousPage(sender) }
    @objc func goNextPage(_ sender: Any?) { pdfView.goToNextPage(sender) }
    @objc func goFirstPage(_ sender: Any?) { pdfView.goToFirstPage(sender) }
    @objc func goLastPage(_ sender: Any?) { pdfView.goToLastPage(sender) }
    @objc func goBack(_ sender: Any?) { pdfView.goBack(sender) }
    @objc func goForward(_ sender: Any?) { pdfView.goForward(sender) }

    @objc func goToPagePrompt(_ sender: Any?) {
        guard let window, let doc = pdfView.document else { return }
        let alert = NSAlert()
        alert.messageText = "페이지로 이동"
        alert.informativeText = "1–\(doc.pageCount)"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        field.stringValue = "\(currentPageNumber)"
        alert.accessoryView = field
        alert.addButton(withTitle: "이동")
        alert.addButton(withTitle: "취소")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .alertFirstButtonReturn, let n = Int(field.stringValue.trimmingCharacters(in: .whitespaces)) else { return }
            self?.goToPage(n)
        }
    }

    // MARK: - View

    @objc func setDisplayModeFromMenu(_ sender: NSMenuItem) {
        let modes: [PDFDisplayMode] = [.singlePage, .singlePageContinuous, .twoUp, .twoUpContinuous]
        guard sender.tag >= 0, sender.tag < modes.count else { return }
        pdfView.displayMode = modes[sender.tag]
        UserDefaults.standard.set(modes[sender.tag].rawValue, forKey: Defaults.displayMode)
        schedulePositionSave()
    }

    @objc func toggleBookMode(_ sender: Any?) {
        pdfView.displaysAsBook.toggle()
    }

    @objc func toggleNightMode(_ sender: Any?) {
        pdfView.nightMode.toggle()
        UserDefaults.standard.set(pdfView.nightMode, forKey: Defaults.nightMode)
    }

    @objc func zoomIn(_ sender: Any?) { pdfView.zoomIn(sender) }
    @objc func zoomOut(_ sender: Any?) { pdfView.zoomOut(sender) }

    @objc func zoomActualSize(_ sender: Any?) {
        pdfView.autoScales = false
        pdfView.scaleFactor = 1.0
    }

    @objc func zoomToFit(_ sender: Any?) {
        guard let page = pdfView.currentPage else { return }
        let size = rotatedSize(page)
        let avail = pdfView.bounds.insetBy(dx: 16, dy: 16).size
        pdfView.autoScales = false
        pdfView.scaleFactor = max(0.1, min(avail.width / size.width, avail.height / size.height))
        pdfView.go(to: page)
    }

    @objc func zoomToWidth(_ sender: Any?) {
        pdfView.autoScales = true
    }

    private func rotatedSize(_ page: PDFPage) -> NSSize {
        let b = page.bounds(for: pdfView.displayBox).size
        let twoUp = pdfView.displayMode == .twoUp || pdfView.displayMode == .twoUpContinuous
        var s = page.rotation % 180 == 0 ? b : NSSize(width: b.height, height: b.width)
        if twoUp { s.width *= 2 }
        return s
    }

    @objc func rotateLeft(_ sender: Any?) { rotate(by: -90) }
    @objc func rotateRight(_ sender: Any?) { rotate(by: 90) }

    private func rotate(by degrees: Int) {
        guard let doc = pdfView.document else { return }
        let current = pdfView.currentPage
        for i in 0..<doc.pageCount {
            if let p = doc.page(at: i) { p.rotation = (p.rotation + degrees + 360) % 360 }
        }
        pdfView.layoutDocumentView()
        if let current { pdfView.go(to: current) }
    }

    // MARK: - Sidebars

    @objc func toggleLeftSidebar(_ sender: Any?) {
        setLeftSidebar(open: leftItem.isCollapsed)
    }

    private func setLeftSidebar(open: Bool) {
        if open { leftVC.ensureLoaded() }
        leftItem.animator().isCollapsed = !open
        UserDefaults.standard.set(open, forKey: Defaults.leftOpen)
    }

    private func showLeftTab(_ tab: SidebarTab) {
        sidebarModel.tab = tab
        if leftItem.isCollapsed { setLeftSidebar(open: true) }
    }

    @objc func showTOC(_ sender: Any?) { showLeftTab(.toc) }
    @objc func showThumbnails(_ sender: Any?) { showLeftTab(.thumbnails) }
    @objc func showHighlightList(_ sender: Any?) { showLeftTab(.highlights) }
    @objc func showSearchResults(_ sender: Any?) { showLeftTab(.search) }

    @objc func toggleAISidebar(_ sender: Any?) {
        if aiItem.isCollapsed {
            openAISidebar()
        } else {
            aiItem.animator().isCollapsed = true
            UserDefaults.standard.set(false, forKey: Defaults.aiOpen)
            window?.makeFirstResponder(pdfView)
        }
    }

    func openAISidebar() {
        chatVC.ensureLoaded()
        if aiItem.isCollapsed {
            aiItem.animator().isCollapsed = false
            UserDefaults.standard.set(true, forKey: Defaults.aiOpen)
        }
        chatModel.requestInputFocus()
    }

    // MARK: - Highlights

    @objc func highlightSelection(_ sender: Any?) {
        addHighlight(color: HighlightColor.yellow.color)
    }

    @objc func highlightWithColorItem(_ sender: NSMenuItem) {
        addHighlight(color: HighlightColor(rawValue: sender.tag)?.color ?? HighlightColor.yellow.color)
    }

    private func canWriteAnnotations() -> Bool {
        if pdfView.document?.isEncrypted == true {
            let alert = NSAlert()
            alert.messageText = "암호화된 PDF에는 하이라이트를 저장할 수 없습니다."
            alert.runModal()
            return false
        }
        return true
    }

    func addHighlight(color: NSColor) {
        guard let selection = pdfView.currentSelection, let text = selection.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { NSSound.beep(); return }
        guard canWriteAnnotations() else { return }
        var added: [(PDFAnnotation, PDFPage)] = []
        let lines = selection.selectionsByLine()
        for page in selection.pages {
            let rects = lines.filter { $0.pages.contains(page) }
                .map { $0.bounds(for: page) }
                .filter { $0.width > 0.5 && $0.height > 0.5 }
            guard let union = rects.dropFirst().reduce(rects.first, { $0?.union($1) }) else { continue }
            let annotation = PDFAnnotation(bounds: union, forType: .highlight, withProperties: nil)
            annotation.color = color
            annotation.userName = NSFullUserName()
            annotation.modificationDate = Date()
            var quads: [NSValue] = []
            for r in rects {
                quads.append(NSValue(point: NSPoint(x: r.minX - union.minX, y: r.maxY - union.minY)))
                quads.append(NSValue(point: NSPoint(x: r.maxX - union.minX, y: r.maxY - union.minY)))
                quads.append(NSValue(point: NSPoint(x: r.minX - union.minX, y: r.minY - union.minY)))
                quads.append(NSValue(point: NSPoint(x: r.maxX - union.minX, y: r.minY - union.minY)))
            }
            annotation.quadrilateralPoints = quads
            page.addAnnotation(annotation)
            added.append((annotation, page))
        }
        guard !added.isEmpty else { return }
        registerUndo(name: "하이라이트") { [weak self] in
            for (a, p) in added { p.removeAnnotation(a) }
            self?.annotationsChanged()
        } redo: { [weak self] in
            for (a, p) in added { p.addAnnotation(a) }
            self?.annotationsChanged()
        }
        pdfView.clearSelection()
        annotationsChanged()
    }

    private func registerUndo(name: String, undo: @escaping () -> Void, redo: @escaping () -> Void) {
        guard let um = readerDocument?.undoManager else { return }
        um.registerUndo(withTarget: self) { target in
            undo()
            target.registerUndo(name: name, undo: redo, redo: undo)
        }
        um.setActionName(name)
    }

    private func annotationsChanged() {
        readerDocument?.updateChangeCount(.changeDone)
        refreshHighlights()
    }

    func refreshHighlights() {
        guard let doc = pdfView.document else { return }
        var items: [HighlightItem] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            for a in page.annotations where a.type == "Highlight" {
                let text = page.selection(for: a.bounds)?.string?
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespaces) ?? ""
                items.append(HighlightItem(id: ObjectIdentifier(a), annotation: a, pageIndex: i, text: text,
                                           note: a.contents, color: a.color))
            }
        }
        sidebarModel.highlights = items
    }

    // ReaderPDFViewDelegate

    func pdfView(_ view: ReaderPDFView, highlightWith color: NSColor) {
        addHighlight(color: color)
    }

    func pdfView(_ view: ReaderPDFView, recolor annotation: PDFAnnotation, color: NSColor) {
        let old = annotation.color
        annotation.color = color
        registerUndo(name: "하이라이트 색상") { [weak self] in
            annotation.color = old
            self?.annotationsChanged()
        } redo: { [weak self] in
            annotation.color = color
            self?.annotationsChanged()
        }
        annotationsChanged()
    }

    func pdfView(_ view: ReaderPDFView, editNoteFor annotation: PDFAnnotation) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "하이라이트 메모"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = annotation.contents ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "저장")
        alert.addButton(withTitle: "취소")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .alertFirstButtonReturn else { return }
            let old = annotation.contents
            let new = field.stringValue
            annotation.contents = new
            self?.registerUndo(name: "메모") { [weak self] in
                annotation.contents = old
                self?.annotationsChanged()
            } redo: { [weak self] in
                annotation.contents = new
                self?.annotationsChanged()
            }
            self?.annotationsChanged()
        }
    }

    func pdfView(_ view: ReaderPDFView, remove annotation: PDFAnnotation) {
        guard let page = annotation.page else { return }
        page.removeAnnotation(annotation)
        registerUndo(name: "하이라이트 삭제") { [weak self] in
            page.addAnnotation(annotation)
            self?.annotationsChanged()
        } redo: { [weak self] in
            page.removeAnnotation(annotation)
            self?.annotationsChanged()
        }
        annotationsChanged()
    }

    // MARK: - AI actions

    func pdfView(_ view: ReaderPDFView, ask kind: AskKind, text: String) {
        ask(kind, text: text)
    }

    private func ask(_ kind: AskKind, text: String) {
        openAISidebar()
        chatModel.quote(text, kind: kind)
    }

    func pdfView(_ view: ReaderPDFView, didCapture image: NSImage, pngData: Data, page: Int) {
        openAISidebar()
        chatModel.addImage(data: pngData, mediaType: "image/png", page: page)
    }

    func pdfViewDidCancelCapture(_ view: ReaderPDFView) {}

    @objc func startRegionCapture(_ sender: Any?) {
        if pdfView.isCapturing { pdfView.endCapture(cancelled: true) } else { pdfView.beginCapture() }
    }

    private var selectedText: String? {
        let s = pdfView.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty ?? true) ? nil : s
    }

    @objc func askAIAboutSelection(_ sender: Any?) {
        if let s = selectedText { ask(.ask, text: s) } else { openAISidebar() }
    }

    @objc func explainSelection(_ sender: Any?) {
        if let s = selectedText { ask(.explain, text: s) }
    }

    @objc func translateSelection(_ sender: Any?) {
        if let s = selectedText { ask(.translate, text: s) }
    }

    @objc func newConversation(_ sender: Any?) {
        openAISidebar()
        chatModel.newConversation()
    }

    @objc func exportChat(_ sender: Any?) {
        chatModel.exportMarkdown(all: false)
    }

    // MARK: - File

    @objc func revealInFinder(_ sender: Any?) {
        if let url = readerDocument?.fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    @objc func printDocument(_ sender: Any?) {
        guard let doc = pdfView.document, let window else { return }
        let info = NSPrintInfo.shared
        guard let op = doc.printOperation(for: info, scalingMode: .pageScaleToFit, autoRotate: true) else { return }
        op.showsPrintPanel = true
        op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    // MARK: - Validation

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let textInputFocused = (window?.firstResponder as? NSTextView) != nil
        switch item.action {
        case #selector(goPreviousPage(_:)), #selector(goNextPage(_:)), #selector(goFirstPage(_:)), #selector(goLastPage(_:)):
            return !textInputFocused
        case #selector(goBack(_:)): return pdfView.canGoBack
        case #selector(goForward(_:)): return pdfView.canGoForward
        case #selector(setDisplayModeFromMenu(_:)):
            let modes: [PDFDisplayMode] = [.singlePage, .singlePageContinuous, .twoUp, .twoUpContinuous]
            item.state = (item.tag < modes.count && modes[item.tag] == pdfView.displayMode) ? .on : .off
            return true
        case #selector(toggleBookMode(_:)):
            item.state = pdfView.displaysAsBook ? .on : .off
            return true
        case #selector(toggleNightMode(_:)):
            item.state = pdfView.nightMode ? .on : .off
            return true
        case #selector(toggleLeftSidebar(_:)):
            item.title = leftItem.isCollapsed ? "사이드바 보기" : "사이드바 가리기"
            return true
        case #selector(toggleAISidebar(_:)):
            item.title = aiItem.isCollapsed ? "AI 사이드바 보기" : "AI 사이드바 가리기"
            return true
        case #selector(highlightSelection(_:)), #selector(explainSelection(_:)), #selector(translateSelection(_:)),
             #selector(useSelectionForFind(_:)):
            return selectedText != nil
        case #selector(findNext(_:)), #selector(findPrevious(_:)):
            return !hits.isEmpty || !textInputFocused
        case #selector(exportChat(_:)):
            return chatModel.canExport
        default:
            return true
        }
    }
}
