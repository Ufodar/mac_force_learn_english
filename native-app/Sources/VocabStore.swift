import Foundation

final class VocabStore {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private(set) var data: VocabStoreData

    init(appSupportFolderName: String = "MacForceLearnEnglish") {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = supportDir.appendingPathComponent(appSupportFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        self.fileURL = folder.appendingPathComponent("store.json")
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601

        if let loaded = try? Data(contentsOf: fileURL),
           let parsed = try? decoder.decode(VocabStoreData.self, from: loaded) {
            self.data = parsed
        } else {
            self.data = VocabStoreData(version: 1, items: [], newWordsSinceLastReview: 0)
            save()
        }
    }

    func save() {
        do {
            let bytes = try encoder.encode(data)
            try bytes.write(to: fileURL, options: [.atomic])
        } catch {
            NSLog("[store] save failed: \(error)")
        }
    }

    func statsSummary() -> String {
        let words = data.items.filter { $0.type == .word }
        let sentences = data.items.filter { $0.type == .sentence }
        let learnedWords = words.filter { $0.timesShown > 0 }.count
        let totalExamples = words.reduce(0) { $0 + $1.examples.count }
        return """
        Words: \(words.count) (learned: \(learnedWords))
        Sentences: \(sentences.count)
        Examples: \(totalExamples)
        """
    }

    func containsDuplicate(for item: VocabItem) -> Bool {
        let key = dedupeKey(type: item.type, front: item.front)
        return data.items.contains { existing in
            dedupeKey(type: existing.type, front: existing.front) == key
        }
    }

    func addItemIfNew(_ item: VocabItem) -> Bool {
        if containsDuplicate(for: item) { return false }
        data.items.append(item)
        save()
        return true
    }

    func findItem(type: VocabItemType, front: String) -> VocabItem? {
        let key = Self.dedupeKey(type: type, front: front)
        return data.items.first { existing in
            Self.dedupeKey(type: existing.type, front: existing.front) == key
        }
    }

    @discardableResult
    func upsertItem(type: VocabItemType, front: String, back: String, phonetic: String? = nil, category: String? = nil) -> VocabItem {
        let key = Self.dedupeKey(type: type, front: front)
        if let idx = data.items.firstIndex(where: { Self.dedupeKey(type: $0.type, front: $0.front) == key }) {
            var item = data.items[idx]
            item.back = back
            if let p = phonetic, !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                item.phonetic = p
            }
            if item.category == nil { item.category = category }
            data.items[idx] = item
            save()
            return item
        }

        let item = VocabItem(
            id: UUID(),
            type: type,
            front: front,
            back: back,
            phonetic: phonetic,
            category: category,
            examples: [],
            createdAt: Date(),
            lastShownAt: nil,
            timesShown: 0
        )
        data.items.append(item)
        save()
        return item
    }

    func updateItem(_ updated: VocabItem) {
        if let idx = data.items.firstIndex(where: { $0.id == updated.id }) {
            data.items[idx] = updated
            save()
        }
    }

    func recordShown(_ item: VocabItem, countedAsNewWord: Bool) -> VocabItem {
        var updated = item
        updated.timesShown += 1
        updated.lastShownAt = Date()
        updateItem(updated)

        if countedAsNewWord {
            data.newWordsSinceLastReview += 1
            save()
        }
        return updated
    }

    func resetNewWordCounter() {
        data.newWordsSinceLastReview = 0
        save()
    }

    func pickOldWordForReview() -> VocabItem? {
        let oldWords = data.items.filter { $0.type == .word && $0.timesShown > 0 }
        if oldWords.isEmpty { return nil }
        let sorted = oldWords.sorted { a, b in
            let da = a.lastShownAt ?? .distantPast
            let db = b.lastShownAt ?? .distantPast
            return da < db
        }
        let slice = Array(sorted.prefix(20))
        return slice.randomElement() ?? sorted.first
    }

    static func dedupeKey(type: VocabItemType, front: String) -> String {
        let normalized = front.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(type.rawValue)::\(normalized)"
    }

    private func dedupeKey(type: VocabItemType, front: String) -> String {
        Self.dedupeKey(type: type, front: front)
    }
}
