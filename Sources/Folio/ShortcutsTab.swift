import SwiftUI

/// Settings → 단축키: a read-only reference of every keyboard shortcut.
struct ShortcutsTab: View {
    struct ShortcutGroup: Identifiable {
        let title: String
        let note: String?
        let rows: [(String, String)]
        var id: String { title }
    }

    static let groups: [ShortcutGroup] = [
        ShortcutGroup(title: "페이지 이동", note: "PDF 화면을 클릭해 포커스가 있을 때 동작합니다.", rows: [
            ("이전 / 다음 페이지", "← / →"),
            ("이전 / 다음 페이지", "Page Up / Page Down"),
            ("이전 / 다음 페이지 (어디서나)", "⌥↑ / ⌥↓"),
            ("첫 / 마지막 페이지", "Home / End, ⌘↑ / ⌘↓"),
            ("뒤로 / 앞으로 (이동 기록)", "⌘[ / ⌘]"),
            ("페이지로 이동…", "⌥⌘G"),
        ]),
        ShortcutGroup(title: "하이라이트", note: "텍스트를 선택한 상태에서 누르세요. 색 변경·메모·삭제는 하이라이트를 우클릭합니다.", rows: [
            ("노랑 하이라이트", "H  또는  ⌃⌘H"),
            ("색 지정 (노랑·초록·파랑·분홍·보라)", "1 – 5  또는  ⌃⌘1 – ⌃⌘5"),
            ("하이라이트 목록 보기", "⌥⌘3"),
        ]),
        ShortcutGroup(title: "AI 사이드바", note: nil, rows: [
            ("AI 사이드바 열기 / 닫기", "⌥⌘0"),
            ("선택 영역을 AI에게 묻기", "⌃⌘A"),
            ("선택 영역 번역", "⌃⌘T"),
            ("그림 영역 캡처해서 첨부 (드래그, ⎋ 취소)", "⌃⇧⌘4"),
            ("새 대화", "⌃⌘N"),
            ("메시지 보내기 / 줄바꿈", "↩ / ⇧↩"),
            ("대화를 Markdown으로 내보내기", "⇧⌘E"),
            ("모든 대화 검색", "⇧⌘F"),
        ]),
        ShortcutGroup(title: "보기", note: nil, rows: [
            ("단일 · 연속 · 두 페이지 · 두 페이지 연속", "⌘1 – ⌘4"),
            ("실제 크기 / 확대 / 축소", "⌘0 / ⌘+ / ⌘−"),
            ("페이지 맞춤 / 너비 맞춤", "⌘9 / ⌥⌘9"),
            ("왼쪽 / 오른쪽으로 회전", "⌘L / ⌘R"),
            ("왼쪽 사이드바", "⌥⌘S"),
            ("목차 / 썸네일 / 하이라이트 / 검색 결과", "⌥⌘1 – ⌥⌘4"),
            ("야간 모드", "⌥⌘N"),
            ("전체 화면", "⌃⌘F"),
        ]),
        ShortcutGroup(title: "찾기 · 파일", note: nil, rows: [
            ("찾기 / 다음 / 이전", "⌘F / ⌘G / ⇧⌘G"),
            ("선택 항목으로 찾기", "⌘E"),
            ("열기 / 닫기 / 저장", "⌘O / ⌘W / ⌘S"),
            ("Finder에서 보기", "⌥⌘R"),
            ("인쇄", "⌘P"),
            ("설정", "⌘,"),
        ]),
    ]

    var body: some View {
        Form {
            ForEach(Self.groups) { g in
                Section {
                    ForEach(Array(g.rows.enumerated()), id: \.offset) { _, row in
                        LabeledContent(row.0) {
                            Text(row.1)
                                .font(.system(.body, design: .rounded).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                } header: {
                    Text(g.title)
                } footer: {
                    if let note = g.note {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
