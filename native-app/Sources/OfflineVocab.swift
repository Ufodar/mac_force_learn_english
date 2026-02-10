import Foundation

actor OfflineVocabProvider {
    struct Entry: Codable {
        struct Translation: Codable {
            var translation: String
            var type: String?
        }

        struct Sentence: Codable {
            var sentence: String
            var translation: String
        }

        var word: String
        var us: String?
        var uk: String?
        var translations: [Translation]?
        var sentences: [Sentence]?
    }

    struct LookupResult {
        var word: String
        var phonetic: String?
        var meaning: String
        var senses: [WordSense]
        var example: VocabExample?
    }

    private let config: AppConfig
    private let decoder = JSONDecoder()
    private var indexed = false
    private var filesByCategory: [String: [URL]] = [:]
    private var categoryByFile: [URL: String] = [:]
    private var entriesCache: [URL: [Entry]] = [:]
    private var lookupIndex: [String: (category: String, file: URL, idx: Int)] = [:]
    private var sentenceLookupIndex: [String: (category: String, file: URL, entryIdx: Int, sentenceIdx: Int)] = [:]
    private var scannedFiles: Set<URL> = []
    private var fullyScannedFiles = false

    init(config: AppConfig = .shared) {
        self.config = config
    }

    func isAvailable() async -> Bool {
        await ensureIndex()
        return !filesByCategory.isEmpty
    }

    func pickItem(
        enabledCategories: [String],
        existingDedupeKeys: Set<String>,
        wordWeight: Int,
        sentenceWeight: Int
    ) async -> VocabItem? {
        await ensureIndex()

        var cats = enabledCategories.filter { filesByCategory[$0] != nil }
        if cats.isEmpty {
            cats = Array(filesByCategory.keys).sorted()
        }
        if cats.isEmpty { return nil }

        let total = max(1, wordWeight + sentenceWeight)
        let roll = Int.random(in: 1...total)
        let wantWord = roll <= max(1, wordWeight)

        let maxAttempts = 80
        for _ in 0..<maxAttempts {
            guard let cat = cats.randomElement(),
                  let file = filesByCategory[cat]?.randomElement() else { continue }

            guard let entries = try? await loadEntries(for: file), !entries.isEmpty else { continue }
            let entry = entries[Int.random(in: 0..<entries.count)]

            if wantWord {
                let item = makeWordItem(from: entry, category: cat)
                if item.front.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                if item.back.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                let key = VocabStore.dedupeKey(type: item.type, front: item.front)
                if existingDedupeKeys.contains(key) { continue }
                return item
            } else {
                guard let sentences = entry.sentences, !sentences.isEmpty else { continue }
                let s = sentences[Int.random(in: 0..<sentences.count)]
                let item = makeSentenceItem(from: s, category: cat)
                if item.front.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                if item.back.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                let key = VocabStore.dedupeKey(type: item.type, front: item.front)
                if existingDedupeKeys.contains(key) { continue }
                return item
            }
        }

        return nil
    }

    func lookupWord(_ word: String) async -> LookupResult? {
        await ensureIndex()
        let key = normalizeWord(word)
        if lookupIndex[key] == nil {
            await ensureLookupCandidateLoaded(wordKey: key, sentenceKey: nil)
        }
        guard let loc = lookupIndex[key] else { return nil }
        guard let entries = try? await loadEntries(for: loc.file),
              loc.idx >= 0, loc.idx < entries.count else { return nil }
        let entry = entries[loc.idx]
        let item = makeWordItem(from: entry, category: loc.category)
        let senses = item.senses ?? []
        let ex = item.examples.last
        return LookupResult(word: item.front, phonetic: item.phonetic, meaning: item.back, senses: senses, example: ex)
    }

    func lookupSentence(_ sentence: String) async -> VocabItem? {
        await ensureIndex()
        let keys = sentenceLookupKeys(sentence)
        if keys.isEmpty { return nil }

        var loc: (category: String, file: URL, entryIdx: Int, sentenceIdx: Int)?
        for key in keys {
            if let hit = sentenceLookupIndex[key] {
                loc = hit
                break
            }
        }
        if loc == nil {
            for key in keys {
                await ensureLookupCandidateLoaded(wordKey: nil, sentenceKey: key)
                if let hit = sentenceLookupIndex[key] {
                    loc = hit
                    break
                }
            }
        }
        guard let loc else { return nil }
        guard let entries = try? await loadEntries(for: loc.file),
              loc.entryIdx >= 0, loc.entryIdx < entries.count else { return nil }
        let entry = entries[loc.entryIdx]
        guard let sentences = entry.sentences, loc.sentenceIdx >= 0, loc.sentenceIdx < sentences.count else { return nil }
        return makeSentenceItem(from: sentences[loc.sentenceIdx], category: loc.category)
    }

    private func ensureIndex() async {
        if indexed { return }
        indexed = true

        let rootPath = config.offlineVocabPathEffective
        guard !rootPath.isEmpty else { return }

        let jsonDir = URL(fileURLWithPath: rootPath, isDirectory: true)
            .appendingPathComponent("json_original", isDirectory: true)
            .appendingPathComponent("json-sentence", isDirectory: true)

        guard FileManager.default.fileExists(atPath: jsonDir.path) else { return }

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: jsonDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var byCat: [String: [URL]] = [:]
        var byFile: [URL: String] = [:]
        for url in files where url.pathExtension.lowercased() == "json" {
            let base = url.deletingPathExtension().lastPathComponent
            guard let cat = categoryId(forFileBaseName: base) else { continue }
            byCat[cat, default: []].append(url)
            byFile[url] = cat
        }
        for (k, arr) in byCat {
            byCat[k] = arr.sorted { a, b in a.lastPathComponent < b.lastPathComponent }
        }
        filesByCategory = byCat
        categoryByFile = byFile
    }

    private func loadEntries(for url: URL) async throws -> [Entry] {
        if let cached = entriesCache[url] {
            scannedFiles.insert(url)
            return cached
        }

        let data = try Data(contentsOf: url)

        if let arr = try? decoder.decode([Entry].self, from: data) {
            entriesCache[url] = arr
            indexEntries(arr, file: url)
            scannedFiles.insert(url)
            return arr
        }
        if let single = try? decoder.decode(Entry.self, from: data) {
            let arr = [single]
            entriesCache[url] = arr
            indexEntries(arr, file: url)
            scannedFiles.insert(url)
            return arr
        }

        throw NSError(domain: "OfflineVocabProvider", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Failed to decode \(url.lastPathComponent)",
        ])
    }

    private func indexEntries(_ entries: [Entry], file: URL) {
        guard let cat = categoryByFile[file] else { return }
        for (idx, e) in entries.enumerated() {
            let w = normalizeWord(e.word)
            if !w.isEmpty, lookupIndex[w] == nil {
                lookupIndex[w] = (category: cat, file: file, idx: idx)
            }
            if let sentences = e.sentences {
                for (sidx, s) in sentences.enumerated() {
                    for key in sentenceLookupKeys(s.sentence) {
                        if key.isEmpty { continue }
                        if sentenceLookupIndex[key] != nil { continue }
                        sentenceLookupIndex[key] = (category: cat, file: file, entryIdx: idx, sentenceIdx: sidx)
                    }
                }
            }
        }
    }

    private func ensureLookupCandidateLoaded(wordKey: String?, sentenceKey: String?) async {
        if let wordKey, lookupIndex[wordKey] != nil { return }
        if let sentenceKey, sentenceLookupIndex[sentenceKey] != nil { return }
        if fullyScannedFiles { return }

        for file in allFiles() {
            if scannedFiles.contains(file) { continue }
            _ = try? await loadEntries(for: file)
            scannedFiles.insert(file)
            if let wordKey, lookupIndex[wordKey] != nil { return }
            if let sentenceKey, sentenceLookupIndex[sentenceKey] != nil { return }
        }

        fullyScannedFiles = true
    }

    private func allFiles() -> [URL] {
        var all: [URL] = []
        for arr in filesByCategory.values {
            all.append(contentsOf: arr)
        }
        return all.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func makeWordItem(from entry: Entry, category: String) -> VocabItem {
        let w = entry.word.trimmingCharacters(in: .whitespacesAndNewlines)

        let (meaning, senses) = normalizeMeaningAndSenses(translations: entry.translations)

        let phonetic = normalizePhonetic(us: entry.us, uk: entry.uk)

        var examples: [VocabExample] = []
        if let sentences = entry.sentences, let s = sentences.first {
            let en = s.sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            let zh = s.translation.trimmingCharacters(in: .whitespacesAndNewlines)
            if !en.isEmpty {
                examples.append(VocabExample(en: en, zh: zh, createdAt: Date()))
            }
        }

        return VocabItem(
            id: UUID(),
            type: .word,
            front: w,
            back: meaning,
            phonetic: phonetic,
            category: category,
            source: "offline",
            senses: senses.isEmpty ? nil : senses,
            examples: examples,
            createdAt: Date(),
            lastShownAt: nil,
            timesShown: 0
        )
    }

    private func makeSentenceItem(from sentence: Entry.Sentence, category: String) -> VocabItem {
        let en = sentence.sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        let zh = sentence.translation.trimmingCharacters(in: .whitespacesAndNewlines)
        return VocabItem(
            id: UUID(),
            type: .sentence,
            front: en,
            back: zh,
            phonetic: nil,
            category: category,
            source: "offline",
            senses: nil,
            examples: [],
            createdAt: Date(),
            lastShownAt: nil,
            timesShown: 0
        )
    }

    private func normalizePhonetic(us: String?, uk: String?) -> String? {
        let u = (us ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let k = (uk ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        func wrap(_ s: String) -> String {
            let t = s
            if t.hasPrefix("/") && t.hasSuffix("/") { return t }
            if t.isEmpty { return t }
            // Best effort: show as IPA-like.
            return "/\(t)/"
        }

        if !u.isEmpty { return wrap(u) }
        if !k.isEmpty { return wrap(k) }
        return nil
    }

    private func normalizeMeaningAndSenses(translations: [Entry.Translation]?) -> (String, [WordSense]) {
        let ts = translations ?? []
        if ts.isEmpty {
            return ("", [])
        }

        var lines: [String] = []
        var senses: [WordSense] = []
        for (idx, t) in ts.enumerated() {
            let meaning = t.translation.trimmingCharacters(in: .whitespacesAndNewlines)
            if meaning.isEmpty { continue }
            let pos = normalizePos(t.type)
            let line = pos.isEmpty ? meaning : "\(pos) \(meaning)"
            lines.append(line)

            let freq = max(1, 5 - idx)
            senses.append(WordSense(pos: pos.isEmpty ? "·" : pos, meaning: meaning, freq: freq))
        }

        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (text.isEmpty ? "" : text, senses)
    }

    private func normalizePos(_ raw: String?) -> String {
        let t = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "" }
        if t.hasSuffix(".") { return t }
        return "\(t)."
    }

    private func categoryId(forFileBaseName base: String) -> String? {
        if base.hasPrefix("WaiYanSheChuZhong") || base.hasPrefix("PEPChuZhong") || base.hasPrefix("ChuZhong") {
            return "junior"
        }
        if base.hasPrefix("BeiShiGaoZhong") || base.hasPrefix("PEPGaoZhong") || base.hasPrefix("GaoZhong") {
            return "high"
        }
        if base.hasPrefix("CET4") {
            return "cet4"
        }
        if base.hasPrefix("CET6") {
            return "cet6"
        }
        if base.hasPrefix("KaoYan") {
            return "kaoyan"
        }
        if base.hasPrefix("TOEFL") {
            return "toefl"
        }
        if base.hasPrefix("SAT") {
            return "sat"
        }
        return nil
    }

    private func normalizeWord(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func normalizeSentence(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "" }
        let singleSpaced = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return singleSpaced.lowercased()
    }

    private func sentenceLookupKeys(_ s: String) -> [String] {
        let base = normalizeSentence(s)
        if base.isEmpty { return [] }

        var trimSet = CharacterSet.whitespacesAndNewlines
        trimSet.formUnion(.punctuationCharacters)
        trimSet.formUnion(.symbols)

        let stripped = base.trimmingCharacters(in: trimSet)
        if stripped.isEmpty || stripped == base {
            return [base]
        }
        return [base, stripped]
    }
}
