import AppKit
import SwiftUI
import UniformTypeIdentifiers
import FolioCore

struct ChatSidebarView: View {
    @ObservedObject var model: ChatViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack {
                ChatTranscriptView(messages: model.messages, streamingID: model.streamingMessageID,
                                   version: model.transcriptVersion,
                                   onCopy: { model.copyMessage(id: $0) },
                                   onPage: { model.goToPage($0) })
                if model.messages.isEmpty { emptyState }
            }
            Divider()
            composer
        }
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { model.handleDrop($0) }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Menu {
                Section("제공자") {
                    ForEach(ProviderKind.allCases) { kind in
                        Button {
                            model.setProvider(kind)
                        } label: {
                            if kind == model.provider { Label(kind.displayName, systemImage: "checkmark") } else { Text(kind.displayName) }
                        }
                    }
                }
                Section("모델") {
                    ForEach(model.models, id: \.self) { m in
                        Button {
                            model.setModel(m)
                        } label: {
                            if m == model.model { Label(m, systemImage: "checkmark") } else { Text(m) }
                        }
                    }
                    Button("모델 직접 입력…") { model.promptCustomModel() }
                }
                Divider()
                Button("AI 설정…") { model.openSettings() }
            } label: {
                Text("\(model.provider.shortName) · \(model.model)").lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("제공자와 모델")

            Spacer(minLength: 4)

            Menu {
                Button("새 대화") { model.newConversation() }
                if !model.conversations.isEmpty {
                    Section("이 문서의 대화") {
                        ForEach(model.conversations) { c in
                            Button {
                                model.selectConversation(id: c.id)
                            } label: {
                                let label = "\(c.title)  —  \(Self.dateFormatter.string(from: Date(timeIntervalSince1970: c.updatedAt)))"
                                if c.id == model.current?.id { Label(label, systemImage: "checkmark") } else { Text(label) }
                            }
                        }
                    }
                }
                if model.current != nil {
                    Divider()
                    Button("이 대화 삭제…", role: .destructive) { model.deleteCurrentConversation() }
                }
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("대화 기록")

            Button { model.newConversation() } label: { Image(systemName: "square.and.pencil") }
                .buttonStyle(.borderless)
                .help("새 대화 (⌃⌘N)")

            Menu {
                Button("이 대화를 Markdown으로 내보내기…") { model.exportMarkdown(all: false) }
                    .disabled(!model.canExport)
                Button("이 문서의 모든 대화 내보내기…") { model.exportMarkdown(all: true) }
                    .disabled(model.conversations.isEmpty)
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("내보내기")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles").font(.system(size: 28)).foregroundStyle(.tertiary)
            Text("이 PDF에 대해 물어보세요").font(.headline).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("• 텍스트 선택 후 우클릭 → AI에게 묻기")
                Text("• ⌃⇧⌘4: 그림 영역 캡처해 첨부")
                Text("• 이미지 붙여넣기(⌘V)나 끌어다 놓기")
                Text("• 답변의 [p.N]을 누르면 해당 페이지로 이동")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            if !model.documentReady {
                ProgressView().controlSize(.small).padding(.top, 6)
            }
        }
        .padding()
        .allowsHitTesting(false)
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let q = model.quotedText {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "text.quote").foregroundStyle(.secondary)
                    Text(q).font(.callout).lineLimit(3).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button { model.quotedText = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
            }
            if !model.pendingImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.pendingImages) { img in
                            ZStack(alignment: .topTrailing) {
                                Image(nsImage: img.thumbnail)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxWidth: 90, maxHeight: 64)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                                Button { model.removePendingImage(img.id) } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.6))
                                }
                                .buttonStyle(.borderless)
                                .offset(x: 4, y: -4)
                            }
                            .help(img.page.map { "p.\($0)에서 캡처" } ?? "이미지")
                        }
                    }
                    .padding(.top, 4)
                }
            }
            HStack(alignment: .bottom, spacing: 6) {
                ChatInputView(text: $model.draft, focusToken: model.focusToken,
                              placeholder: "질문 입력 (⏎ 전송, ⇧⏎ 줄바꿈)",
                              onSubmit: { model.send() },
                              onPasteImage: { data, type in model.addImage(data: data, mediaType: type, page: nil) })
                    .frame(minHeight: 40, maxHeight: 120)
                    .fixedSize(horizontal: false, vertical: false)
                VStack(spacing: 4) {
                    if model.isStreaming {
                        Button { model.stop() } label: { Image(systemName: "stop.circle.fill").font(.title2) }
                            .buttonStyle(.borderless)
                            .keyboardShortcut(.escape, modifiers: [])
                            .help("중단 (⎋)")
                    } else {
                        Button { model.send() } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                            .buttonStyle(.borderless)
                            .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                      && model.pendingImages.isEmpty && model.quotedText == nil)
                            .help("전송 (⏎)")
                    }
                }
            }
            if let status = model.status {
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
            }
        }
        .padding(10)
    }
}

// MARK: - Input

struct ChatInputView: NSViewRepresentable {
    @Binding var text: String
    var focusToken: Int
    var placeholder: String
    var onSubmit: () -> Void
    var onPasteImage: (Data, String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let tv = SubmitTextView()
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        tv.textContainerInset = NSSize(width: 4, height: 6)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.drawsBackground = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.delegate = context.coordinator
        tv.placeholder = placeholder
        tv.onPasteImage = { data, type in context.coordinator.parent.onPasteImage(data, type) }
        scroll.documentView = tv
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 6
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = NSColor.separatorColor.cgColor
        context.coordinator.textView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = context.coordinator.textView else { return }
        if tv.string != text && !tv.hasMarkedText() {
            tv.string = text
            tv.needsDisplay = true
        }
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatInputView
        weak var textView: SubmitTextView?
        var lastFocusToken: Int

        init(_ parent: ChatInputView) {
            self.parent = parent
            self.lastFocusToken = parent.focusToken
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }

        /// Return sends; Shift/Option-Return inserts a newline. Runs after the input method has
        /// committed any composition, so Korean IME works as expected.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                if flags.contains(.shift) || flags.contains(.option) {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    parent.text = textView.string
                    parent.onSubmit()
                }
                return true
            }
            return false
        }
    }
}

final class SubmitTextView: NSTextView {
    var placeholder = ""
    var onPasteImage: ((Data, String) -> Void)?

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        if pb.string(forType: .string) == nil,
           let image = NSImage(pasteboard: pb),
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            onPasteImage?(png, "image/png")
            return
        }
        super.paste(sender)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.placeholderTextColor,
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
        ]
        let origin = NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height)
        (placeholder as NSString).draw(at: origin, withAttributes: attrs)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}
