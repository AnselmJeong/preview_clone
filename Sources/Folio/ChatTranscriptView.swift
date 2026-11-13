import AppKit
import SwiftUI
import WebKit
import FolioCore

/// Renders the conversation in one WKWebView (markdown-it + KaTeX, bundled). Created only when the
/// AI sidebar is first opened.
struct ChatTranscriptView: NSViewRepresentable {
    let messages: [MessageRecord]
    let streamingID: String?
    let version: Int
    let onCopy: (String) -> Void
    let onPage: (Int) -> Void
    let onAction: (TranscriptAction, String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(WeakScriptHandler(context.coordinator), name: "folio")
        let web = WKWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = context.coordinator
        web.allowsMagnification = false
        context.coordinator.web = web
        if let url = Bundle.main.url(forResource: "chat", withExtension: "html", subdirectory: "ChatRenderer") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            web.loadHTMLString("<p style='font-family:-apple-system;color:gray'>ChatRenderer 리소스를 찾을 수 없습니다. scripts/build.sh로 앱을 빌드하세요.</p>", baseURL: nil)
        }
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.onCopy = onCopy
        context.coordinator.onPage = onPage
        context.coordinator.onAction = onAction
        context.coordinator.update(messages: messages, streamingID: streamingID)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var web: WKWebView?
        var onCopy: ((String) -> Void)?
        var onPage: ((Int) -> Void)?
        var onAction: ((TranscriptAction, String) -> Void)?
        private var ready = false
        private var renderedIDs: [String] = []
        private var renderedContent: [String: String] = [:]
        private var renderedStreaming: String?
        private var latest: (messages: [MessageRecord], streaming: String?) = ([], nil)
        private var thumbnails: [String: String] = [:]  // attachment id → data URL

        func update(messages: [MessageRecord], streamingID: String?) {
            latest = (messages, streamingID)
            guard ready else { return }
            let ids = messages.map(\.id)
            if ids == renderedIDs {
                // Only re-render messages whose content or streaming state changed.
                let changed = messages.filter {
                    renderedContent[$0.id] != $0.content || ($0.id == streamingID) != ($0.id == renderedStreaming)
                }
                for m in changed { call("folio.update", payload(m, streaming: m.id == streamingID)) }
            } else {
                call("folio.setMessages", messages.map { payload($0, streaming: $0.id == streamingID) })
            }
            renderedIDs = ids
            renderedContent = Dictionary(messages.map { ($0.id, $0.content) }, uniquingKeysWith: { _, b in b })
            renderedStreaming = streamingID
        }

        private func payload(_ m: MessageRecord, streaming: Bool) -> [String: Any] {
            var p: [String: Any] = [
                "id": m.id,
                "role": m.role.rawValue,
                "content": m.content,
                "streaming": streaming,
                "error": m.isError,
            ]
            if let q = m.quotedText { p["quoted"] = q }
            if let page = m.pageRef, m.role == .user { p["page"] = page }
            let images = m.attachments.compactMap { a -> [String: Any]? in
                guard let url = thumbnail(for: a) else { return nil }
                var d: [String: Any] = ["src": url]
                if let page = a.page { d["page"] = page }
                return d
            }
            if !images.isEmpty { p["images"] = images }
            return p
        }

        private func thumbnail(for a: AttachmentRecord) -> String? {
            if let cached = thumbnails[a.id] { return cached }
            guard let image = NSImage(contentsOfFile: a.filePath) else { return nil }
            let thumb = ChatViewModel.thumbnail(image, maxEdge: 480)
            guard let tiff = thumb.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { return nil }
            let url = "data:image/jpeg;base64," + jpg.base64EncodedString()
            thumbnails[a.id] = url
            return url
        }

        private func call(_ fn: String, _ arg: Any) {
            guard let web, let data = try? JSONSerialization.data(withJSONObject: arg, options: [.fragmentsAllowed]),
                  let json = String(data: data, encoding: .utf8) else { return }
            web.evaluateJavaScript("\(fn)(\(json));", completionHandler: nil)
        }

        // MARK: Bridge

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
            switch action {
            case "ready":
                ready = true
                renderedIDs = []
                update(messages: latest.messages, streamingID: latest.streaming)
            case "copy":
                if let id = body["id"] as? String { onCopy?(id) }
            case "export", "regenerate", "delete":
                if let id = body["id"] as? String, let a = TranscriptAction(rawValue: action) { onAction?(a, id) }
            case "page":
                if let p = body["page"] as? Int { onPage?(p) } else if let s = body["page"] as? String, let p = Int(s) { onPage?(p) }
            default:
                break
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                if url.scheme == "http" || url.scheme == "https" || url.scheme == "mailto" {
                    NSWorkspace.shared.open(url)
                }
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}

enum TranscriptAction: String {
    case export, regenerate, delete
}

/// Avoids the retain cycle WKUserContentController creates with its handlers.
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
