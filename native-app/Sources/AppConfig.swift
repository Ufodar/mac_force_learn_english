import Foundation

final class AppConfig {
    static let shared = AppConfig()

    private init() {}

    private let defaults = UserDefaults.standard

    var llmEnabled: Bool {
        get { defaults.object(forKey: "llm.enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "llm.enabled") }
    }

    var llmEndpoint: String {
        get { defaults.string(forKey: "llm.endpoint") ?? "" }
        set { defaults.set(newValue, forKey: "llm.endpoint") }
    }

    var llmEndpointEffective: String {
        let raw = !llmEndpoint.isEmpty ? llmEndpoint : (env("LLM_BASE_URL") ?? env("OPENAI_BASE_URL") ?? env("LLM_ENDPOINT") ?? "")
        return Self.resolveLLMEndpoint(raw)
    }

    var llmApiKey: String {
        get { defaults.string(forKey: "llm.apiKey") ?? "" }
        set { defaults.set(newValue, forKey: "llm.apiKey") }
    }

    var llmApiKeyEffective: String {
        if !llmApiKey.isEmpty { return llmApiKey }
        return env("LLM_API_KEY") ?? env("OPENAI_API_KEY") ?? ""
    }

    var llmModel: String {
        get { defaults.string(forKey: "llm.model") ?? "" }
        set { defaults.set(newValue, forKey: "llm.model") }
    }

    var llmModelEffective: String {
        if !llmModel.isEmpty { return llmModel }
        return env("LLM_MODEL") ?? ""
    }

    var intervalSeconds: TimeInterval {
        get {
            let v = defaults.double(forKey: "overlay.intervalSeconds")
            return v > 0 ? v : 20 * 60
        }
        set { defaults.set(newValue, forKey: "overlay.intervalSeconds") }
    }

    var displaySeconds: TimeInterval {
        get {
            let v = defaults.double(forKey: "overlay.displaySeconds")
            return v > 0 ? v : 12
        }
        set { defaults.set(newValue, forKey: "overlay.displaySeconds") }
    }

    var newWordsBeforeReview: Int {
        get {
            let v = defaults.integer(forKey: "review.newWordsBeforeReview")
            return v > 0 ? v : 3
        }
        set { defaults.set(newValue, forKey: "review.newWordsBeforeReview") }
    }

    var doNotDisturb: Bool {
        get { defaults.object(forKey: "overlay.dnd") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "overlay.dnd") }
    }

    var quickTranslateEnabled: Bool {
        get { defaults.object(forKey: "quickTranslate.enabled") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "quickTranslate.enabled") }
    }

    /// "en" | "zh" | "auto"
    var quickTranslateTarget: String {
        get { defaults.string(forKey: "quickTranslate.target") ?? "en" }
        set { defaults.set(newValue, forKey: "quickTranslate.target") }
    }

    var wordWeight: Int {
        get {
            let v = defaults.integer(forKey: "mix.wordWeight")
            return v > 0 ? v : 7
        }
        set { defaults.set(newValue, forKey: "mix.wordWeight") }
    }

    var sentenceWeight: Int {
        get {
            let v = defaults.integer(forKey: "mix.sentenceWeight")
            return v > 0 ? v : 3
        }
        set { defaults.set(newValue, forKey: "mix.sentenceWeight") }
    }

    var enabledCategories: [String] {
        get {
            if let arr = defaults.array(forKey: "llm.categories") as? [String], !arr.isEmpty {
                return arr
            }
            return ["cs", "gaokao3500", "cet4", "cet6"]
        }
        set { defaults.set(newValue, forKey: "llm.categories") }
    }

    private func env(_ key: String) -> String? {
        let v = ProcessInfo.processInfo.environment[key]
        let t = (v ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    static func resolveLLMEndpoint(_ input: String) -> String {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if s.isEmpty { return "" }

        // Already a full endpoint
        if s.contains("/chat/completions") || s.contains("/completions") {
            return s
        }

        // Common: user provides base URL
        // - http://host:port/v1
        // - http://host:port
        if s.hasSuffix("/v1") {
            return s + "/chat/completions"
        }

        if let url = URL(string: s) {
            let path = url.path
            if path.isEmpty || path == "/" {
                return s + "/v1/chat/completions"
            }
            if path == "/v1" {
                return s + "/chat/completions"
            }
        }

        // Fall back: keep as-is
        return s
    }
}
