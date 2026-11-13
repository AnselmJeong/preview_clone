import AppKit
import PDFKit
import CoreImage

@MainActor
protocol ReaderPDFViewDelegate: AnyObject {
    func pdfView(_ view: ReaderPDFView, didCapture image: NSImage, pngData: Data, page: Int)
    func pdfViewDidCancelCapture(_ view: ReaderPDFView)
    func pdfView(_ view: ReaderPDFView, ask kind: AskKind, text: String)
    func pdfView(_ view: ReaderPDFView, highlightWith color: NSColor)
    func pdfView(_ view: ReaderPDFView, recolor annotation: PDFAnnotation, color: NSColor)
    func pdfView(_ view: ReaderPDFView, editNoteFor annotation: PDFAnnotation)
    func pdfView(_ view: ReaderPDFView, remove annotation: PDFAnnotation)
}

enum AskKind {
    case ask, explain, translate
}

enum HighlightColor: Int, CaseIterable {
    case yellow, green, blue, pink, purple

    var name: String {
        switch self {
        case .yellow: return "노랑"
        case .green: return "초록"
        case .blue: return "파랑"
        case .pink: return "분홍"
        case .purple: return "보라"
        }
    }

    var color: NSColor {
        switch self {
        case .yellow: return NSColor(srgbRed: 1.00, green: 0.89, blue: 0.30, alpha: 1)
        case .green: return NSColor(srgbRed: 0.55, green: 0.90, blue: 0.45, alpha: 1)
        case .blue: return NSColor(srgbRed: 0.50, green: 0.75, blue: 1.00, alpha: 1)
        case .pink: return NSColor(srgbRed: 1.00, green: 0.60, blue: 0.75, alpha: 1)
        case .purple: return NSColor(srgbRed: 0.78, green: 0.62, blue: 1.00, alpha: 1)
        }
    }

    var swatch: NSImage {
        let img = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
            self.color.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        return img
    }
}

/// PDFView with region capture, a reading-oriented context menu, and night mode.
final class ReaderPDFView: PDFView {
    weak var readerDelegate: ReaderPDFViewDelegate?

    // MARK: Night mode

    var nightMode = false {
        didSet { applyNightMode() }
    }

    private func applyNightMode() {
        wantsLayer = true
        layerUsesCoreImageFilters = true
        if nightMode {
            let invert = CIFilter(name: "CIColorInvert")!
            let hue = CIFilter(name: "CIHueAdjust")!
            hue.setValue(Double.pi, forKey: kCIInputAngleKey)
            contentFilters = [invert, hue]
            backgroundColor = NSColor(white: 0.85, alpha: 1)  // inverted → dark gray
        } else {
            contentFilters = []
            backgroundColor = NSColor.windowBackgroundColor
        }
    }

    // MARK: Region capture

    private lazy var captureOverlay: CaptureOverlayView = {
        let v = CaptureOverlayView()
        v.onFinish = { [weak self] rect in self?.finishCapture(overlayRect: rect) }
        v.onCancel = { [weak self] in self?.endCapture(cancelled: true) }
        return v
    }()
    private(set) var isCapturing = false

    func beginCapture() {
        guard !isCapturing else { return }
        isCapturing = true
        captureOverlay.frame = bounds
        captureOverlay.autoresizingMask = [.width, .height]
        captureOverlay.selection = nil
        addSubview(captureOverlay)
        window?.makeFirstResponder(captureOverlay)
        window?.invalidateCursorRects(for: captureOverlay)
    }

    func endCapture(cancelled: Bool) {
        guard isCapturing else { return }
        isCapturing = false
        captureOverlay.removeFromSuperview()
        window?.makeFirstResponder(self)
        if cancelled { readerDelegate?.pdfViewDidCancelCapture(self) }
    }

    private func finishCapture(overlayRect: NSRect) {
        let rect = convert(overlayRect, from: captureOverlay)
        endCapture(cancelled: false)
        guard rect.width > 4, rect.height > 4, let result = renderRegion(rect) else {
            readerDelegate?.pdfViewDidCancelCapture(self)
            return
        }
        readerDelegate?.pdfView(self, didCapture: result.0, pngData: result.1, page: result.2)
    }

    /// Renders the selected view rectangle from the page's vector content at ≥2× (up to ~2400 px).
    private func renderRegion(_ viewRect: NSRect) -> (NSImage, Data, Int)? {
        let center = NSPoint(x: viewRect.midX, y: viewRect.midY)
        guard let page = page(for: center, nearest: true), let doc = document else { return nil }
        let pageNumber = doc.index(for: page) + 1
        var pageRect = convert(viewRect, to: page)
        let box = page.bounds(for: .cropBox)
        pageRect = pageRect.intersection(box)
        guard !pageRect.isEmpty else { return nil }

        let longest = max(pageRect.width, pageRect.height)
        let scale = max(2.0, min(6.0, 2400.0 / longest))
        let pixelW = Int((pageRect.width * scale).rounded())
        let pixelH = Int((pageRect.height * scale).rounded())
        guard pixelW > 0, pixelH > 0,
              let ctx = CGContext(data: nil, width: pixelW, height: pixelH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: pixelW, height: pixelH))
        ctx.scaleBy(x: scale, y: scale)
        // Page space here is unrotated: draw the page so `pageRect` lands at the origin.
        ctx.translateBy(x: -pageRect.minX, y: -pageRect.minY)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let rotation = page.rotation
        page.rotation = 0
        // draw(with:to:) maps the box origin to (0,0); compensate so page coordinates stay absolute.
        ctx.translateBy(x: box.minX, y: box.minY)
        page.draw(with: .cropBox, to: ctx)
        page.rotation = rotation
        NSGraphicsContext.restoreGraphicsState()

        guard var cg = ctx.makeImage() else { return nil }
        if rotation != 0, let rotated = Self.rotate(cg, degrees: rotation) { cg = rotated }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale))
        return (image, png, pageNumber)
    }

    private static func rotate(_ image: CGImage, degrees: Int) -> CGImage? {
        let quarter = ((degrees % 360) + 360) % 360 / 90
        let w = image.width, h = image.height
        let (outW, outH) = quarter % 2 == 1 ? (h, w) : (w, h)
        guard let ctx = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // PDF rotation is clockwise.
        ctx.translateBy(x: CGFloat(outW) / 2, y: CGFloat(outH) / 2)
        ctx.rotate(by: -CGFloat(quarter) * .pi / 2)
        ctx.draw(image, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2, width: CGFloat(w), height: CGFloat(h)))
        return ctx.makeImage()
    }

    // MARK: Keyboard

    /// Single-key reading shortcuts, active only while the page view has focus (so the find field
    /// and chat composer keep their own arrow keys and letters).
    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard mods.isEmpty, let key = event.charactersIgnoringModifiers?.unicodeScalars.first else {
            super.keyDown(with: event)
            return
        }
        switch Int(key.value) {
        case NSLeftArrowFunctionKey, NSPageUpFunctionKey:
            goToPreviousPage(nil)
        case NSRightArrowFunctionKey, NSPageDownFunctionKey:
            goToNextPage(nil)
        case NSHomeFunctionKey:
            goToFirstPage(nil)
        case NSEndFunctionKey:
            goToLastPage(nil)
        default:
            if hasTextSelection, let color = Self.highlightColor(forKey: Character(key)) {
                readerDelegate?.pdfView(self, highlightWith: color.color)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    private var hasTextSelection: Bool {
        guard let text = currentSelection?.string else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// H = yellow; 1–5 = the five highlight colours in menu order.
    static func highlightColor(forKey c: Character) -> HighlightColor? {
        switch c {
        case "h", "H": return .yellow
        case "1"..."5": return HighlightColor(rawValue: Int(String(c))! - 1)
        default: return nil
        }
    }

    // MARK: Context menu

    private var menuAnnotation: PDFAnnotation?

    func highlightAnnotation(at viewPoint: NSPoint) -> PDFAnnotation? {
        guard let page = page(for: viewPoint, nearest: false) else { return nil }
        let p = convert(viewPoint, to: page)
        for a in page.annotations.reversed() where a.type == "Highlight" {
            if let quads = a.quadrilateralPoints, quads.count >= 4 {
                var i = 0
                while i + 3 < quads.count {
                    let pts = (0..<4).map { quads[i + $0].pointValue }
                    let xs = pts.map(\.x), ys = pts.map(\.y)
                    let r = NSRect(x: xs.min()! + a.bounds.minX, y: ys.min()! + a.bounds.minY,
                                   width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
                    if r.contains(p) { return a }
                    i += 4
                }
            } else if a.bounds.contains(p) {
                return a
            }
        }
        return nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let base = super.menu(for: event) ?? NSMenu()
        let menu = NSMenu()
        let point = convert(event.locationInWindow, from: nil)

        if let annotation = highlightAnnotation(at: point) {
            menuAnnotation = annotation
            let colors = NSMenu()
            for c in HighlightColor.allCases {
                let item = NSMenuItem(title: c.name, action: #selector(recolorFromMenu(_:)), keyEquivalent: "")
                item.tag = c.rawValue
                item.image = c.swatch
                item.target = self
                colors.addItem(item)
            }
            let colorItem = NSMenuItem(title: "하이라이트 색상", action: nil, keyEquivalent: "")
            colorItem.submenu = colors
            menu.addItem(colorItem)
            let note = NSMenuItem(title: (annotation.contents?.isEmpty == false) ? "메모 편집…" : "메모 추가…",
                                  action: #selector(editNoteFromMenu(_:)), keyEquivalent: "")
            note.target = self
            menu.addItem(note)
            let remove = NSMenuItem(title: "하이라이트 삭제", action: #selector(removeFromMenu(_:)), keyEquivalent: "")
            remove.target = self
            menu.addItem(remove)
            menu.addItem(.separator())
        }

        if let text = currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            let colors = NSMenu()
            for c in HighlightColor.allCases {
                let item = NSMenuItem(title: c.name, action: #selector(highlightFromMenu(_:)), keyEquivalent: "")
                item.tag = c.rawValue
                item.image = c.swatch
                item.target = self
                colors.addItem(item)
            }
            let h = NSMenuItem(title: "하이라이트", action: nil, keyEquivalent: "")
            h.submenu = colors
            menu.addItem(h)
            menu.addItem(.separator())
            for (title, tag) in [("AI에게 묻기", 0), ("설명해줘", 1), ("번역해줘", 2)] {
                let item = NSMenuItem(title: title, action: #selector(askFromMenu(_:)), keyEquivalent: "")
                item.tag = tag
                item.target = self
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        // Keep PDFKit's useful items (copy, look up, zoom, display modes...).
        for item in base.items {
            base.removeItem(item)
            menu.addItem(item)
        }
        return menu
    }

    @objc private func highlightFromMenu(_ sender: NSMenuItem) {
        let color = HighlightColor(rawValue: sender.tag)?.color ?? HighlightColor.yellow.color
        readerDelegate?.pdfView(self, highlightWith: color)
    }

    @objc private func recolorFromMenu(_ sender: NSMenuItem) {
        guard let a = menuAnnotation else { return }
        readerDelegate?.pdfView(self, recolor: a, color: HighlightColor(rawValue: sender.tag)?.color ?? HighlightColor.yellow.color)
    }

    @objc private func editNoteFromMenu(_ sender: NSMenuItem) {
        guard let a = menuAnnotation else { return }
        readerDelegate?.pdfView(self, editNoteFor: a)
    }

    @objc private func removeFromMenu(_ sender: NSMenuItem) {
        guard let a = menuAnnotation else { return }
        readerDelegate?.pdfView(self, remove: a)
    }

    @objc private func askFromMenu(_ sender: NSMenuItem) {
        guard let text = currentSelection?.string else { return }
        let kind: AskKind = sender.tag == 1 ? .explain : (sender.tag == 2 ? .translate : .ask)
        readerDelegate?.pdfView(self, ask: kind, text: text)
    }
}

/// Dims the page, tracks the drag, and draws the capture rectangle. Esc cancels.
final class CaptureOverlayView: NSView {
    var selection: NSRect? { didSet { needsDisplay = true } }
    var onFinish: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?
    private var start: NSPoint?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        selection = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let p = convert(event.locationInWindow, from: nil)
        selection = NSRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
    }

    override func mouseUp(with event: NSEvent) {
        let rect = selection ?? .zero
        start = nil
        onFinish?(rect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.25).setFill()
        let path = NSBezierPath(rect: bounds)
        if let sel = selection {
            path.appendRect(sel)
            path.windingRule = .evenOdd
        }
        path.fill()
        if let sel = selection {
            NSColor.controlAccentColor.setStroke()
            let border = NSBezierPath(rect: sel.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1.5
            border.stroke()
        }
    }
}
