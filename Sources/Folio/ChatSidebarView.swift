import AppKit
import SwiftUI
import UniformTypeIdentifiers
import FolioCore

struct ChatSidebarView: View {
    @ObservedObject var model: ChatViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.provider == .claudeCode { ClaudeLoginBanner() }
            ZStack {
                ChatTranscriptView(messages: model.messages, streamingID: model.streamingMessageID,
                                   version: model.transcriptVersion,
                                   onCopy: { model.copyMessage(id: $0) },
                                   onPage: { model.goToPage($0) },
                                   onAction: { model.handle($0, messageID: $1) })
                if model.messages.isEmpty { emptyState }
            }
            composer
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { model.handleDrop($0) }
        .onAppear { if model.provider == .claudeCode { ClaudeAccount.shared.refreshIfStale() } }
        .onChange(of: model.provider) { _, p in if p == .claudeCode { ClaudeAccount.shared.refreshIfStale(0) } }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 2) {
            Text(model.current?.title ?? "새 대화")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)

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
                Image(systemName: "clock")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("대화 기록")

            Menu {
                Button("이 대화를 Markdown으로 내보내기…") { model.exportMarkdown(all: false) }
                    .disabled(!model.canExport)
                Button("이 문서의 모든 대화 내보내기…") { model.exportMarkdown(all: true) }
                    .disabled(model.conversations.isEmpty)
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("내보내기")

            Button { model.newConversation() } label: { Image(systemName: "square.and.pencil") }
                .buttonStyle(QuietIconButtonStyle())
                .help("새 대화 (⌃⌘N)")

            Button { model.openSettings() } label: { Image(systemName: "gearshape") }
                .buttonStyle(QuietIconButtonStyle())
                .help("설정 (⌘,)")
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .frame(height: 34)
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles").font(.system(size: 26, weight: .light)).foregroundStyle(.tertiary)
            Text("이 PDF에 대해 물어보세요")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 7) {
                hint("text.quote", "텍스트를 선택하고 우클릭 → AI에게 묻기")
                hint("viewfinder", "⌃⌘C로 그림 영역을 캡처하거나, 스크린샷을 ⌘V로 붙여넣기")
                hint("doc.on.clipboard", "이미지 붙여넣기(⌘V)나 끌어다 놓기")
                hint("number", "답변의 페이지 번호를 누르면 이동")
            }
            if !model.documentReady {
                ProgressView().controlSize(.small).padding(.top, 4)
            }
        }
        .padding(24)
        .allowsHitTesting(false)
    }

    private func hint(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).frame(width: 16).foregroundStyle(.tertiary)
            Text(text)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }

    // MARK: Composer

    private var canSend: Bool {
        !(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && model.pendingImages.isEmpty && model.quotedText == nil)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                if let q = model.quotedText {
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: 1).fill(Color.secondary.opacity(0.35)).frame(width: 2)
                        Text(q).font(.system(size: 12)).lineLimit(3).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button { model.quotedText = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(QuietIconButtonStyle(size: 18))
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                }
                if !model.pendingImages.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(model.pendingImages) { img in
                                ZStack(alignment: .topTrailing) {
                                    Image(nsImage: img.thumbnail)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 64, height: 52)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
                                    Button { model.removePendingImage(img.id) } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 14))
                                            .foregroundStyle(.white, .black.opacity(0.55))
                                    }
                                    .buttonStyle(.plain)
                                    .offset(x: 5, y: -5)
                                }
                                .help(img.page.map { "p.\($0)에서 캡처" } ?? "이미지")
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 12)
                        .padding(.bottom, 2)
                    }
                }

                ChatInputView(text: $model.draft, focusToken: model.focusToken,
                              placeholder: "이 PDF에 대해 질문하세요…",
                              onSubmit: { model.send() },
                              onPasteImage: { data, type in model.addImage(data: data, mediaType: type, page: nil) })
                    .frame(minHeight: 44, maxHeight: 140)
                    .padding(.horizontal, 8)
                    .padding(.top, 6)

                HStack(spacing: 2) {
                    Button { model.startCapture() } label: { Image(systemName: "viewfinder") }
                        .buttonStyle(QuietIconButtonStyle())
                        .help("페이지 영역 캡처 (⌃⌘C)")
                    Button { model.chooseImage() } label: { Image(systemName: "photo") }
                        .buttonStyle(QuietIconButtonStyle())
                        .help("이미지 첨부")

                    Spacer(minLength: 6)

                    modelMenu

                    sendButton
                        .padding(.leading, 6)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.06), radius: 6, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.22), lineWidth: 1)
            )

            if let status = model.status {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .padding(.horizontal, 6)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    private var modelMenu: some View {
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
            HStack(spacing: 4) {
                Text(model.model).foregroundStyle(.primary)
                Text(model.provider.shortName).foregroundStyle(.tertiary)
            }
            .font(.system(size: 12))
            .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("제공자와 모델")
    }

    @ViewBuilder private var sendButton: some View {
        if model.isStreaming {
            Button { model.stop() } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.primary.opacity(0.85)))
                    .foregroundStyle(Color(nsColor: .textBackgroundColor))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .help("중단 (⎋)")
        } else {
            Button { model.send() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(canSend ? Color.accentColor : Color.secondary.opacity(0.35)))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help("전송 (⏎)")
        }
    }
}

/// Small borderless icon button with a soft hover background.
struct QuietIconButtonStyle: ButtonStyle {
    var size: CGFloat = 26

    func makeBody(configuration: Configuration) -> some View {
        QuietIconBody(configuration: configuration, size: size)
    }

    private struct QuietIconBody: View {
        let configuration: ButtonStyleConfiguration
        let size: CGFloat
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13))
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovering || configuration.isPressed ? 0.08 : 0)))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
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
        tv.font = NSFont.systemFont(ofSize: 14)
        tv.textContainerInset = NSSize(width: 4, height: 4)
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
        if let (data, type) = Self.imageOnPasteboard(NSPasteboard.general) {
            onPasteImage?(data, type)
            return
        }
        super.paste(sender)
    }

    /// A plain-text view disables Paste when the clipboard holds only an image, so ⌘V never
    /// reached `paste(_:)`. Enable it whenever there is an image to take.
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), Self.imageOnPasteboard(NSPasteboard.general) != nil {
            return true
        }
        return super.validateUserInterfaceItem(item)
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.readablePasteboardTypes + [.png, .tiff, .fileURL]
    }

    /// Image data from the clipboard: a screenshot (⌃⇧⌘4), an image copied from another app, or an
    /// image file copied in Finder. Text wins when the clipboard also has text (e.g. copied from a web page).
    static func imageOnPasteboard(_ pb: NSPasteboard) -> (Data, String)? {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first(where: { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }),
           let data = try? Data(contentsOf: url) {
            let type = UTType(filenameExtension: url.pathExtension)
            return (data, type?.conforms(to: .jpeg) == true ? "image/jpeg" : (type?.conforms(to: .png) == true ? "image/png" : "image/other"))
        }
        if pb.string(forType: .string) != nil { return nil }
        if let png = pb.data(forType: .png) { return (png, "image/png") }
        guard let image = NSImage(pasteboard: pb), let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return (png, "image/png")
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
