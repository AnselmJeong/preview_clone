import AppKit

/// Builds the menu bar in code (no nib). Document actions travel the responder chain to
/// `ReaderWindowController`; app actions go to `AppDelegate`.
@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(fileMenu()))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(viewMenu()))
        main.addItem(submenu(goMenu()))
        main.addItem(submenu(toolsMenu()))
        let window = windowMenu()
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        let help = NSMenu(title: "도움말")
        help.addItem(item("Folio 저장소 열기", #selector(AppDelegate.showHelpPage(_:))))
        main.addItem(submenu(help))
        NSApp.helpMenu = help
        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    static func item(_ title: String, _ action: Selector?, _ key: String = "",
                     _ mods: NSEvent.ModifierFlags = [.command], tag: Int = 0) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = key.isEmpty ? [] : mods
        i.tag = tag
        return i
    }

    private static func appMenu() -> NSMenu {
        let m = NSMenu(title: "Folio")
        m.addItem(item("Folio에 관하여", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        m.addItem(.separator())
        m.addItem(item("설정…", #selector(AppDelegate.showSettings(_:)), ","))
        m.addItem(.separator())
        let services = NSMenu(title: "서비스")
        let s = NSMenuItem(title: "서비스", action: nil, keyEquivalent: "")
        s.submenu = services
        NSApp.servicesMenu = services
        m.addItem(s)
        m.addItem(.separator())
        m.addItem(item("Folio 가리기", #selector(NSApplication.hide(_:)), "h"))
        m.addItem(item("기타 가리기", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        m.addItem(item("모두 보기", #selector(NSApplication.unhideAllApplications(_:))))
        m.addItem(.separator())
        m.addItem(item("Folio 종료", #selector(NSApplication.terminate(_:)), "q"))
        return m
    }

    private static func fileMenu() -> NSMenu {
        let m = NSMenu(title: "파일")
        m.addItem(item("열기…", #selector(NSDocumentController.openDocument(_:)), "o"))
        let recent = NSMenuItem(title: "최근 사용 항목 열기", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "최근 사용 항목 열기")
        recentMenu.addItem(item("메뉴 지우기", #selector(NSDocumentController.clearRecentDocuments(_:))))
        recent.submenu = recentMenu
        m.addItem(recent)
        m.addItem(.separator())
        m.addItem(item("닫기", #selector(NSWindow.performClose(_:)), "w"))
        m.addItem(item("저장", #selector(NSDocument.save(_:)), "s"))
        m.addItem(item("Finder에서 보기", #selector(ReaderWindowController.revealInFinder(_:)), "r", [.command, .option]))
        m.addItem(.separator())
        m.addItem(item("대화를 Markdown으로 내보내기…", #selector(ReaderWindowController.exportChat(_:)), "e", [.command, .shift]))
        m.addItem(item("모든 대화 검색…", #selector(AppDelegate.showHistorySearch(_:)), "f", [.command, .shift]))
        m.addItem(.separator())
        m.addItem(item("인쇄…", #selector(ReaderWindowController.printDocument(_:)), "p"))
        return m
    }

    private static func editMenu() -> NSMenu {
        let m = NSMenu(title: "편집")
        m.addItem(item("실행 취소", Selector(("undo:")), "z"))
        m.addItem(item("실행 복귀", Selector(("redo:")), "z", [.command, .shift]))
        m.addItem(.separator())
        m.addItem(item("오려두기", #selector(NSText.cut(_:)), "x"))
        m.addItem(item("복사하기", #selector(NSText.copy(_:)), "c"))
        m.addItem(item("붙여넣기", #selector(NSText.paste(_:)), "v"))
        m.addItem(item("모두 선택", #selector(NSText.selectAll(_:)), "a"))
        m.addItem(.separator())
        let find = NSMenu(title: "찾기")
        find.addItem(item("찾기…", #selector(ReaderWindowController.focusFind(_:)), "f"))
        find.addItem(item("다음 찾기", #selector(ReaderWindowController.findNext(_:)), "g"))
        find.addItem(item("이전 찾기", #selector(ReaderWindowController.findPrevious(_:)), "g", [.command, .shift]))
        find.addItem(item("선택 항목으로 찾기", #selector(ReaderWindowController.useSelectionForFind(_:)), "e"))
        let f = NSMenuItem(title: "찾기", action: nil, keyEquivalent: "")
        f.submenu = find
        m.addItem(f)
        return m
    }

    private static func viewMenu() -> NSMenu {
        let m = NSMenu(title: "보기")
        m.addItem(item("단일 페이지", #selector(ReaderWindowController.setDisplayModeFromMenu(_:)), "1", [.command], tag: 0))
        m.addItem(item("단일 페이지 연속", #selector(ReaderWindowController.setDisplayModeFromMenu(_:)), "2", [.command], tag: 1))
        m.addItem(item("두 페이지", #selector(ReaderWindowController.setDisplayModeFromMenu(_:)), "3", [.command], tag: 2))
        m.addItem(item("두 페이지 연속", #selector(ReaderWindowController.setDisplayModeFromMenu(_:)), "4", [.command], tag: 3))
        m.addItem(item("책 모드 (표지 단독)", #selector(ReaderWindowController.toggleBookMode(_:))))
        m.addItem(.separator())
        m.addItem(item("실제 크기", #selector(ReaderWindowController.zoomActualSize(_:)), "0"))
        m.addItem(item("확대", #selector(ReaderWindowController.zoomIn(_:)), "+"))
        m.addItem(item("확대", #selector(ReaderWindowController.zoomIn(_:)), "=").hiddenAlternate())
        m.addItem(item("축소", #selector(ReaderWindowController.zoomOut(_:)), "-"))
        m.addItem(item("페이지 맞춤", #selector(ReaderWindowController.zoomToFit(_:)), "9"))
        m.addItem(item("너비 맞춤", #selector(ReaderWindowController.zoomToWidth(_:)), "9", [.command, .option]))
        m.addItem(.separator())
        m.addItem(item("왼쪽으로 회전", #selector(ReaderWindowController.rotateLeft(_:)), "l"))
        m.addItem(item("오른쪽으로 회전", #selector(ReaderWindowController.rotateRight(_:)), "r"))
        m.addItem(.separator())
        m.addItem(item("야간 모드", #selector(ReaderWindowController.toggleNightMode(_:)), "n", [.command, .option]))
        m.addItem(.separator())
        m.addItem(item("사이드바", #selector(ReaderWindowController.toggleLeftSidebar(_:)), "s", [.command, .option]))
        m.addItem(item("목차", #selector(ReaderWindowController.showTOC(_:)), "1", [.command, .option]))
        m.addItem(item("썸네일", #selector(ReaderWindowController.showThumbnails(_:)), "2", [.command, .option]))
        m.addItem(item("하이라이트 목록", #selector(ReaderWindowController.showHighlightList(_:)), "3", [.command, .option]))
        m.addItem(item("검색 결과", #selector(ReaderWindowController.showSearchResults(_:)), "4", [.command, .option]))
        m.addItem(.separator())
        m.addItem(item("AI 사이드바", #selector(ReaderWindowController.toggleAISidebar(_:)), "0", [.command, .option]))
        m.addItem(.separator())
        m.addItem(item("전체 화면", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return m
    }

    private static func goMenu() -> NSMenu {
        let m = NSMenu(title: "이동")
        m.addItem(item("이전 페이지", #selector(ReaderWindowController.goPreviousPage(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.option]))
        m.addItem(item("다음 페이지", #selector(ReaderWindowController.goNextPage(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.option]))
        m.addItem(item("첫 페이지", #selector(ReaderWindowController.goFirstPage(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command]))
        m.addItem(item("마지막 페이지", #selector(ReaderWindowController.goLastPage(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.command]))
        m.addItem(.separator())
        m.addItem(item("뒤로", #selector(ReaderWindowController.goBack(_:)), "["))
        m.addItem(item("앞으로", #selector(ReaderWindowController.goForward(_:)), "]"))
        m.addItem(.separator())
        m.addItem(item("페이지로 이동…", #selector(ReaderWindowController.goToPagePrompt(_:)), "g", [.command, .option]))
        return m
    }

    private static func toolsMenu() -> NSMenu {
        let m = NSMenu(title: "도구")
        m.addItem(item("하이라이트", #selector(ReaderWindowController.highlightSelection(_:)), "h", [.command, .control]))
        let colors = NSMenu(title: "하이라이트 색상")
        for c in HighlightColor.allCases {
            let i = item(c.name, #selector(ReaderWindowController.highlightWithColorItem(_:)), "\(c.rawValue + 1)", [.command, .control], tag: c.rawValue)
            i.image = c.swatch
            colors.addItem(i)
        }
        m.addItem(submenu(colors))
        m.addItem(item("영역 캡처해서 AI에 첨부", #selector(ReaderWindowController.startRegionCapture(_:)), "c", [.command, .control]))
        m.addItem(.separator())
        m.addItem(item("선택 영역을 AI에게 묻기", #selector(ReaderWindowController.askAIAboutSelection(_:)), "a", [.command, .control]))
        m.addItem(item("선택 영역 설명", #selector(ReaderWindowController.explainSelection(_:)), "", []))
        m.addItem(item("선택 영역 번역", #selector(ReaderWindowController.translateSelection(_:)), "t", [.command, .control]))
        m.addItem(.separator())
        m.addItem(item("새 대화", #selector(ReaderWindowController.newConversation(_:)), "n", [.command, .control]))
        return m
    }

    private static func windowMenu() -> NSMenu {
        let m = NSMenu(title: "윈도우")
        m.addItem(item("최소화", #selector(NSWindow.performMiniaturize(_:)), "m"))
        m.addItem(item("확대/축소", #selector(NSWindow.performZoom(_:))))
        m.addItem(.separator())
        m.addItem(item("모두 앞으로 가져오기", #selector(NSApplication.arrangeInFront(_:))))
        return m
    }
}

private extension NSMenuItem {
    /// Same action under a second shortcut (e.g. ⌘= for zoom in), hidden from the menu.
    func hiddenAlternate() -> NSMenuItem {
        isHidden = true
        allowsKeyEquivalentWhenHidden = true
        return self
    }
}
