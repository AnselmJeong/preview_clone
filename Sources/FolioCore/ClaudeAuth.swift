import Foundation

/// Sign-in state of the user's `claude` CLI, as reported by `claude auth status --json`.
/// Folio only reads this summary; the credentials themselves stay inside the CLI.
public struct ClaudeAuthStatus: Equatable, Sendable {
    public var loggedIn: Bool
    public var authMethod: String?
    public var email: String?
    public var organization: String?
    public var subscription: String?

    public init(loggedIn: Bool, authMethod: String? = nil, email: String? = nil,
                organization: String? = nil, subscription: String? = nil) {
        self.loggedIn = loggedIn
        self.authMethod = authMethod
        self.email = email
        self.organization = organization
        self.subscription = subscription
    }

    /// Parses `claude auth status --json`. Returns nil when the output is not that JSON.
    public static func parse(_ output: String) -> ClaudeAuthStatus? {
        // Tolerate log lines before the JSON object.
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end,
              let obj = jsonObject(String(output[start...end])),
              let loggedIn = obj["loggedIn"] as? Bool else { return nil }
        func str(_ keys: String...) -> String? {
            for k in keys { if let v = obj[k] as? String, !v.isEmpty { return v } }
            return nil
        }
        return ClaudeAuthStatus(
            loggedIn: loggedIn,
            authMethod: str("authMethod"),
            email: str("email", "emailAddress", "accountEmail"),
            organization: str("orgName", "organizationName", "organization"),
            subscription: str("subscriptionType", "subscription", "plan"))
    }

    /// One line for the UI, e.g. "you@example.com · Max".
    public var summary: String {
        guard loggedIn else { return "로그인되어 있지 않음" }
        var parts: [String] = []
        if let email { parts.append(email) }
        if let subscription { parts.append(subscription.capitalized) }
        if parts.isEmpty, let authMethod { parts.append(Self.methodName(authMethod)) }
        return parts.isEmpty ? "로그인됨" : parts.joined(separator: " · ")
    }

    static func methodName(_ m: String) -> String {
        switch m {
        case "claude.ai", "claudeai", "oauth", "oauth_token": return "Claude 구독"
        case "api_key", "apiKey": return "API 키"
        default: return m
        }
    }
}

/// Helpers for driving `claude auth login` through a pseudo-terminal.
public enum ClaudeLoginOutput {
    /// Removes ANSI/OSC escape sequences and carriage returns from terminal output.
    public static func clean(_ raw: String) -> String {
        var s = raw
        // OSC (e.g. hyperlinks): ESC ] … BEL  or  ESC ] … ESC \
        s = s.replacingOccurrences(of: "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)", with: "", options: .regularExpression)
        // CSI: ESC [ params letter
        s = s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        // Remaining two-byte escapes.
        s = s.replacingOccurrences(of: "\u{1B}[@-Z\\\\-_]", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return s
    }

    /// The sign-in link the CLI prints ("If the browser didn't open, visit: …").
    public static func signInURL(in cleaned: String) -> URL? {
        guard let range = cleaned.range(of: "https://[^\\s\"'<>]+", options: .regularExpression) else { return nil }
        return URL(string: String(cleaned[range]))
    }

    /// Whether the CLI is waiting for the code shown after signing in on the web page.
    public static func asksForCode(_ cleaned: String) -> Bool {
        cleaned.localizedCaseInsensitiveContains("paste code")
    }

    public static func reportsSuccess(_ cleaned: String) -> Bool {
        let l = cleaned.lowercased()
        return l.contains("login successful") || l.contains("logged in as") || l.contains("successfully logged in")
    }
}

extension ClaudeCodeProvider {
    /// Environment for launching the CLI from a GUI app (which doesn't inherit the shell PATH).
    public static func processEnvironment(executable exe: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let exeDir = (exe as NSString).deletingLastPathComponent
        env["PATH"] = [exeDir, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", env["PATH"] ?? ""].joined(separator: ":")
        return env
    }
}
