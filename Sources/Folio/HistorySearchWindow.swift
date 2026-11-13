import AppKit
import SwiftUI
import FolioCore

/// Searches every conversation of every PDF and reopens the document at that conversation.
@MainActor
final class HistorySearchWindowController: NSWindowController {
    static let shared = HistorySearchWindowController()

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 480),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: true)
        window.title = "모든 대화 검색"
        window.contentViewController = NSHostingController(rootView: HistorySearchView())
        window.center()
        window.setFrameAutosaveName("FolioHistorySearch")
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    static func open(_ hit: MessageSearchHit) {
        var url = hit.documentPath.map { URL(fileURLWithPath: $0) }
        if url == nil || !FileManager.default.fileExists(atPath: url!.path) {
            let alert = NSAlert()
            alert.messageText = "PDF를 찾을 수 없습니다"
            alert.informativeText = "마지막 위치: \(hit.documentPath ?? "알 수 없음")\n파일을 옮겼다면 직접 찾아 주세요. 내용이 같으면 대화 기록이 그대로 연결됩니다."
            alert.addButton(withTitle: "찾기…")
            alert.addButton(withTitle: "취소")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.pdf]
            guard panel.runModal() == .OK, let picked = panel.url else { return }
            url = picked
        }
        guard let url else { return }
        let info: [String: Any] = ["documentID": hit.documentID, "conversationID": hit.conversationID, "path": url.path]
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error { NSApp.presentError(error); return }
            // Already-open windows handle it now; a freshly opened one picks it up once its identity resolves.
            NotificationCenter.default.post(name: .folioOpenConversation, object: nil, userInfo: info)
        }
    }
}

struct HistorySearchView: View {
    @State private var query = ""
    @State private var hits: [MessageSearchHit] = []

    var body: some View {
        VStack(spacing: 0) {
            TextField("검색어", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(10)
                .onSubmit(search)
                .onChange(of: query) { _, _ in search() }
            Divider()
            if hits.isEmpty {
                Spacer()
                Text(query.isEmpty ? "모든 PDF의 AI 대화에서 검색합니다" : "결과 없음").foregroundStyle(.secondary)
                Spacer()
            } else {
                List(hits) { hit in
                    Button { HistorySearchWindowController.open(hit) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(hit.documentTitle ?? (hit.documentPath.map { ($0 as NSString).lastPathComponent } ?? "문서"))
                                .font(.headline)
                            Text(hit.conversationTitle).font(.caption).foregroundStyle(.secondary)
                            Text(hit.snippet).font(.callout).lineLimit(3)
                        }
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 300)
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let store = AppServices.shared.store else { hits = []; return }
        hits = (try? store.searchMessages(q)) ?? []
    }
}
