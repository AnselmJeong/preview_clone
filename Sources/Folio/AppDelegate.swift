import AppKit
import UniformTypeIdentifiers
import FolioCore

/// Shared services. The store opens lazily so a launch that only reads PDFs pays almost nothing.
@MainActor
final class AppServices {
    static let shared = AppServices()

    lazy var store: Store? = {
        do {
            return try Store(directory: Store.defaultDirectory())
        } catch {
            NSLog("Folio: could not open library database: \(error)")
            return nil
        }
    }()
}

extension Notification.Name {
    /// userInfo: ["documentID": String, "conversationID": String]
    static let folioOpenConversation = Notification.Name("folio.openConversation")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var openedFileAtLaunch = false
    private var keyMonitor: Any?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        UserDefaults.standard.register(defaults: [
            "NSQuitAlwaysKeepsWindows": true,
        ])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installShortcutMonitor()
        // Like Preview: with nothing to open, show the Open panel.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            if !self.openedFileAtLaunch && NSDocumentController.shared.documents.isEmpty && NSApp.windows.filter({ $0.isVisible }).isEmpty {
                NSDocumentController.shared.openDocument(nil)
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        openedFileAtLaunch = true
        for url in urls {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
            }
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NSDocumentController.shared.openDocument(nil) }
        return false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Matches the AI-sidebar shortcuts by physical key code, before menu key-equivalent matching.
    /// The menu's "0" equivalent depends on the characters the input source produces for ⌥0,
    /// which can differ (e.g. Korean 2-Set, remappers); the key code does not. ⌃⌘I is a hidden
    /// alternate that is easier to press.
    private func installShortcutMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.capsLock, .numericPad, .function])
            let isOptionCmd0 = event.keyCode == 29 && mods == [.command, .option]
            let isControlCmdI = event.keyCode == 34 && mods == [.command, .control]
            guard isOptionCmd0 || isControlCmdI else { return event }
            let handled = NSApp.sendAction(#selector(ReaderWindowController.toggleAISidebar(_:)), to: nil, from: nil)
            return handled ? nil : event
        }
    }

    // MARK: App-level actions

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.showWindow(nil)
        SettingsWindowController.shared.window?.makeKeyAndOrderFront(nil)
    }

    @objc func showHistorySearch(_ sender: Any?) {
        HistorySearchWindowController.shared.showWindow(nil)
        HistorySearchWindowController.shared.window?.makeKeyAndOrderFront(nil)
    }

    @objc func showHelpPage(_ sender: Any?) {
        if let url = URL(string: "https://github.com/AnselmJeong/preview_clone") { NSWorkspace.shared.open(url) }
    }

    static func setAsDefaultPDFApp() {
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: .pdf) { error in
            DispatchQueue.main.async {
                let alert = NSAlert()
                if let error {
                    alert.messageText = "기본 앱으로 설정하지 못했습니다"
                    alert.informativeText = error.localizedDescription
                } else {
                    alert.messageText = "Folio가 기본 PDF 앱으로 설정되었습니다"
                }
                alert.runModal()
            }
        }
    }
}
