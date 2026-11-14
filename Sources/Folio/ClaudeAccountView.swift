import AppKit
import SwiftUI
import FolioCore

/// Login status + sign-in/out controls for the Claude subscription (used in Settings).
struct ClaudeAccountPanel: View {
    @ObservedObject var account = ClaudeAccount.shared
    @State private var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                statusIcon
                VStack(alignment: .leading, spacing: 1) {
                    Text(statusTitle).font(.system(size: 13, weight: .medium))
                    if let detail = statusDetail {
                        Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                Spacer()
                actionButtons
            }
            ClaudeLoginProgress(account: account, code: $code)
        }
        .onAppear { account.refresh() }
    }

    @ViewBuilder private var statusIcon: some View {
        switch account.state {
        case .loggedIn: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .checking, .unknown: ProgressView().controlSize(.small)
        case .loggedOut: Image(systemName: "person.crop.circle.badge.xmark").foregroundStyle(.orange)
        case .notInstalled, .error: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    private var statusTitle: String {
        switch account.state {
        case .loggedIn: return "Claude에 로그인됨"
        case .checking, .unknown: return "로그인 상태 확인 중…"
        case .loggedOut: return "로그인되어 있지 않음"
        case .notInstalled: return "claude CLI를 찾지 못했습니다"
        case .error: return "상태를 확인하지 못했습니다"
        }
    }

    private var statusDetail: String? {
        switch account.state {
        case .loggedIn(let s): return s.summary
        case .loggedOut: return "‘Claude에 로그인’을 누르면 브라우저에서 Claude 계정으로 로그인합니다."
        case .notInstalled: return "https://claude.com/claude-code 에서 Claude Code를 설치하거나, 아래에 경로를 지정하세요."
        case .error(let m): return m
        default: return nil
        }
    }

    @ViewBuilder private var actionButtons: some View {
        if account.isLoggingIn {
            Button("취소") { account.cancelLogin() }
        } else {
            switch account.state {
            case .loggedIn:
                Button("다시 확인") { account.refresh() }
                Button("로그아웃") { account.logout() }
            case .loggedOut, .error:
                Button("다시 확인") { account.refresh() }
                Button("Claude에 로그인") { account.startLogin() }.keyboardShortcut(.defaultAction)
            case .notInstalled:
                Button("다시 찾기") { account.refresh() }
            case .checking, .unknown:
                EmptyView()
            }
        }
    }
}

/// While `claude auth login` runs: what is happening, the fallback link and the code field.
/// After it ends: a success or failure line.
struct ClaudeLoginProgress: View {
    @ObservedObject var account: ClaudeAccount
    @Binding var code: String

    var body: some View {
        switch account.login {
        case .idle:
            EmptyView()
        case .running:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("브라우저에서 Claude 로그인을 마치면 자동으로 완료됩니다.")
                        .font(.caption)
                }
                if account.signInURL != nil {
                    Button("브라우저가 열리지 않았다면: 로그인 페이지 열기") { account.openSignInPage() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                if account.asksForCode {
                    Text("로그인 페이지에 코드가 표시되면 복사해서 여기에 붙여 넣으세요.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField("인증 코드", text: $code)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(submit)
                        Button("확인", action: submit).disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        case .succeeded(let summary):
            resultLine("checkmark.circle.fill", .green, "로그인 성공 · \(summary)")
        case .failed(let message):
            resultLine("xmark.octagon.fill", .red, message)
        }
    }

    private func submit() {
        account.submitCode(code)
        code = ""
    }

    private func resultLine(_ symbol: String, _ color: Color, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).font(.caption).textSelection(.enabled)
            Spacer(minLength: 0)
            Button { account.dismissLoginResult() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .font(.caption)
        }
    }
}

/// Shown at the top of the AI sidebar when the Claude subscription is selected but not usable.
struct ClaudeLoginBanner: View {
    @ObservedObject var account = ClaudeAccount.shared
    @State private var code = ""

    var body: some View {
        if shouldShow {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: icon).foregroundStyle(iconColor)
                    Text(message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                if !account.isLoggingIn, case .loggedOut = account.state {
                    Button("Claude에 로그인") { account.startLogin() }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                } else if !account.isLoggingIn, case .notInstalled = account.state {
                    Button("설치 안내 열기") {
                        if let url = URL(string: "https://claude.com/claude-code") { NSWorkspace.shared.open(url) }
                    }
                    .controlSize(.small)
                }
                ClaudeLoginProgress(account: account, code: $code)
                if account.isLoggingIn {
                    Button("취소") { account.cancelLogin() }.controlSize(.small)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.secondary.opacity(0.08)))
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
    }

    private var shouldShow: Bool {
        if account.isLoggingIn { return true }
        switch account.login {
        case .succeeded, .failed: return true
        default: break
        }
        switch account.state {
        case .loggedOut, .notInstalled: return true
        default: return false
        }
    }

    private var icon: String {
        if case .succeeded = account.login { return "checkmark.circle.fill" }
        if case .notInstalled = account.state { return "exclamationmark.triangle.fill" }
        return "person.crop.circle.badge.exclamationmark"
    }

    private var iconColor: Color {
        if case .succeeded = account.login { return .green }
        if case .notInstalled = account.state { return .red }
        return .orange
    }

    private var message: String {
        if case .succeeded = account.login { return "Claude 구독으로 대화할 준비가 되었습니다." }
        if account.isLoggingIn { return "Claude에 로그인하는 중…" }
        if case .notInstalled = account.state { return "Claude 구독을 쓰려면 Claude Code(claude CLI)가 필요합니다." }
        return "Claude 구독으로 대화하려면 로그인하세요."
    }
}
