import AppKit
import SwiftUI
import UniformTypeIdentifiers
import FolioCore

struct PendingImage: Identifiable {
    let id = UUID()
    let data: Data
    let mediaType: String
    let page: Int?
    let thumbnail: NSImage
}

@MainActor
final class ChatViewModel: ObservableObject {
    private weak var host: ReaderWindowController?

    @Published private(set) var conversations: [ConversationRecord] = []
    @Published private(set) var current: ConversationRecord?
    @Published private(set) var messages: [MessageRecord] = []
    @Published private(set) var streamingMessageID: String?
    @Published private(set) var transcriptVersion = 0
    @Published var pendingImages: [PendingImage] = []
    @Published var quotedText: String?
    @Published var draft = ""
    @Published private(set) var provider: ProviderKind = AppSettings.provider
    @Published private(set) var model: String = AppSettings.model(for: AppSettings.provider)
    @Published private(set) var models: [String] = []
    @Published var status: String?
    @Published private(set) var focusToken = 0
    @Published private(set) var documentReady = false

    private var documentID: String?
    private var task: Task<Void, Never>?
    private var streamBuffer = ""
    private var flushScheduled = false
    private var store: Store? { AppServices.shared.store }

    /// Longest edge for images sent to models (Claude's recommended maximum).
    static let maxImageEdge: CGFloat = 1568

    init(host: ReaderWindowController) {
        self.host = host
        loadModels()
    }

    var canExport: Bool { current != nil && !messages.isEmpty }
    var isStreaming: Bool { streamingMessageID != nil }

    // MARK: Document / conversations

    func documentResolved(_ record: DocumentRecord) {
        documentID = record.id
        documentReady = true
        reloadConversations()
        if current == nil, let latest = conversations.first {
            selectConversation(id: latest.id)
        }
    }

    private func reloadConversations() {
        guard let store, let documentID else { return }
        conversations = (try? store.conversations(documentID: documentID)) ?? []
    }

    func selectConversation(id: String) {
        guard !isStreaming, let store, let conv = try? store.conversation(id: id) else { return }
        current = conv
        messages = (try? store.messages(conversationID: id)) ?? []
        if let kind = ProviderKind(rawValue: conv.provider) {
            provider = kind
            model = conv.model
        }
        status = nil
        transcriptVersion += 1
    }

    func newConversation() {
        guard !isStreaming else { return }
        current = nil
        messages = []
        status = nil
        transcriptVersion += 1
        requestInputFocus()
    }

    func deleteCurrentConversation() {
        guard let conv = current, !isStreaming else { return }
        let alert = NSAlert()
        alert.messageText = "이 대화를 삭제할까요?"
        alert.informativeText = "“\(conv.title)” 대화와 첨부 이미지가 영구히 삭제됩니다."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "삭제")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? store?.deleteConversation(id: conv.id)
        reloadConversations()
        newConversation()
    }

    // MARK: Provider / model

    func setProvider(_ kind: ProviderKind) {
        guard kind != provider else { return }
        provider = kind
        AppSettings.provider = kind
        model = AppSettings.model(for: kind)
        loadModels()
    }

    func setModel(_ m: String) {
        model = m
        AppSettings.setModel(m, for: provider)
    }

    func loadModels() {
        let kind = provider
        models = kind == .claudeCode ? ClaudeCodeProvider.modelAliases : (kind == .anthropicAPI ? AnthropicAPIProvider.defaultModels : [])
        Task {
            let list = (try? await ProviderFactory.make(kind).listModels()) ?? []
            if kind == self.provider, !list.isEmpty { self.models = list }
        }
    }

    func promptCustomModel() {
        let alert = NSAlert()
        alert.messageText = "모델 이름"
        alert.informativeText = "\(provider.displayName)에서 사용할 모델 이름을 입력하세요."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = model
        alert.accessoryView = field
        alert.addButton(withTitle: "확인")
        alert.addButton(withTitle: "취소")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            let m = field.stringValue.trimmingCharacters(in: .whitespaces)
            if !m.isEmpty { setModel(m) }
        }
    }

    // MARK: Composer

    func requestInputFocus() { focusToken += 1 }

    func quote(_ text: String, kind: AskKind) {
        quotedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .ask:
            requestInputFocus()
        case .explain:
            draft = "이 부분을 쉽게 설명해줘."
            send()
        case .translate:
            draft = "이 부분을 \(AppSettings.responseLanguage)로 번역해줘."
            send()
        }
    }

    func addImage(data: Data, mediaType: String, page: Int?) {
        guard let image = NSImage(data: data) else { return }
        let (bytes, type) = Self.normalizedImage(image, original: data, mediaType: mediaType)
        let thumb = Self.thumbnail(image, maxEdge: 120)
        pendingImages.append(PendingImage(data: bytes, mediaType: type, page: page, thumbnail: thumb))
        requestInputFocus()
    }

    func startCapture() {
        host?.startRegionCapture(nil)
    }

    func chooseImage() {
        guard let window = host?.window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK else { return }
            for url in panel.urls {
                guard let data = try? Data(contentsOf: url) else { continue }
                let type = UTType(filenameExtension: url.pathExtension)
                let mt = type?.conforms(to: .jpeg) == true ? "image/jpeg" : (type?.conforms(to: .png) == true ? "image/png" : "image/other")
                self?.addImage(data: data, mediaType: mt, page: nil)
            }
        }
    }

    func removePendingImage(_ id: UUID) {
        pendingImages.removeAll { $0.id == id }
    }

    /// Downscales to `maxImageEdge` and re-encodes as PNG when needed.
    static func normalizedImage(_ image: NSImage, original: Data, mediaType: String) -> (Data, String) {
        guard let rep = NSBitmapImageRep(data: original) ?? image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)) else {
            return (original, mediaType)
        }
        let w = CGFloat(rep.pixelsWide), h = CGFloat(rep.pixelsHigh)
        let longest = max(w, h)
        let okType = mediaType == "image/png" || mediaType == "image/jpeg"
        if longest <= maxImageEdge && okType { return (original, mediaType) }
        let scale = min(1, maxImageEdge / longest)
        let size = NSSize(width: (w * scale).rounded(), height: (h * scale).rounded())
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return (original, mediaType) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        NSGraphicsContext.current?.imageInterpolation = .high
        rep.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let png = out.representation(using: .png, properties: [:]) ?? original
        return (png, "image/png")
    }

    static func thumbnail(_ image: NSImage, maxEdge: CGFloat) -> NSImage {
        let s = image.size
        let scale = min(1, maxEdge / max(s.width, s.height, 1))
        let size = NSSize(width: max(1, s.width * scale), height: max(1, s.height * scale))
        return NSImage(size: size, flipped: false) { r in
            image.draw(in: r)
            return true
        }
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
                          let data = try? Data(contentsOf: url) else { return }
                    let mt = type.conforms(to: .jpeg) ? "image/jpeg" : (type.conforms(to: .png) ? "image/png" : "image/other")
                    DispatchQueue.main.async { self.addImage(data: data, mediaType: mt, page: nil) }
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                handled = true
                p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    DispatchQueue.main.async { self.addImage(data: data, mediaType: "image/other", page: nil) }
                }
            }
        }
        return handled
    }

    // MARK: Sending

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isStreaming, !(text.isEmpty && pendingImages.isEmpty && (quotedText ?? "").isEmpty) else { return }
        guard let store, let documentID, let host else {
            status = "문서를 분석하는 중입니다. 잠시 후 다시 시도하세요."
            return
        }

        // Conversation bookkeeping.
        var conv: ConversationRecord
        if let c = current {
            conv = c
        } else {
            let titleSource = text.isEmpty ? (quotedText ?? "이미지 질문") : text
            conv = ConversationRecord(documentID: documentID,
                                      title: String(titleSource.replacingOccurrences(of: "\n", with: " ").prefix(40)),
                                      provider: provider.rawValue, model: model)
        }
        if conv.provider != provider.rawValue {
            conv.cliSessionID = nil  // a Claude Code session can't continue another provider's conversation
        }
        conv.provider = provider.rawValue
        conv.model = model
        conv.updatedAt = Date().timeIntervalSince1970
        do { try store.save(conv) } catch { status = "저장 실패: \(error.localizedDescription)"; return }
        current = conv
        if !conversations.contains(where: { $0.id == conv.id }) { conversations.insert(conv, at: 0) }

        let attachments = pendingImages.compactMap { try? store.storeAttachment(data: $0.data, mediaType: $0.mediaType, page: $0.page) }
        let userMessage = MessageRecord(conversationID: conv.id, role: .user, content: text, quotedText: quotedText,
                                        pageRef: host.currentPageNumber, attachments: attachments)
        try? store.save(userMessage)
        messages.append(userMessage)
        draft = ""
        quotedText = nil
        pendingImages = []
        status = nil

        startReply(conversation: conv)
    }

    /// Appends an empty assistant message and streams the reply to the latest user message.
    private func startReply(conversation conv: ConversationRecord) {
        guard let store, let documentID, let host,
              let userMessage = messages.last(where: { $0.role == .user }) else { return }
        let text = userMessage.content
        let assistant = MessageRecord(conversationID: conv.id, role: .assistant, content: "",
                                      createdAt: max(Date().timeIntervalSince1970, userMessage.createdAt + 0.001))
        messages.append(assistant)
        streamingMessageID = assistant.id
        transcriptVersion += 1

        // Build the request.
        let pages = host.pageTexts()
        let builder = ContextBuilder(documentTitle: host.documentTitle, pages: pages, outline: host.outlineEntries,
                                     budgetChars: AppSettings.contextChars(for: provider),
                                     responseLanguage: AppSettings.responseLanguage, customPrompt: AppSettings.customPrompt)
        let relevant = builder.fitsWhole ? [] :
            ((try? store.searchPages(documentID: documentID, query: text + " " + (userMessage.quotedText ?? ""), limit: 8)) ?? [])
        let system = builder.systemPrompt(currentPage: host.currentPageNumber, relevantPages: relevant)
        let turns = buildTurns()
        let resume = provider == .claudeCode ? conv.cliSessionID : nil
        let request = ChatRequest(system: system, turns: turns, model: model, resumeSessionID: resume)
        let chatProvider = ProviderFactory.make(provider)
        let assistantID = assistant.id
        let convID = conv.id

        task = Task { [weak self] in
            var failure: Error?
            do {
                for try await event in chatProvider.stream(request) {
                    guard let self else { return }
                    switch event {
                    case .text(let t): self.appendDelta(t)
                    case .sessionID(let sid): self.updateSession(sid, conversationID: convID)
                    case .usage(let u): self.status = u
                    }
                }
            } catch is CancellationError {
            } catch {
                failure = error
                // A sign-in problem shows up as a failed request: re-read the login state so the
                // sidebar can offer "Claude에 로그인".
                if self?.provider == .claudeCode { ClaudeAccount.shared.refresh() }
            }
            self?.finish(assistantID: assistantID, error: failure)
        }
    }

    /// Conversation history as provider turns. Images: all on the newest turn; older ones only for
    /// API providers, capped so requests stay small.
    private func buildTurns() -> [ChatTurn] {
        let history = messages.filter { !$0.isError && !($0.role == .assistant && $0.content.isEmpty) }
        var imageBudget = provider == .claudeCode ? 0 : 4
        var turns: [ChatTurn] = []
        for (i, m) in history.enumerated().reversed() {
            let isLast = i == history.count - 1
            var images: [ChatImage] = []
            if m.role == .user, !m.attachments.isEmpty, isLast || imageBudget > 0 {
                for a in m.attachments {
                    if let data = FileManager.default.contents(atPath: a.filePath) {
                        images.append(ChatImage(data: data, mediaType: a.mediaType))
                    }
                }
                if !isLast { imageBudget -= images.count }
            }
            var text = m.content
            if m.role == .user {
                text = ContextBuilder.messagePreamble(currentPage: m.pageRef ?? 1, quoted: m.quotedText) + m.content
                if m.content.isEmpty && !images.isEmpty { text += "이 이미지를 설명해줘." }
            }
            turns.append(ChatTurn(role: m.role, text: text, images: images))
        }
        return turns.reversed()
    }

    private func appendDelta(_ t: String) {
        streamBuffer += t
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.flush() }
    }

    private func flush() {
        flushScheduled = false
        guard !streamBuffer.isEmpty, let id = streamingMessageID,
              let idx = messages.lastIndex(where: { $0.id == id }) else { return }
        messages[idx].content += streamBuffer
        streamBuffer = ""
        transcriptVersion += 1
    }

    private func updateSession(_ sid: String, conversationID: String) {
        guard var conv = current, conv.id == conversationID, conv.cliSessionID != sid else { return }
        conv.cliSessionID = sid
        current = conv
        try? store?.save(conv)
    }

    private func finish(assistantID: String, error: Error?) {
        flush()
        task = nil
        streamingMessageID = nil
        guard let idx = messages.lastIndex(where: { $0.id == assistantID }) else { return }
        if let error {
            let text = messages[idx].content
            messages[idx].content = (text.isEmpty ? "" : text + "\n\n") + "⚠️ " + error.localizedDescription
            messages[idx].isError = text.isEmpty
        } else if messages[idx].content.isEmpty {
            messages[idx].content = "_(응답이 중단되었습니다)_"
            messages[idx].isError = true
        }
        try? store?.save(messages[idx])
        reloadConversations()
        transcriptVersion += 1
    }

    func stop() {
        task?.cancel()
    }

    // MARK: Per-message actions

    func handle(_ action: TranscriptAction, messageID: String) {
        switch action {
        case .export: exportMessage(id: messageID)
        case .regenerate: regenerate(id: messageID)
        case .delete: deleteMessage(id: messageID)
        }
    }

    private func regenerate(id: String) {
        guard !isStreaming, var conv = current, let idx = messages.lastIndex(where: { $0.id == id }),
              messages[idx].role == .assistant, idx == messages.count - 1 else { return }
        try? store?.deleteMessage(id: id)
        messages.remove(at: idx)
        // The Claude Code session already holds the old answer; start a fresh session from the transcript.
        if conv.cliSessionID != nil {
            conv.cliSessionID = nil
            current = conv
            try? store?.save(conv)
        }
        conv.provider = provider.rawValue
        conv.model = model
        current = conv
        try? store?.save(conv)
        status = nil
        startReply(conversation: conv)
    }

    private func deleteMessage(id: String) {
        guard !isStreaming, let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        try? store?.deleteMessage(id: id)
        messages.remove(at: idx)
        if var conv = current, conv.cliSessionID != nil {
            conv.cliSessionID = nil  // keep the model's memory consistent with what's on screen
            current = conv
            try? store?.save(conv)
        }
        transcriptVersion += 1
    }

    private func exportMessage(id: String) {
        guard let m = messages.first(where: { $0.id == id }), let conv = current, let host, let window = host.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        let base = (host.readerDocument?.displayName ?? "chat").replacingOccurrences(of: ".pdf", with: "")
        panel.nameFieldStringValue = "\(base) - \(conv.title)".replacingOccurrences(of: "/", with: "-") + ".md"
        // Include the question the answer belongs to.
        var selected = [m]
        if m.role == .assistant, let i = messages.firstIndex(where: { $0.id == id }),
           let q = messages[..<i].last(where: { $0.role == .user }) {
            selected.insert(q, at: 0)
        }
        panel.beginSheetModal(for: window) { resp in
            guard resp == .OK, let url = panel.url else { return }
            do {
                try MarkdownExporter.export(to: url, title: host.documentTitle,
                                            sourcePath: host.readerDocument?.fileURL?.path, sha256: host.currentSHA,
                                            conversations: [.init(record: conv, messages: selected)])
            } catch {
                NSApp.presentError(error)
            }
        }
    }

    // MARK: Transcript actions

    func copyMessage(id: String) {
        guard let m = messages.first(where: { $0.id == id }) else { return }
        var text = m.content
        if let q = m.quotedText, !q.isEmpty {
            text = q.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n") + "\n\n" + text
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func goToPage(_ page: Int) {
        host?.goToPage(page)
    }

    // MARK: Export

    func exportMarkdown(all: Bool) {
        guard let store, let host, let window = host.window else { return }
        var convs: [ConversationRecord] = []
        if all {
            convs = conversations.sorted { $0.createdAt < $1.createdAt }
        } else if let c = current {
            convs = [c]
        }
        guard !convs.isEmpty else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        let base = (host.readerDocument?.displayName ?? "chat").replacingOccurrences(of: ".pdf", with: "")
        let suffix = all ? "AI 대화" : (convs.first?.title ?? "AI 대화")
        panel.nameFieldStringValue = "\(base) - \(suffix)".replacingOccurrences(of: "/", with: "-") + ".md"
        panel.beginSheetModal(for: window) { resp in
            guard resp == .OK, let url = panel.url else { return }
            let payload = convs.map { c in
                MarkdownExporter.Conversation(record: c, messages: (try? store.messages(conversationID: c.id)) ?? [])
            }
            do {
                try MarkdownExporter.export(to: url, title: host.documentTitle,
                                            sourcePath: host.readerDocument?.fileURL?.path,
                                            sha256: host.currentSHA, conversations: payload)
            } catch {
                NSApp.presentError(error)
            }
        }
    }

    func openSettings() {
        (NSApp.delegate as? AppDelegate)?.showSettings(nil)
    }
}
