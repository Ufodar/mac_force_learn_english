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

struct VocabItem: Codable, Hashable, Identifiable {
    var id: UUID
    var type: VocabItemType
    var front: String
    var back: String
    var phonetic: String?
    var category: String?
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

