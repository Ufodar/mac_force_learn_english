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

    var llmApiKey: String {
        get { defaults.string(forKey: "llm.apiKey") ?? "" }
        set { defaults.set(newValue, forKey: "llm.apiKey") }
    }

    var llmModel: String {
        get { defaults.string(forKey: "llm.model") ?? "" }
        set { defaults.set(newValue, forKey: "llm.model") }
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
}

