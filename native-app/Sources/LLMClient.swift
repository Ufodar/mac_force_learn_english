import Foundation

enum LLMError: Error, CustomStringConvertible {
    case missingConfig(String)
    case invalidURL(String)
    case httpError(Int, String)
    case invalidResponse(String)

    var description: String {
        switch self {
        case .missingConfig(let s): return "missing config: \(s)"
        case .invalidURL(let s): return "invalid url: \(s)"
        case .httpError(let code, let body): return "http \(code): \(body)"
        case .invalidResponse(let s): return "invalid response: \(s)"
        }
    }
}

final class LLMClient {
    struct GeneratedItemPayload: Codable {
        var type: String
        var front: String
        var back: String
        var phonetic: String?
        var category: String?
        var exampleEn: String?
        var exampleZh: String?
    }

    private let config: AppConfig
    private let decoder = JSONDecoder()

    init(config: AppConfig = .shared) {
        self.config = config
    }

    func generateItem(existingDedupeKeys: Set<String>) async throws -> VocabItem {
        guard config.llmEnabled else { throw LLMError.missingConfig("llm disabled") }
        guard !config.llmEndpoint.isEmpty else { throw LLMError.missingConfig("endpoint") }
        guard !config.llmModel.isEmpty else { throw LLMError.missingConfig("model") }

        let categories = config.enabledCategories.joined(separator: ", ")

        let roll = Int.random(in: 1...(max(1, config.wordWeight + config.sentenceWeight)))
        let wantWord = roll <= config.wordWeight

        let prompt: String
        if wantWord {
            prompt = """
            你是一个英语学习内容生成器。请生成 1 个英文单词，偏向：计算机/高考3500/四级/六级，避免太生僻。
            你必须避免重复（如果你看到一个候选词疑似重复，就换一个新词）。
            输出必须是严格 JSON（不要 Markdown，不要额外文本），格式如下：
            {"type":"word","front":"WORD","phonetic":"/IPA/","back":"中文释义（简洁，1-2行）","category":"cs|gaokao3500|cet4|cet6","exampleEn":"英文例句（尽量计算机/学习场景）","exampleZh":"例句中文翻译"}
            额外要求：
            - phonetic 必须是 IPA，形如 /.../
            - back 不要包含 IPA（IPA 放 phonetic）
            - category 从 [\(categories)] 中选 1 个
            """
        } else {
            prompt = """
            你是一个英语学习内容生成器。请生成 1 句英文短句（适合背诵，偏向计算机/学习/职场），并给出中文翻译。
            输出必须是严格 JSON（不要 Markdown，不要额外文本），格式如下：
            {"type":"sentence","front":"ENGLISH","back":"中文翻译","category":"cs|gaokao3500|cet4|cet6"}
            category 从 [\(categories)] 中选 1 个
            """
        }

        let maxAttempts = 6
        for attempt in 1...maxAttempts {
            let content = try await requestLLM(prompt: prompt, attempt: attempt)
            guard let payload = parsePayload(from: content) else {
                if attempt == maxAttempts { throw LLMError.invalidResponse("cannot parse json") }
                continue
            }

            let t: VocabItemType = (payload.type.lowercased() == "sentence") ? .sentence : .word
            let dedupe = VocabStore.dedupeKey(type: t, front: payload.front)
            if existingDedupeKeys.contains(dedupe) {
                if attempt == maxAttempts { throw LLMError.invalidResponse("too many duplicates") }
                continue
            }

            var examples: [VocabExample] = []
            if t == .word, let exEn = payload.exampleEn, !exEn.isEmpty {
                examples.append(VocabExample(en: exEn, zh: payload.exampleZh ?? "", createdAt: Date()))
            }

            return VocabItem(
                id: UUID(),
                type: t,
                front: payload.front.trimmingCharacters(in: .whitespacesAndNewlines),
                back: payload.back.trimmingCharacters(in: .whitespacesAndNewlines),
                phonetic: payload.phonetic?.trimmingCharacters(in: .whitespacesAndNewlines),
                category: payload.category,
                examples: examples,
                createdAt: Date(),
                lastShownAt: nil,
                timesShown: 0
            )
        }

        throw LLMError.invalidResponse("unreachable")
    }

    func generateExample(for word: String) async throws -> VocabExample {
        guard !config.llmEndpoint.isEmpty else { throw LLMError.missingConfig("endpoint") }
        guard !config.llmModel.isEmpty else { throw LLMError.missingConfig("model") }

        let prompt = """
        给单词 \"\(word)\" 生成 1 个英文例句（尽量贴近计算机/学习/工作语境），并给出中文翻译。
        输出必须是严格 JSON（不要 Markdown，不要额外文本），格式如下：
        {"exampleEn":"...","exampleZh":"..."}
        """

        let maxAttempts = 4
        for attempt in 1...maxAttempts {
            let content = try await requestLLM(prompt: prompt, attempt: attempt)
            if let obj = try? decoder.decode([String: String].self, from: Data(content.utf8)),
               let en = obj["exampleEn"], !en.isEmpty {
                return VocabExample(en: en, zh: obj["exampleZh"] ?? "", createdAt: Date())
            }
        }
        throw LLMError.invalidResponse("cannot parse example")
    }

    private func parsePayload(from content: String) -> GeneratedItemPayload? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)

        if let data = trimmed.data(using: .utf8),
           let payload = try? decoder.decode(GeneratedItemPayload.self, from: data) {
            return payload
        }

        // 容错：尝试从文本中截取第一个 {...} JSON
        if let start = trimmed.firstIndex(of: "{"),
           let end = trimmed.lastIndex(of: "}") {
            let sub = String(trimmed[start...end])
            if let data = sub.data(using: .utf8),
               let payload = try? decoder.decode(GeneratedItemPayload.self, from: data) {
                return payload
            }
        }
        return nil
    }

    private func requestLLM(prompt: String, attempt: Int) async throws -> String {
        let endpoint = config.llmEndpoint
        guard let url = URL(string: endpoint) else { throw LLMError.invalidURL(endpoint) }

        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.llmApiKey.isEmpty {
            request.setValue("Bearer \(config.llmApiKey)", forHTTPHeaderField: "Authorization")
        }

        let body: [String: Any]
        if url.path.contains("/chat/completions") {
            body = [
                "model": config.llmModel,
                "messages": [
                    ["role": "system", "content": "You are a helpful assistant. Output JSON only."],
                    ["role": "user", "content": prompt],
                ],
                "temperature": 0.7,
                "max_tokens": 300,
            ]
        } else {
            body = [
                "model": config.llmModel,
                "prompt": prompt,
                "temperature": 0.7,
                "max_tokens": 300,
            ]
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse("no http response")
        }
        if !(200...299).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            let snippet = String(bodyText.prefix(400))
            if http.statusCode == 503 {
                let delay = min(3.0, 0.3 * Double(attempt * attempt))
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            throw LLMError.httpError(http.statusCode, snippet)
        }

        return try parseOpenAIContent(from: data, url: url)
    }

    private func parseOpenAIContent(from data: Data, url: URL) throws -> String {
        let obj = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dict = obj as? [String: Any] else { throw LLMError.invalidResponse("not json object") }

        if url.path.contains("/chat/completions") {
            if let choices = dict["choices"] as? [[String: Any]],
               let first = choices.first,
               let msg = first["message"] as? [String: Any],
               let content = msg["content"] as? String {
                return content
            }
            throw LLMError.invalidResponse("missing choices.message.content")
        }

        if let choices = dict["choices"] as? [[String: Any]],
           let first = choices.first,
           let text = first["text"] as? String {
            return text
        }
        throw LLMError.invalidResponse("missing choices.text")
    }
}
