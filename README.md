# Folio (preview_clone)

macOS Preview를 PDF 읽기 용도로 대체하는 가볍고 빠른 PDF 리더입니다. 주석·서명 같은 기능은 빼고, 읽기(보기 모드, 찾기, 목차, 하이라이트)와 열린 PDF에 대해 대화하는 우측 AI 사이드바만 넣었습니다. 설계와 결정 사항은 [PLAN.md](PLAN.md)를 보세요.

## 빌드와 설치

필요한 것: macOS 14 이상, Xcode 또는 Command Line Tools (Swift 5.9+).

```bash
scripts/build.sh            # build/Folio.app 생성
scripts/build.sh install    # /Applications(또는 ~/Applications)에 설치
scripts/test.sh             # 핵심 로직 단위 테스트 (Xcode가 있으면 `swift test`도 가능)
```

설치 후 Finder에서 PDF를 선택하고 ⌘I → "다음으로 열기"에서 Folio를 고른 뒤 "모두 변경"을 누르거나, Folio 설정(⌘,) → 일반 → "Folio를 기본 PDF 앱으로 설정"을 누르세요.

## AI 제공자

| 제공자 | 설정 |
|---|---|
| **Claude 구독** | [Claude Code](https://claude.com/claude-code)를 설치하고 터미널에서 `claude`를 한 번 실행해 로그인합니다. Folio는 그 CLI(`claude -p`)를 실행해 대화하며, 로그인 정보를 읽거나 저장하지 않습니다. 사용량은 Claude Code 사용 한도에서 차감됩니다. |
| **Ollama (ollama.com)** | 설정 → AI 제공자에서 API 키(ollama.com/settings/keys)를 넣습니다. Base URL을 `http://localhost:11434/v1`로 바꾸면 로컬 Ollama도 됩니다. |
| **Claude API 키** (선택) | Anthropic Console API 키. 종량제입니다. |

## 단축키

전체 목록은 설정(⌘,) → 단축키 탭에도 있습니다.

| 동작 | 키 |
|---|---|
| 찾기 / 다음 / 이전 | ⌘F / ⌘G / ⇧⌘G |
| 보기 모드 (단일, 연속, 두 페이지, 두 페이지 연속) | ⌘1–⌘4 |
| 실제 크기 / 확대 / 축소 / 페이지 맞춤 / 너비 맞춤 | ⌘0 / ⌘+ / ⌘− / ⌘9 / ⌥⌘9 |
| 사이드바 / 목차 / 썸네일 / 하이라이트 목록 | ⌥⌘S / ⌥⌘1 / ⌥⌘2 / ⌥⌘3 |
| AI 사이드바 열기·닫기 | ⌥⌘0 |
| 이전 / 다음 페이지 | ← / →, Page Up / Page Down (PDF 화면에 포커스), ⌥↑ / ⌥↓ |
| 첫 / 마지막 페이지 | Home / End, ⌘↑ / ⌘↓ |
| 하이라이트 (텍스트 선택 후) | H 또는 ⌃⌘H = 노랑, 1–5 또는 ⌃⌘1–5 = 노랑·초록·파랑·분홍·보라 |
| 그림 영역 캡처해서 AI에 첨부 | ⌃⇧⌘4 (드래그, ⎋ 취소) |
| 선택 영역 AI에게 묻기 / 번역 | ⌃⌘A / ⌃⌘T |
| 새 대화 / 대화 내보내기 / 모든 대화 검색 | ⌃⌘N / ⇧⌘E / ⇧⌘F |
| 페이지로 이동 | ⌥⌘G |
| 야간 모드 | ⌥⌘N |

## 데이터

- 대화 기록, 페이지 텍스트 캐시: `~/Library/Application Support/Folio/library.sqlite`
- 첨부 이미지: `~/Library/Application Support/Folio/attachments/`
- API 키: macOS 키체인

문서는 파일 경로가 아니라 내용(SHA-256 → PDF `/ID` → 텍스트 지문)으로 식별하므로, PDF를 옮기거나 하이라이트를 저장해도 대화 기록이 이어집니다.

## 구조

```
Sources/FolioCore   SQLite 저장소, 문서 식별, AI 제공자, 컨텍스트 조립, Markdown 내보내기 (테스트 대상)
Sources/Folio       AppKit 앱: 문서, 뷰어, 사이드바, 채팅 UI, 설정
Resources           Info.plist, 채팅 렌더러(markdown-it, KaTeX)
```

서드파티: [markdown-it](https://github.com/markdown-it/markdown-it) (MIT), [KaTeX](https://katex.org) (MIT). 라이선스는 `Resources/ChatRenderer/`에 있습니다.
