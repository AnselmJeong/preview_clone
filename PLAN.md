# PLAN — Preview를 대체하는 가볍고 빠른 PDF 리더 + AI 사이드바

> 상태: 승인됨, Swift로 구현 중 (개인 사용 전제)
>
> 구현하면서 바꾼 점: Xcode 프로젝트/XcodeGen 대신 Swift Package + `scripts/build.sh`로 앱 번들을 만들고, GRDB 대신 시스템 SQLite3를 직접 씁니다(외부 의존성 0). 스캔본 OCR(4.5)은 다음 단계로 미뤘습니다.
> 작업 이름: **Folio** (가칭, 바꾸기 쉬움)

## 1. 목표와 원칙

macOS 기본 앱 Preview를 **PDF 읽기 용도로 대체**하는 기본 PDF 리더를 만든다. 주석 도구, 서명, 양식 편집, 이미지 편집, 페이지 재배열 같은 기능은 모두 뺀다. 남기는 것은 읽기에 필요한 것(보기 모드, 찾기, 목차, 하이라이트)과, 열려 있는 PDF에 대해 대화할 수 있는 **우측 AI 사이드바**다.

설계 원칙은 세 가지다.

1. **읽기 경험이 최우선이다.** 앱 실행과 PDF 열기는 Preview와 같거나 더 빨라야 하며, AI 기능은 사이드바를 처음 열 때까지 아무 비용도 들지 않아야 한다(지연 로딩).
2. **기능은 적게, 완성도는 높게.** 새 기능은 "Preview 대신 매일 쓰는 데 필요한가"를 기준으로 넣는다.
3. **데이터는 로컬에.** 대화 기록, 하이라이트 메타데이터, 설정은 모두 로컬 DB와 Keychain에 저장한다.

### 성능 목표 (M1 완료 기준으로 측정)

| 항목 | 목표 |
|---|---|
| 콜드 스타트 → 첫 페이지 표시 | < 300 ms (일반 논문 PDF) |
| 100 MB 이상 PDF 첫 페이지 표시 | < 300 ms (렌더링은 PDFKit 타일 방식) |
| 유휴 메모리 (사이드바 닫힘) | < 80 MB |
| 앱 번들 크기 | < 10 MB |
| 스크롤/줌 | 120 Hz ProMotion에서 프레임 드랍 없음 |

## 2. 기술 선택: Swift vs Rust + gpui

### 비교

| 기준 | **Swift (AppKit + PDFKit, 일부 SwiftUI)** | **Rust + gpui (+ gpui-component)** |
|---|---|---|
| PDF 렌더링 | 시스템 PDFKit. Preview와 같은 엔진이라 렌더링 품질과 호환성이 동일하고, 타일 렌더링, Retina, 색 관리가 기본 제공됨 | 직접 붙여야 함. 선택지는 `pdfium-render`(Chromium PDFium, 약 5 MB 네이티브 라이브러리 번들), 순수 Rust `hayro`(젊은 프로젝트, `gpui-pdf` 0.7이 이를 사용), MuPDF(AGPL 라이선스) |
| 텍스트 선택, 찾기, 목차, 링크 | `PDFView`, `PDFDocument.findString`, `PDFOutline`, `PDFSelection`이 모두 기본 제공 | 텍스트 레이어, 선택, 하이라이트 그리기, 검색 결과 표시를 대부분 직접 구현해야 함 |
| 보기 모드 (단일/연속/2쪽/책) | `displayMode`, `displaysAsBook` 속성으로 해결 | 직접 레이아웃 구현 |
| 하이라이트 저장 | `PDFAnnotation(.highlight)` 저장 시 Preview, Acrobat과 호환 | pdfium으로 가능하지만 추가 작업이 큼 |
| macOS 통합 | 트랙패드 제스처, 한글 IME, 접근성(VoiceOver), Services, 다크 모드, 공유 메뉴, 문서 탭, 버전 관리, "열기" 기본 앱 등록이 자연스러움 | gpui는 macOS를 잘 지원하지만 시스템 통합 일부(IME 엣지 케이스, 접근성, 문서 기반 앱 구조)는 직접 처리해야 함 |
| 실행 속도와 메모리 | 시스템 프레임워크를 공유하므로 번들이 작고(수 MB) 실행이 빠름 | 실행 자체는 빠르지만 번들은 15–30 MB 이상(pdfium 포함 시 더 큼) |
| AI 사이드바 구현 | SwiftUI로 빠르게 구현. 마크다운과 수식 렌더링은 아래 4.4 참고 | gpui-component에 마크다운 컴포넌트가 있어 편함 |
| 크로스 플랫폼 | macOS 전용 | 이론상 Linux/Windows 확장 가능 |
| 개발 공수 (뷰어 부분) | 낮음 | 높음 (뷰어 기능 대부분을 새로 만들어야 함) |

### 권장: **Swift (AppKit 기반 + PDFKit, 사이드바는 SwiftUI)**

목표가 "Preview를 대체하는 가볍고 빠른 macOS 기본 PDF 리더"라면 Swift가 확실히 낫다. Preview 자체가 PDFKit 위에서 동작하므로 렌더링 품질, 속도, 호환성을 처음부터 같은 수준으로 얻고, 사용자가 원한 뷰어 기능(보기 모드, 찾기, 목차, 하이라이트)은 거의 모두 PDFKit에 이미 들어 있다. Rust + gpui는 UI 프레임워크로는 훌륭하지만, PDF 뷰어 기능 대부분을 직접 다시 만들어야 하고 그 과정에서 "가볍고 반응이 빠른" 품질을 Preview 수준으로 맞추는 데 큰 비용이 든다. 크로스 플랫폼이 필요해지기 전까지는 gpui를 쓸 이유가 약하다.

세부 구성:

- **AppKit `NSDocument` 기반 문서 앱**: 다중 창, 탭, 최근 문서, 기본 앱 등록이 무료로 따라온다.
- **뷰어**: `PDFView`를 `NSViewController`에 직접 둔다(SwiftUI 래핑으로 생기는 성능 문제와 포커스 문제를 피함).
- **분할 레이아웃**: `NSSplitViewController` (좌측 목차/썸네일 | 가운데 뷰어 | 우측 AI 사이드바). 사이드바는 `NSSplitViewItem(inspectorWithViewController:)`로 만들어 접기/펼치기 애니메이션과 너비 기억이 기본 제공된다.
- **AI 사이드바 UI**: SwiftUI (`NSHostingController`), 처음 열 때 생성한다.
- **최소 지원 버전**: macOS 14 Sonoma (Observation 프레임워크, 최신 SwiftUI API 사용).
- **프로젝트 생성**: XcodeGen(`project.yml`)으로 Xcode 프로젝트를 생성해서 diff와 리뷰를 쉽게 한다.
- **외부 의존성은 최소로**: GRDB.swift(SQLite), 수식 렌더링용 KaTeX(번들 리소스) 정도.

## 3. 뷰어 기능 (Preview에서 가져오는 것만)

### 3.1 보기
- 보기 모드: 단일 페이지, 단일 페이지 연속, 2쪽, 2쪽 연속, 책 모드(표지 단독)
- 줌: 실제 크기(⌘0), 너비 맞춤, 페이지 맞춤, 확대/축소(⌘+/⌘−), 핀치 줌
- 회전(보기만, 파일은 수정 안 함)
- 전체 화면, 프레젠테이션 수준의 슬라이드쇼는 제외
- 좌측 사이드바: **목차(outline)** / **썸네일** / **하이라이트 목록** 탭, 토글(⌥⌘1/2/3)
- 페이지 이동: ⌥⌘G "페이지로 이동", 상태 표시줄에 "12 / 340" 표시, 뒤로/앞으로(링크 이동 히스토리, ⌘[ / ⌘])
- 문서 탭 지원(macOS 기본 창 탭)

### 3.2 찾기
- ⌘F 찾기 막대: 증분 검색, 일치 개수 표시, ⌘G / ⇧⌘G로 이동
- 대소문자 무시, 전체 단어 옵션
- 결과 목록을 좌측 사이드바에 페이지별 문맥과 함께 표시(Preview와 동일)
- 검색은 백그라운드에서 `beginFindString`으로 비동기 실행해 큰 문서에서도 UI가 멈추지 않게 한다

### 3.3 하이라이트
- 텍스트 선택 후 ⌃⌘H 또는 툴바 버튼으로 하이라이트, 색상 5가지
- 하이라이트 클릭 시 색 변경/삭제 팝오버, 메모(짧은 텍스트) 한 줄 추가 가능
- 좌측 사이드바 "하이라이트" 탭에서 목록 보기, 클릭하면 이동
- **저장 방식(결정 필요, 7장 참고)**: 기본안은 표준 PDF Highlight 주석으로 파일에 저장해서 Preview, Acrobat, Zotero 등에서도 보이게 하는 것이다. 이때 파일 바이트가 바뀌므로 5장의 문서 식별 방식이 이를 견디도록 설계했다.

### 3.4 빼는 것
주석 도구(도형, 텍스트 상자, 펜), 서명, 양식 채우기, 페이지 삽입/삭제/재정렬, 이미지 편집, PDF 내보내기 필터, 인쇄 레이아웃 편집. (인쇄 ⌘P와 공유 메뉴는 시스템 기본 기능이므로 유지.)

## 4. AI 사이드바

### 4.1 레이아웃과 동작
- 우측 `NSSplitViewItem` 인스펙터. 분할선으로 너비를 조절하며 최소 280 pt, 최대 창 너비의 60%.
- ⌥⌘0 또는 툴바 버튼으로 열고 닫는다. 열림 여부와 너비는 앱 전역으로 기억한다.
- 처음 열 때까지 SwiftUI 뷰, 웹뷰, 네트워크 클라이언트를 만들지 않는다.
- 구성(위에서 아래로):
  1. 헤더: 제공자/모델 선택 메뉴, 대화 목록(이 PDF의 이전 대화들), 새 대화, 내보내기 메뉴
  2. 메시지 목록: 마크다운 렌더링, 스트리밍 표시, 각 메시지에 "복사" 버튼(마우스 오버 시 표시)
  3. 첨부 영역: 첨부 이미지 썸네일, 인용된 선택 텍스트 칩
  4. 입력창: 여러 줄, ⏎ 전송 / ⇧⏎ 줄바꿈, 한글 IME 조합 중 ⏎ 무시, 생성 중 ⎋로 중단

### 4.2 이미지(figure) 입력
그림을 설명할 때 필요한 이미지 입력은 세 가지 경로로 받는다.

1. **페이지 영역 캡처 (주 경로)**: 툴바의 "영역 캡처" 버튼(⇧⌘4와 비슷한 단축키, 예: ⌃⇧⌘4)을 누르고 페이지 위에서 사각형을 드래그하면, 해당 영역을 `PDFPage`에서 **벡터 원본으로 2× 이상 해상도로 렌더링**해 첨부한다. 화면 스크린샷보다 선명하고, 화면 녹화 권한도 필요 없다. 캡처한 페이지 번호도 함께 메시지 메타데이터에 남긴다.
2. **붙여넣기**: 시스템 스크린샷(⌃⇧⌘4로 클립보드 복사)을 입력창에 ⌘V.
3. **드래그 앤 드롭**: 이미지 파일을 사이드바에 끌어다 놓기.

전송 전 이미지는 긴 변 최대 1568 px로 줄이고 PNG/JPEG로 인코딩한다(Claude 권장 크기, 토큰 절약). 원본 이미지는 DB가 아닌 앱 지원 폴더에 해시 이름으로 저장하고 DB에는 경로만 둔다.

### 4.3 선택 텍스트와 연동 (추가 제안)
- PDF에서 텍스트를 선택하고 우클릭 → "AI에게 묻기" / "설명해줘" / "한국어로 번역" 메뉴. 선택 텍스트가 인용 칩으로 입력창에 붙는다.
- AI 답변 속 `p.12`, `(12쪽)` 같은 페이지 참조를 클릭 가능한 링크로 바꿔 해당 페이지로 이동한다. 시스템 프롬프트에서 페이지 인용을 `[p.12]` 형식으로 요청해 파싱을 쉽게 한다.

### 4.4 메시지 렌더링, 복사, 내보내기
- 렌더링: 논문 PDF는 수식이 많으므로 **메시지 목록 전체를 하나의 `WKWebView`**로 그리고, 번들된 markdown-it + KaTeX + highlight.js로 렌더링한다. 웹뷰는 사이드바를 처음 열 때 한 번만 만든다. (대안: 순수 SwiftUI 마크다운 라이브러리. 가볍지만 수식 지원이 약하다. 7장 결정 사항.)
- 복사: 메시지마다 "복사"(원본 마크다운), 우클릭 메뉴에 "일반 텍스트로 복사". 코드 블록 개별 복사 버튼.
- 내보내기: 헤더 메뉴의 "Markdown으로 내보내기…"(⇧⌘E). 형식:

  ```markdown
  ---
  title: <PDF 제목 또는 파일명>
  source: <파일 경로>
  sha256: <해시>
  exported: 2026-11-13T09:00:00+09:00
  model: <제공자/모델>
  ---

  ## User — 2026-11-13 09:01
  …(인용 텍스트는 > 블록, 첨부 이미지는 ./<이름>_assets/ 폴더로 복사 후 ![](...) 링크)

  ## Assistant — 2026-11-13 09:01
  …
  ```
- "모든 대화 내보내기"는 한 파일에 대화별 `#` 제목으로 합친다.

### 4.5 PDF 내용을 모델에 전달하는 방식
- 문서를 처음 열 때(백그라운드) PDFKit으로 페이지별 텍스트를 추출해 `[p.N]` 표시를 붙여 DB에 캐시한다. 스캔본처럼 텍스트가 없는 PDF는 Vision 프레임워크 OCR(`VNRecognizeTextRequest`, 한국어/영어)을 사용자가 요청할 때만 실행한다.
- 컨텍스트 구성(v1, 단순):
  - 문서 전체 텍스트가 제공자별 예산(설정 가능, 예: Claude 15만 토큰, ollama 모델은 모델의 컨텍스트 길이에 맞춤) 안에 들어오면 **전체를 시스템 프롬프트에** 넣는다. Claude는 프롬프트 캐싱 덕분에 같은 대화의 반복 비용이 크지 않다.
  - 넘으면: 목차 + 현재 보고 있는 페이지 ±3쪽 + 사용자가 인용한 선택 텍스트 + 질문과 관련된 페이지(SQLite FTS5 BM25 검색 상위 N쪽)를 넣는다.
- 매 메시지에 "현재 보고 있는 페이지 번호"를 메타데이터로 함께 보내 "이 페이지", "이 그림" 같은 질문을 처리한다.

## 5. AI 제공자

공통 인터페이스:

```swift
protocol ChatProvider {
    var id: String { get }
    func models() async throws -> [ModelInfo]
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error>  // 텍스트 델타, 사용량, 종료
    func cancel()
}
```

### 5.1 Claude 구독 사용: 현실적인 방법과 제약 (조사 결과)

Anthropic의 현재 정책(Claude Code [Legal and compliance](https://code.claude.com/docs/en/legal-and-compliance) 문서, 2026년 2월 강화)은 다음과 같다.

- 구독(Free/Pro/Max) OAuth 인증은 **Claude Code와 Anthropic 자체 앱의 일반적인 사용**을 위한 것이다.
- 제3자 개발자는 자기 앱에 claude.ai 로그인을 넣거나, 사용자 대신 Pro/Max 자격 증명으로 요청을 보내면 안 된다. **claude.ai 자격 증명이나 세션 토큰을 수집, 저장, 중계하는 것도 금지**이며, 로그인은 반드시 Anthropic 자체 흐름으로 끝나야 한다. Agent SDK로 만든 제품도 API 키를 쓰라고 명시되어 있다.
- 반면 **최종 사용자가 수정되지 않은 Claude Code 바이너리에 자기 구독으로 로그인해서 쓰는 것**은 명시적으로 허용된다.

따라서 이 앱에서 구독을 쓰는 유일하게 깔끔한 방법은 다음과 같다.

> **사용자가 직접 설치하고 로그인한 `claude` CLI(Claude Code)를 앱이 자식 프로세스로 실행**하고, 앱은 토큰을 절대 읽거나 저장하지 않는다.

구현 방식 (`ClaudeCodeProvider`):

- 실행: `claude -p --input-format stream-json --output-format stream-json --verbose --include-partial-messages --model <model> --system-prompt <PDF 컨텍스트 포함 프롬프트>` 형태로, 대화당 프로세스 하나를 유지한다. stdin으로 사용자 메시지(텍스트 + base64 이미지 content block)를 보내고 stdout의 JSON 이벤트를 읽어 스트리밍한다. 매 턴마다 새로 실행하면 CLI 시작 시간(약 1–2초)이 붙으므로 프로세스를 재사용한다.
- 도구 비활성화: PDF 대화에는 파일 편집이나 셸 실행이 필요 없으므로 내장 도구를 모두 끈다(`--tools ""` 또는 `--disallowedTools`; M0 스파이크에서 현재 CLI 버전의 정확한 플래그를 확인한다). 작업 디렉터리는 빈 임시 폴더로 지정한다.
- 대화 재개: CLI가 돌려주는 `session_id`를 DB에 저장하고, 앱을 다시 열면 `--resume <session_id>`로 이어간다. 세션이 없어졌으면 DB에 있는 기록으로 대화를 재구성해 새로 시작한다.
- 바이너리 찾기: GUI 앱은 셸의 PATH를 물려받지 않으므로 `~/.local/bin/claude`, `~/.claude/local/claude`, `/opt/homebrew/bin/claude`, `/usr/local/bin/claude` 순서로 찾고, 설정에서 경로를 직접 지정할 수 있게 한다. 없거나 로그인 안 된 상태면 "터미널에서 `claude`를 실행해 로그인하세요" 안내를 띄운다.
- 제약과 주의:
  - 사용량은 사용자의 Claude Code 사용 한도(5시간/주간 한도)에서 차감된다. 응답 메타데이터의 사용량을 사이드바 하단에 작게 표시한다.
  - 사용 한도 공지에 "일반적인 개인 사용"을 전제로 한다고 되어 있으므로, 이 앱은 **본인이 자기 컴퓨터에서 쓰는 개인 도구**로 두고, 배포한다면 각 사용자가 자기 CLI 로그인을 쓰는 구조를 유지한다(앱이 계정을 중계하지 않음).
  - CLI의 출력 형식이 버전마다 조금씩 바뀔 수 있으므로 파서를 관대하게 만들고, 알 수 없는 이벤트는 무시한다.
  - **App Sandbox를 켜면 자식 프로세스가 `~/.claude`에 접근할 수 없다.** 따라서 앱은 샌드박스 없이 Developer ID 서명 + 공증으로 배포한다(Mac App Store 배포 불가).
- 선택 사항 `AnthropicAPIProvider`: Console API 키(Keychain 저장)로 Messages API를 직접 호출. 구독이 아닌 종량제이지만 가장 빠르고 안정적이며, CLI가 없을 때 대체 수단이 된다. 구현이 작으므로 함께 넣는다.

### 5.2 Ollama (ollama.com 클라우드, OpenAI 호환)
- `OpenAICompatibleProvider` 하나로 구현: `POST {baseURL}/chat/completions`, `stream: true`, SSE 파싱.
- 기본 base URL `https://ollama.com/v1`, API 키는 `Authorization: Bearer <OLLAMA_API_KEY>` (키는 Keychain 저장, ollama.com/settings/keys에서 발급).
- 모델 목록: `GET {baseURL}/models`.
- 이미지: OpenAI 형식 `image_url`에 **base64 data URI만** 지원(원격 URL 불가). 비전 지원 모델(예: qwen-vl 계열)이 아니면 이미지 첨부 버튼을 비활성화하고 안내한다.
- base URL을 바꾸면 로컬 Ollama(`http://localhost:11434/v1`)나 다른 OpenAI 호환 서버도 그대로 쓸 수 있다.

### 5.3 설정 화면 (⌘,)
제공자별 활성화, 기본 모델, Claude CLI 경로, API 키, 컨텍스트 예산, 응답 언어(기본: 한국어로 답변), 사용자 지정 시스템 프롬프트 한 칸.

## 6. 저장소: 대화 기록과 문서 식별

### 6.1 문서 식별 (파일을 옮겨도 기록 유지)
파일 경로는 바뀔 수 있으므로 내용 기반으로 식별한다. 다만 하이라이트를 파일에 저장하면 바이트가 바뀌므로 **여러 단계의 지문**을 둔다.

| 순서 | 지문 | 특징 |
|---|---|---|
| 1 | **파일 SHA-256** (CryptoKit, 백그라운드 스트리밍 계산) | 가장 정확. 같은 파일을 어디로 옮기거나 복사해도 동일 |
| 2 | **PDF 트레일러 `/ID` 첫 번째 값** (`CGPDFDocument`로 읽음) | PDF 명세상 문서 최초 생성 시 정해지고, 증분 저장(하이라이트 추가)에도 유지되는 경우가 많음 |
| 3 | **텍스트 지문**: 앞쪽 몇 페이지와 페이지 수로 만든 정규화된 텍스트의 해시 | 주석 추가, 재저장, 다른 도구로 최적화해도 대부분 유지 |

열 때의 조회 순서는 1 → 2 → 3이다. 2나 3으로 찾으면 해당 문서 레코드에 새 SHA-256을 추가로 연결한다(한 문서에 여러 해시가 붙을 수 있음). 해시 계산은 첫 페이지 표시 후 백그라운드에서 하므로 열기 속도에 영향이 없다. 큰 파일(수백 MB)도 수백 ms 수준이다.

### 6.2 DB
- SQLite (GRDB.swift), 위치: `~/Library/Application Support/Folio/library.sqlite`, WAL 모드.
- 스키마 초안:

```sql
documents(id TEXT PRIMARY KEY,          -- UUID
          title TEXT, page_count INT,
          pdf_id TEXT, text_fp TEXT,
          last_path TEXT, last_opened_at INT,
          last_page INT, last_zoom REAL, display_mode INT)
document_hashes(sha256 TEXT PRIMARY KEY, document_id TEXT REFERENCES documents)
page_text(document_id TEXT, page INT, text TEXT, PRIMARY KEY(document_id, page))
page_text_fts  -- FTS5 (page_text 내용 색인; 컨텍스트 검색용)
conversations(id TEXT PRIMARY KEY, document_id TEXT, title TEXT,
              provider TEXT, model TEXT, cli_session_id TEXT,
              created_at INT, updated_at INT)
messages(id TEXT PRIMARY KEY, conversation_id TEXT, role TEXT,
         content_md TEXT, quoted_text TEXT, page_ref INT,
         created_at INT, usage_json TEXT)
attachments(id TEXT PRIMARY KEY, message_id TEXT, kind TEXT,
            file_path TEXT, page INT, rect TEXT)
messages_fts   -- FTS5 (대화 기록 전체 검색)
```

- 대화 기록은 자동으로 삭제하지 않는다. 대화를 직접 삭제할 때만 지운다(휴지통 없이 확인 대화상자).
- 대화 제목은 첫 질문의 앞부분으로 자동 생성한다(모델 호출 없이).

## 7. 추가로 넣을 기능 (최소한으로)

필요성이 높고 가벼운 것만 골랐다.

1. **마지막 위치 기억**: 문서별 마지막 페이지, 줌, 보기 모드를 DB에 저장하고 다시 열면 복원(문서 식별 덕분에 파일을 옮겨도 유지).
2. **파일 변경 자동 새로고침**: 열려 있는 PDF가 디스크에서 바뀌면(예: LaTeX 컴파일) 현재 페이지를 유지한 채 다시 불러온다.
3. **선택 텍스트 → AI 묻기/설명/번역** (4.3).
4. **AI 답변의 페이지 인용 링크** (4.3).
5. **야간 읽기 모드**: 페이지 색 반전(다크 모드에서 흰 종이가 눈부신 문제). 보기 메뉴 토글.
6. **대화 기록 전체 검색**: 설정 창이 아닌 별도 창(⇧⌘F)에서 모든 PDF의 대화를 FTS로 검색하고, 결과를 누르면 해당 PDF를 연다(경로가 바뀌었으면 마지막 경로를 보여주고 "찾기" 버튼 제공).
7. **기본 PDF 앱 등록 안내**: 첫 실행 시 "기본 PDF 앱으로 설정" 버튼(`LSSetDefaultRoleHandlerForContentType`).

일부러 넣지 않은 것: 클라우드 동기화, 다중 문서 동시 대화, 에이전트형 도구 사용, 플러그인, 자체 PDF 편집.

## 8. 결정이 필요한 사항

| # | 질문 | 기본안 (별도 의견 없으면 이대로 진행) |
|---|---|---|
| D1 | 하이라이트를 PDF 파일에 쓸지, 앱 DB에만 둘지 | **파일에 표준 주석으로 저장** (다른 앱에서도 보임). 6.1의 다단계 식별로 기록 유지 |
| D2 | 채팅 렌더링: WKWebView + KaTeX vs 순수 SwiftUI | **WKWebView + KaTeX** (논문 수식 때문). 사이드바를 열 때만 로드 |
| D3 | 최소 macOS 버전 | **macOS 14 Sonoma** |
| D4 | 앱 이름 | 가칭 **Folio** |
| D5 | Anthropic API 키 제공자도 넣을지 | **넣음** (작고, CLI가 없을 때 대체 수단) |

## 9. 프로젝트 구조

```
preview_clone/
├── project.yml                 # XcodeGen
├── App/
│   ├── AppDelegate.swift
│   ├── Document/               # NSDocument 하위 클래스, 문서 식별(해시)
│   ├── Viewer/                 # PDFView 컨트롤러, 찾기, 목차/썸네일/하이라이트 사이드바, 영역 캡처
│   ├── Sidebar/                # AI 사이드바 (SwiftUI + WKWebView 렌더러)
│   ├── Providers/              # ChatProvider, ClaudeCode, AnthropicAPI, OpenAICompatible
│   ├── Context/                # 텍스트 추출, OCR, 컨텍스트 조립, FTS
│   ├── Storage/                # GRDB 스키마, 마이그레이션, 저장소
│   ├── Export/                 # Markdown 내보내기
│   └── Settings/
├── Resources/ChatRenderer/     # markdown-it, KaTeX, highlight.js, chat.html
└── Tests/                      # 해시/식별, 스트림 파서, 내보내기, 컨텍스트 조립 단위 테스트
```

## 10. 마일스톤

| 단계 | 내용 | 완료 기준 |
|---|---|---|
| **M0 스파이크** (짧게) | XcodeGen 스켈레톤, `claude -p` stream-json 입출력과 이미지 전송 확인, 도구 비활성화 플래그 확인, ollama.com 스트리밍 확인 | 터미널 없이 앱에서 두 제공자 모두 스트리밍 응답 수신 |
| **M1 뷰어** | 문서 열기, 보기 모드, 줌, 목차/썸네일, 찾기, 페이지 이동, 마지막 위치 기억, 자동 새로고침, 야간 모드, 기본 앱 등록 | 1장 성능 목표 측정 통과, Preview 대신 하루 써도 불편 없음 |
| **M2 하이라이트** | 하이라이트 생성/수정/삭제, 목록 탭 | 저장 후 Preview에서 같은 하이라이트가 보임 |
| **M3 AI 사이드바** | 분할 레이아웃, 접기/너비 기억, 제공자 3종, 스트리밍, 중단, 영역 캡처/붙여넣기/드롭 이미지, 선택 텍스트 인용, 페이지 링크 | 그림 영역 캡처 → 설명 요청이 두 제공자에서 동작 |
| **M4 저장과 내보내기** | DB, 다단계 문서 식별, 대화 목록/재개, 메시지 복사, Markdown 내보내기, 대화 전체 검색 | 파일을 옮기거나 하이라이트를 추가해도 같은 대화 기록이 열림 |
| **M5 마무리** | 설정 화면, 단축키 정리, 오류 안내(CLI 미설치/미로그인, 한도 초과, 네트워크), Developer ID 서명과 공증, DMG | 깨끗한 Mac에 설치해 기본 PDF 앱으로 사용 가능 |

## 11. 위험 요소와 대응

| 위험 | 대응 |
|---|---|
| Claude CLI의 stream-json 형식이나 플래그 변경 | 파서를 관대하게, CLI 버전 표시, 통합 테스트용 녹화된 이벤트 샘플 유지, API 키 제공자로 대체 가능 |
| 구독 사용 정책 변경 | 앱은 자격 증명을 다루지 않고 공식 CLI만 실행하므로 정책 범위 안에 있음. 정책이 더 바뀌면 API 키 제공자로 전환 |
| 매우 큰 PDF의 텍스트 추출, 해시 계산 부하 | 모두 백그라운드 큐에서, 첫 페이지 표시 후 실행. 추출 결과는 DB 캐시 |
| PDFKit 버그 (일부 macOS 버전의 특정 PDF 렌더링 문제) | Preview도 같은 엔진이므로 동등 수준. 문제 PDF 샘플을 테스트 폴더에 수집 |
| 샌드박스 미적용 | 네트워크와 자식 프로세스 외 권한은 쓰지 않음. Hardened Runtime은 켬 |

## 참고 자료
- Claude Code 법적 고지와 인증 정책: https://code.claude.com/docs/en/legal-and-compliance
- Claude Code 인증: https://code.claude.com/docs/en/authentication
- Ollama OpenAI 호환 API: https://docs.ollama.com/openai
- gpui-component: https://github.com/longbridge/gpui-component
- gpui-pdf (hayro 기반 GPUI PDF 뷰어): https://docs.rs/gpui-pdf
