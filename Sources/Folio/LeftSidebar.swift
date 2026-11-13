import AppKit
import PDFKit
import SwiftUI

enum SidebarTab: Int, CaseIterable, Identifiable {
    case toc, thumbnails, highlights, search
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .toc: return "목차"
        case .thumbnails: return "썸네일"
        case .highlights: return "하이라이트"
        case .search: return "검색"
        }
    }
}

final class TOCNode: Identifiable {
    let id = UUID()
    let title: String
    let pageIndex: Int?
    let destination: PDFDestination?
    var children: [TOCNode]?

    init(title: String, pageIndex: Int?, destination: PDFDestination?, children: [TOCNode]?) {
        self.title = title
        self.pageIndex = pageIndex
        self.destination = destination
        self.children = children
    }

    static func build(from outline: PDFOutline?, in doc: PDFDocument) -> [TOCNode] {
        guard let outline else { return [] }
        return (0..<outline.numberOfChildren).compactMap { i in
            guard let child = outline.child(at: i) else { return nil }
            var dest = child.destination
            if dest == nil, let action = child.action as? PDFActionGoTo { dest = action.destination }
            let pageIndex = dest?.page.map { doc.index(for: $0) }
            let kids = build(from: child, in: doc)
            return TOCNode(title: child.label ?? "", pageIndex: pageIndex, destination: dest, children: kids.isEmpty ? nil : kids)
        }
    }
}

struct HighlightItem: Identifiable {
    let id: ObjectIdentifier
    let annotation: PDFAnnotation
    let pageIndex: Int
    let text: String
    let note: String?
    let color: NSColor
}

struct SearchHit: Identifiable {
    let id: Int
    let selection: PDFSelection
    let pageIndex: Int
    let context: String
}

@MainActor
final class SidebarModel: ObservableObject {
    @Published var tab: SidebarTab = .toc
    @Published var toc: [TOCNode] = []
    @Published var highlights: [HighlightItem] = []
    @Published var searchHits: [SearchHit] = []
    @Published var searchQuery = ""
    @Published var searching = false
    @Published var currentHit: Int?
    weak var pdfView: PDFView?

    var onSelectTOC: ((TOCNode) -> Void)?
    var onSelectHighlight: ((HighlightItem) -> Void)?
    var onSelectHit: ((Int) -> Void)?
}

struct LeftSidebarView: View {
    @ObservedObject var model: SidebarModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $model.tab) {
                ForEach(SidebarTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .padding(8)
            Divider()
            switch model.tab {
            case .toc: tocView
            case .thumbnails: ThumbnailsView(pdfView: model.pdfView)
            case .highlights: highlightsView
            case .search: searchView
            }
        }
    }

    @ViewBuilder private var tocView: some View {
        if model.toc.isEmpty {
            placeholder("이 문서에는 목차가 없습니다")
        } else {
            List {
                OutlineGroup(model.toc, children: \.children) { node in
                    Button { model.onSelectTOC?(node) } label: {
                        HStack {
                            Text(node.title).lineLimit(2)
                            Spacer(minLength: 4)
                            if let p = node.pageIndex {
                                Text("\(p + 1)").foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder private var highlightsView: some View {
        if model.highlights.isEmpty {
            placeholder("하이라이트가 없습니다\n텍스트를 선택하고 ⌃⌘H를 누르세요")
        } else {
            List(model.highlights) { h in
                Button { model.onSelectHighlight?(h) } label: {
                    HStack(alignment: .top, spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: h.color)).frame(width: 4)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(h.text).lineLimit(4).font(.callout)
                            if let note = h.note, !note.isEmpty {
                                Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Text("p.\(h.pageIndex + 1)").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder private var searchView: some View {
        VStack(spacing: 0) {
            if model.searching {
                ProgressView().controlSize(.small).padding(6)
            }
            if model.searchHits.isEmpty {
                placeholder(model.searchQuery.isEmpty ? "⌘F로 검색하세요" : (model.searching ? "검색 중…" : "결과 없음"))
            } else {
                Text("\(model.searchHits.count)개 일치").font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
                List(model.searchHits) { hit in
                    Button { model.onSelectHit?(hit.id) } label: {
                        HStack(alignment: .top) {
                            Text(hit.context).lineLimit(3).font(.callout)
                            Spacer(minLength: 4)
                            Text("\(hit.pageIndex + 1)").foregroundStyle(.secondary).monospacedDigit()
                        }
                        .padding(.vertical, 1)
                        .background(model.currentHit == hit.id ? Color.accentColor.opacity(0.15) : Color.clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.sidebar)
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary).font(.callout).padding()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

struct ThumbnailsView: NSViewRepresentable {
    weak var pdfView: PDFView?

    func makeNSView(context: Context) -> PDFThumbnailView {
        let v = PDFThumbnailView()
        v.thumbnailSize = NSSize(width: 110, height: 140)
        v.maximumNumberOfColumns = 1
        v.backgroundColor = .clear
        v.pdfView = pdfView
        return v
    }

    func updateNSView(_ nsView: PDFThumbnailView, context: Context) {
        if nsView.pdfView !== pdfView { nsView.pdfView = pdfView }
    }
}
