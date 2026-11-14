import AppKit
import Darwin
import FolioCore

/// Shows and changes the sign-in state of the user's `claude` CLI.
///
/// Signing in runs the CLI's own `claude auth login` in a pseudo-terminal: the CLI opens the
/// browser, receives the OAuth result and stores the credentials itself. Folio only shows the
/// CLI's messages and, when the CLI asks for it, types the code the user pastes into the CLI's
/// prompt. It never reads or stores the credentials.
@MainActor
final class ClaudeAccount: ObservableObject {
    static let shared = ClaudeAccount()

    enum State: Equatable {
        case unknown
        case checking
        case notInstalled
        case loggedOut
        case loggedIn(ClaudeAuthStatus)
        case error(String)
    }

    enum LoginPhase: Equatable {
        case idle
        case running
        case succeeded(String)
        case failed(String)
    }

    @Published private(set) var state: State = .unknown
    @Published private(set) var login: LoginPhase = .idle
    /// Link the CLI printed, for when the browser didn't open by itself.
    @Published private(set) var signInURL: URL?
    /// The CLI is showing "Paste code here if prompted".
    @Published private(set) var asksForCode = false
    @Published private(set) var lastChecked: Date?

    private var loginProcess: Process?
    private var masterFD: Int32 = -1
    private var output = ""
    private var userCancelled = false
    private var checkInFlight = false

    private init() {}

    var isLoggedIn: Bool { if case .loggedIn = state { return true } else { return false } }
    var isLoggingIn: Bool { login == .running }

    var executable: String? { ClaudeCodeProvider.locate(preferred: AppSettings.claudePath) }

    // MARK: Status

    /// Re-reads `claude auth status`. Cheap; called when the settings or sidebar appear.
    func refresh() {
        guard !checkInFlight, !isLoggingIn else { return }
        guard let exe = executable else { state = .notInstalled; return }
        if case .loggedIn = state {} else { state = .checking }
        checkInFlight = true
        Task.detached {
            let (code, out) = Self.run(exe, ["auth", "status", "--json"])
            let parsed = ClaudeAuthStatus.parse(out)
            await MainActor.run {
                self.checkInFlight = false
                self.lastChecked = Date()
                if let parsed {
                    self.state = parsed.loggedIn ? .loggedIn(parsed) : .loggedOut
                } else if code != 0, out.lowercased().contains("not logged in") || out.lowercased().contains("login") {
                    self.state = .loggedOut
                } else {
                    self.state = .error(out.isEmpty ? "상태를 확인하지 못했습니다 (코드 \(code))." : String(out.prefix(400)))
                }
            }
        }
    }

    /// Refreshes only if the last check is older than `maxAge` seconds.
    func refreshIfStale(_ maxAge: TimeInterval = 60) {
        if let lastChecked, Date().timeIntervalSince(lastChecked) < maxAge, state != .unknown { return }
        refresh()
    }

    // MARK: Login

    func startLogin() {
        guard loginProcess == nil else { return }
        guard let exe = executable else {
            state = .notInstalled
            login = .failed("claude CLI를 찾을 수 없습니다. https://claude.com/claude-code 에서 설치하세요.")
            return
        }
        var master: Int32 = -1, slave: Int32 = -1
        var size = winsize(ws_row: 24, ws_col: 400, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else {
            login = .failed("터미널을 만들지 못했습니다 (errno \(errno)).")
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = ["auth", "login", "--claudeai"]
        var env = ClaudeCodeProvider.processEnvironment(executable: exe)
        env["TERM"] = "xterm-256color"
        proc.environment = env
        proc.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        proc.standardInput = slaveHandle
        proc.standardOutput = slaveHandle
        proc.standardError = slaveHandle

        output = ""
        userCancelled = false
        signInURL = nil
        asksForCode = false
        login = .running
        do {
            try proc.run()
        } catch {
            close(slave); close(master)
            login = .failed("로그인을 시작하지 못했습니다: \(error.localizedDescription)")
            return
        }
        // The child holds its own copy; closing ours lets reads end with EIO when it exits.
        close(slave)
        loginProcess = proc
        masterFD = master

        Thread.detachNewThread { [weak self] in
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(master, &buf, buf.count)
                if n <= 0 { break }
                let chunk = String(decoding: buf[0..<n], as: UTF8.self)
                DispatchQueue.main.async { self?.consume(chunk) }
            }
            proc.waitUntilExit()
            let status = proc.terminationStatus
            DispatchQueue.main.async { self?.loginEnded(status: status) }
        }
    }

    /// Types the code from the sign-in page into the CLI's prompt.
    func submitCode(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard masterFD >= 0, !trimmed.isEmpty else { return }
        let bytes = Array((trimmed + "\r").utf8)
        _ = bytes.withUnsafeBufferPointer { write(masterFD, $0.baseAddress, $0.count) }
        asksForCode = false
    }

    func cancelLogin() {
        guard let proc = loginProcess, proc.isRunning else { return }
        userCancelled = true
        proc.interrupt()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if proc.isRunning { proc.terminate() } }
    }

    func openSignInPage() {
        if let signInURL { NSWorkspace.shared.open(signInURL) }
    }

    func dismissLoginResult() {
        if !isLoggingIn { login = .idle }
    }

    private func consume(_ chunk: String) {
        output += chunk
        if output.count > 20_000 { output = String(output.suffix(10_000)) }
        let cleaned = ClaudeLoginOutput.clean(output)
        if signInURL == nil { signInURL = ClaudeLoginOutput.signInURL(in: cleaned) }
        let tail = String(cleaned.suffix(300))
        asksForCode = ClaudeLoginOutput.asksForCode(tail) && !ClaudeLoginOutput.reportsSuccess(tail)
    }

    private func loginEnded(status: Int32) {
        if masterFD >= 0 { close(masterFD); masterFD = -1 }
        loginProcess = nil
        asksForCode = false
        let cleaned = ClaudeLoginOutput.clean(output)
        let cancelled = userCancelled

        guard let exe = executable else { login = .failed("claude CLI를 찾을 수 없습니다."); return }
        state = .checking
        Task.detached {
            let (_, out) = Self.run(exe, ["auth", "status", "--json"])
            let parsed = ClaudeAuthStatus.parse(out)
            await MainActor.run {
                self.lastChecked = Date()
                if let parsed, parsed.loggedIn {
                    self.state = .loggedIn(parsed)
                    self.login = .succeeded(parsed.summary)
                    self.announceSuccess(parsed)
                } else {
                    self.state = parsed == nil ? .error(String(out.prefix(400))) : .loggedOut
                    if cancelled {
                        self.login = .idle
                    } else {
                        let detail = cleaned.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty && !$0.hasPrefix("http") }.suffix(3).joined(separator: "\n")
                        self.login = .failed("로그인하지 못했습니다 (코드 \(status)).\(detail.isEmpty ? "" : "\n" + detail)")
                    }
                }
            }
        }
    }

    /// The user is usually in the browser when sign-in finishes: bring Folio back and say so.
    private func announceSuccess(_ status: ClaudeAuthStatus) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Claude에 로그인했습니다"
        alert.informativeText = "\(status.summary)\n이제 AI 사이드바에서 Claude 구독으로 대화할 수 있습니다."
        alert.addButton(withTitle: "확인")
        alert.runModal()
    }

    // MARK: Logout

    func logout() {
        guard let exe = executable else { return }
        state = .checking
        login = .idle
        Task.detached {
            _ = Self.run(exe, ["auth", "logout"])
            await MainActor.run { self.state = .unknown; self.refresh() }
        }
    }

    // MARK: Process

    nonisolated static func run(_ exe: String, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = ClaudeCodeProvider.processEnvironment(executable: exe)
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do {
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return (-1, error.localizedDescription)
        }
    }
}
