import Foundation

enum VocabItemType: String, Codable {
    case word
    case sentence
}

struct VocabExample: Codable, Hashable {
    var en: String
    var zh: String
    var createdAt: Date
}

struct WordSense: Codable, Hashable {
    /// e.g. "n.", "v.", "adj."
    var pos: String
    /// Meaning in target language (usually Chinese)
    var meaning: String
    /// Larger means more common (1-5)
    var freq: Int
}

struct VocabItem: Codable, Hashable, Identifiable {
    var id: UUID
    var type: VocabItemType
    var front: String
    var back: String
    var phonetic: String?
    var category: String?
    /// "lookup" etc. Optional for backward compatibility.
    var source: String? = nil
    /// Multi-sense dictionary data (optional).
    var senses: [WordSense]? = nil
    var examples: [VocabExample]
    var createdAt: Date
    var lastShownAt: Date?
    var timesShown: Int
}

struct VocabStoreData: Codable {
    var version: Int
    var items: [VocabItem]
    var newWordsSinceLastReview: Int
}

enum OverlayMode {
    case auto
    case review
    case manual
}
