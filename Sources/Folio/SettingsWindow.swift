import AppKit
import SwiftUI
import FolioCore

@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = "Folio 설정"
        window.contentViewController = NSHostingController(rootView: SettingsView())
        window.center()
        window.setFrameAutosaveName("FolioSettings")
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }
}

struct SettingsView: View {
    @State private var claudePath = AppSettings.claudePath
    @State private var claudeModel = AppSettings.claudeModel
    @State private var claudeExtraArgs = AppSettings.claudeExtraArgs
    @State private var detectedClaude: String?
    @State private var claudeCheck: String?

    @State private var ollamaURL = AppSettings.ollamaBaseURL
    @State private var ollamaKey = Keychain.get(Keychain.ollamaKey) ?? ""
    @State private var ollamaModel = AppSettings.ollamaModel
    @State private var ollamaCheck: String?

    @State private var anthropicKey = Keychain.get(Keychain.anthropicKey) ?? ""
    @State private var anthropicModel = AppSettings.anthropicModel

    @State private var language = AppSettings.responseLanguage
    @State private var customPrompt = AppSettings.customPrompt
    @State private var claudeBudget = Double(AppSettings.claudeContextChars)
    @State private var ollamaBudget = Double(AppSettings.ollamaContextChars)

    var body: some View {
        TabView {
            providersTab.tabItem { Label("AI 제공자", systemImage: "sparkles") }
            generalTab.tabItem { Label("일반", systemImage: "gearshape") }
            ShortcutsTab().tabItem { Label("단축키", systemImage: "keyboard") }
        }
        .padding(16)
        .frame(width: 560, height: 560)
        .onAppear { detectedClaude = ClaudeCodeProvider.locate(preferred: claudePath) }
    }

    private var providersTab: some View {
        Form {
            Section("Claude 구독 (Claude Code CLI)") {
                Text("터미널에서 `claude`를 설치하고 한 번 실행해 로그인하면, Folio가 그 CLI를 통해 대화합니다. Folio는 로그인 정보를 읽거나 저장하지 않습니다.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("CLI 경로 (비우면 자동 탐색)", text: $claudePath)
                    .onChange(of: claudePath) { _, v in AppSettings.claudePath = v }
                HStack {
                    Text(detectedClaude.map { "찾음: \($0)" } ?? "claude를 찾지 못했습니다")
                        .font(.caption).foregroundStyle(detectedClaude == nil ? .red : .secondary)
                    Spacer()
                    Button("상태 확인") { checkClaude() }
                }
                if let claudeCheck { Text(claudeCheck).font(.caption).textSelection(.enabled) }
                TextField("모델 (sonnet, opus, haiku 또는 전체 이름)", text: $claudeModel)
                    .onChange(of: claudeModel) { _, v in AppSettings.claudeModel = v }
                TextField("추가 CLI 인수 (선택)", text: $claudeExtraArgs)
                    .onChange(of: claudeExtraArgs) { _, v in AppSettings.claudeExtraArgs = v }
            }
            Section("Ollama (OpenAI 호환 API)") {
                TextField("Base URL", text: $ollamaURL)
                    .onChange(of: ollamaURL) { _, v in AppSettings.ollamaBaseURL = v }
                SecureField("API 키 (ollama.com/settings/keys)", text: $ollamaKey)
                    .onChange(of: ollamaKey) { _, v in Keychain.set(v, for: Keychain.ollamaKey) }
                HStack {
                    TextField("모델", text: $ollamaModel)
                        .onChange(of: ollamaModel) { _, v in AppSettings.ollamaModel = v }
                    Button("연결 확인") { checkOllama() }
                }
                if let ollamaCheck { Text(ollamaCheck).font(.caption).textSelection(.enabled) }
            }
            Section("Claude API 키 (선택, 종량제)") {
                SecureField("Anthropic API 키", text: $anthropicKey)
                    .onChange(of: anthropicKey) { _, v in Keychain.set(v, for: Keychain.anthropicKey) }
                TextField("모델", text: $anthropicModel)
                    .onChange(of: anthropicModel) { _, v in AppSettings.anthropicModel = v }
            }
        }
        .formStyle(.grouped)
    }

    private var generalTab: some View {
        Form {
            Section("답변") {
                TextField("답변 언어", text: $language)
                    .onChange(of: language) { _, v in AppSettings.responseLanguage = v }
                VStack(alignment: .leading) {
                    Text("추가 지시문 (모든 대화에 적용)").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $customPrompt)
                        .font(.body)
                        .frame(height: 80)
                        .onChange(of: customPrompt) { _, v in AppSettings.customPrompt = v }
                }
            }
            Section("문서 컨텍스트") {
                Text("문서 텍스트가 이 길이 이하이면 전체를, 넘으면 현재 페이지 주변과 질문 관련 페이지만 보냅니다.")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper(value: $claudeBudget, in: 50_000...2_000_000, step: 50_000) {
                    Text("Claude: \(Int(claudeBudget).formatted())자")
                }
                .onChange(of: claudeBudget) { _, v in AppSettings.claudeContextChars = Int(v) }
                Stepper(value: $ollamaBudget, in: 20_000...1_000_000, step: 20_000) {
                    Text("Ollama: \(Int(ollamaBudget).formatted())자")
                }
                .onChange(of: ollamaBudget) { _, v in AppSettings.ollamaContextChars = Int(v) }
            }
            Section("기본 앱") {
                Button("Folio를 기본 PDF 앱으로 설정") { AppDelegate.setAsDefaultPDFApp() }
                Button("데이터 폴더 열기") { NSWorkspace.shared.open(Store.defaultDirectory()) }
            }
        }
        .formStyle(.grouped)
    }

    private func checkClaude() {
        detectedClaude = ClaudeCodeProvider.locate(preferred: claudePath)
        guard let exe = detectedClaude else {
            claudeCheck = "claude를 찾을 수 없습니다. https://claude.com/claude-code 에서 설치하세요."
            return
        }
        claudeCheck = "확인 중…"
        Task.detached {
            let result = Self.run(exe, ["auth", "status", "--text"])
            await MainActor.run { claudeCheck = result }
        }
    }

    nonisolated private static func run(_ exe: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do {
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "종료 코드 \(p.terminationStatus)" : String(text.prefix(800))
        } catch {
            return error.localizedDescription
        }
    }

    private func checkOllama() {
        ollamaCheck = "확인 중…"
        let provider = ProviderFactory.make(.ollama)
        Task {
            do {
                let models = try await provider.listModels()
                ollamaCheck = "연결됨 · 모델 \(models.count)개" + (models.isEmpty ? "" : ": " + models.prefix(8).joined(separator: ", "))
            } catch {
                ollamaCheck = "실패: \(error.localizedDescription)"
            }
        }
    }
}
