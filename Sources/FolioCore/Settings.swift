import Foundation
import Security

/// Non-secret preferences (UserDefaults). Secrets live in the Keychain.
public enum AppSettings {
    private static var d: UserDefaults { .standard }

    public enum Key {
        public static let provider = "ai.provider"
        public static let claudeModel = "ai.claude.model"
        public static let claudePath = "ai.claude.path"
        public static let claudeExtraArgs = "ai.claude.extraArgs"
        public static let ollamaBaseURL = "ai.ollama.baseURL"
        public static let ollamaModel = "ai.ollama.model"
        public static let anthropicModel = "ai.anthropic.model"
        public static let responseLanguage = "ai.responseLanguage"
        public static let customPrompt = "ai.customPrompt"
        public static let claudeContextChars = "ai.claude.contextChars"
        public static let ollamaContextChars = "ai.ollama.contextChars"
    }

    public static var provider: ProviderKind {
        get { ProviderKind(rawValue: d.string(forKey: Key.provider) ?? "") ?? .claudeCode }
        set { d.set(newValue.rawValue, forKey: Key.provider) }
    }

    public static var claudeModel: String {
        get { d.string(forKey: Key.claudeModel) ?? "sonnet" }
        set { d.set(newValue, forKey: Key.claudeModel) }
    }

    public static var claudePath: String {
        get { d.string(forKey: Key.claudePath) ?? "" }
        set { d.set(newValue, forKey: Key.claudePath) }
    }

    /// Extra CLI arguments, space separated.
    public static var claudeExtraArgs: String {
        get { d.string(forKey: Key.claudeExtraArgs) ?? "" }
        set { d.set(newValue, forKey: Key.claudeExtraArgs) }
    }

    public static var ollamaBaseURL: String {
        get { d.string(forKey: Key.ollamaBaseURL) ?? "https://ollama.com/v1" }
        set { d.set(newValue, forKey: Key.ollamaBaseURL) }
    }

    public static var ollamaModel: String {
        get { d.string(forKey: Key.ollamaModel) ?? "gpt-oss:120b" }
        set { d.set(newValue, forKey: Key.ollamaModel) }
    }

    public static var anthropicModel: String {
        get { d.string(forKey: Key.anthropicModel) ?? "claude-sonnet-5-5" }
        set { d.set(newValue, forKey: Key.anthropicModel) }
    }

    public static var responseLanguage: String {
        get { d.string(forKey: Key.responseLanguage) ?? "한국어" }
        set { d.set(newValue, forKey: Key.responseLanguage) }
    }

    public static var customPrompt: String {
        get { d.string(forKey: Key.customPrompt) ?? "" }
        set { d.set(newValue, forKey: Key.customPrompt) }
    }

    /// Character budget for document text in the prompt (~3–4 chars per token for English).
    public static var claudeContextChars: Int {
        get { let v = d.integer(forKey: Key.claudeContextChars); return v > 0 ? v : 450_000 }
        set { d.set(newValue, forKey: Key.claudeContextChars) }
    }

    public static var ollamaContextChars: Int {
        get { let v = d.integer(forKey: Key.ollamaContextChars); return v > 0 ? v : 200_000 }
        set { d.set(newValue, forKey: Key.ollamaContextChars) }
    }

    public static func model(for kind: ProviderKind) -> String {
        switch kind {
        case .claudeCode: return claudeModel
        case .ollama: return ollamaModel
        case .anthropicAPI: return anthropicModel
        }
    }

    public static func setModel(_ model: String, for kind: ProviderKind) {
        switch kind {
        case .claudeCode: claudeModel = model
        case .ollama: ollamaModel = model
        case .anthropicAPI: anthropicModel = model
        }
    }

    public static func contextChars(for kind: ProviderKind) -> Int {
        kind == .ollama ? ollamaContextChars : claudeContextChars
    }
}

/// Minimal generic-password Keychain access.
public enum Keychain {
    public static let service = "app.folio.reader"

    public static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func set(_ value: String?, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    public static let ollamaKey = "ollama-api-key"
    public static let anthropicKey = "anthropic-api-key"
}

public enum ProviderFactory {
    public static func make(_ kind: ProviderKind) -> ChatProvider {
        switch kind {
        case .claudeCode:
            let workdir = Store.defaultDirectory().appendingPathComponent("claude-workdir", isDirectory: true)
            let extra = AppSettings.claudeExtraArgs.split(separator: " ").map(String.init)
            return ClaudeCodeProvider(executablePath: AppSettings.claudePath, extraArguments: extra, workingDirectory: workdir)
        case .ollama:
            let url = URL(string: AppSettings.ollamaBaseURL) ?? URL(string: "https://ollama.com/v1")!
            return OpenAICompatibleProvider(baseURL: url, apiKey: Keychain.get(Keychain.ollamaKey))
        case .anthropicAPI:
            return AnthropicAPIProvider(apiKey: Keychain.get(Keychain.anthropicKey) ?? "")
        }
    }
}
