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
    enum SmartReadMode {
        case cleanSummary
        case codeExplain
    }

    struct GeneratedItemPayload: Codable {
        var type: String
        var front: String
        var back: String
        var phonetic: String?
        var category: String?
        var exampleEn: String?
        var exampleZh: String?
    }

    struct WordLookupPayload: Codable {
        var phonetic: String?
        var meaning: String
    }

    struct WordLookupDetailsPayload: Codable {
        var phonetic: String?
        var senses: [WordSense]
    }

    private let config: AppConfig
    private let decoder = JSONDecoder()

    init(config: AppConfig = .shared) {
        self.config = config
    }

    func generateItem(existingDedupeKeys: Set<String>) async throws -> VocabItem {
        guard config.llmEnabled else { throw LLMError.missingConfig("llm disabled") }
        guard !config.llmEndpointEffective.isEmpty else { throw LLMError.missingConfig("endpoint") }
        guard !config.llmModelEffective.isEmpty else { throw LLMError.missingConfig("model") }

        let categories = config.enabledCategories.joined(separator: ", ")

        let roll = Int.random(in: 1...(max(1, config.wordWeight + config.sentenceWeight)))
        let wantWord = roll <= config.wordWeight

        let prompt: String
        if wantWord {
            prompt = """
            你是一个英语学习内容生成器。请生成 1 个英文单词，偏向：计算机/学习/考试词汇（初中/高中/四级/六级/考研/托福/SAT），避免太生僻。
            你必须避免重复（如果你看到一个候选词疑似重复，就换一个新词）。
            输出必须是严格 JSON（不要 Markdown，不要额外文本），格式如下：
            {"type":"word","front":"WORD","phonetic":"/IPA/","back":"中文释义（简洁，1-2行）","category":"junior|high|cet4|cet6|kaoyan|toefl|sat","exampleEn":"英文例句（尽量计算机/学习场景）","exampleZh":"例句中文翻译"}
            额外要求：
            - phonetic 必须是 IPA，形如 /.../
            - back 不要包含 IPA（IPA 放 phonetic）
            - category 从 [\(categories)] 中选 1 个
            """
        } else {
            prompt = """
            你是一个英语学习内容生成器。请生成 1 句英文短句（适合背诵，偏向计算机/学习/职场），并给出中文翻译。
            输出必须是严格 JSON（不要 Markdown，不要额外文本），格式如下：
            {"type":"sentence","front":"ENGLISH","back":"中文翻译","category":"junior|high|cet4|cet6|kaoyan|toefl|sat"}
            category 从 [\(categories)] 中选 1 个
            """
        }

        let maxAttempts = 6
        for attempt in 1...maxAttempts {
            let content: String
            do {
                content = try await requestLLM(prompt: prompt, attempt: attempt)
            } catch {
                if attempt == maxAttempts { throw error }
                continue
            }

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
        guard !config.llmEndpointEffective.isEmpty else { throw LLMError.missingConfig("endpoint") }
        guard !config.llmModelEffective.isEmpty else { throw LLMError.missingConfig("model") }

        let prompt = """
        给单词 \"\(word)\" 生成 1 个英文例句（尽量贴近计算机/学习/工作语境），并给出中文翻译。
        输出必须是严格 JSON（不要 Markdown，不要额外文本），格式如下：
        {"exampleEn":"...","exampleZh":"..."}
        """

        let maxAttempts = 4
        for attempt in 1...maxAttempts {
            let content: String
            do {
                content = try await requestLLM(prompt: prompt, attempt: attempt)
            } catch {
                if attempt == maxAttempts { throw error }
                continue
            }
            if let obj = try? decoder.decode([String: String].self, from: Data(content.utf8)),
               let en = obj["exampleEn"], !en.isEmpty {
                return VocabExample(en: en, zh: obj["exampleZh"] ?? "", createdAt: Date())
            }
        }
        throw LLMError.invalidResponse("cannot parse example")
    }

    func translate(text: String, target: String) async throws -> String {
        guard !config.llmEndpointEffective.isEmpty else { throw LLMError.missingConfig("endpoint") }
        guard !config.llmModelEffective.isEmpty else { throw LLMError.missingConfig("model") }

        let to = target.lowercased() == "zh" ? "中文" : "英文"
        let translateSystemPrompt = "You are a precise translation engine. Do not add, explain, expand, or omit meaning. Output JSON only."
        let maxTokens = max(220, min(1200, text.count * 2))
        let prompt = """
        你是严谨翻译器。请把给定文本翻译成\(to)。
        输出必须是严格 JSON（不要 Markdown，不要额外文本）：
        {"translation":"..."}

        硬性规则（必须遵守）：
        1) 只翻译，不解释，不扩展，不补全，不续写，不举例。
        2) 不新增原文没有的信息；不改变事实、语气、时态、主语。
        3) 原文若是不完整片段/短语/标题，译文也保持片段，不补成完整句。
        4) 保留专有名词、数字、URL、代码标记与换行结构（除非直译必需微调）。
        5) 不要输出“翻译：/Translation:”等标签。

        待翻译文本（仅翻译此段）：
        <<<SOURCE>>>
        \(text)
        <<<END_SOURCE>>>
        """

        let maxAttempts = 4
        for attempt in 1...maxAttempts {
            let content: String
            do {
                content = try await requestLLM(
                    prompt: prompt,
                    attempt: attempt,
                    temperature: 0.1,
                    maxTokens: maxTokens,
                    systemPrompt: translateSystemPrompt
                )
            } catch {
                if attempt == maxAttempts { throw error }
                continue
            }

            if let obj = try? decoder.decode([String: String].self, from: Data(content.utf8)),
               let t = obj["translation"] {
                let cleaned = normalizeTranslationText(t)
                if !cleaned.isEmpty { return cleaned }
            }

            // 容错：尝试从文本中截取第一个 {...} JSON
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if let start = trimmed.firstIndex(of: "{"),
               let end = trimmed.lastIndex(of: "}") {
                let sub = String(trimmed[start...end])
                if let obj = try? decoder.decode([String: String].self, from: Data(sub.utf8)),
                   let t = obj["translation"] {
                    let cleaned = normalizeTranslationText(t)
                    if !cleaned.isEmpty { return cleaned }
                }
            }
        }

        throw LLMError.invalidResponse("cannot parse translation")
    }

    func lookupWord(_ word: String, target: String) async throws -> WordLookupPayload {
        guard !config.llmEndpointEffective.isEmpty else { throw LLMError.missingConfig("endpoint") }
        guard !config.llmModelEffective.isEmpty else { throw LLMError.missingConfig("model") }

        let to = target.lowercased() == "zh" ? "中文" : "英文"
        let prompt = """
        你是英语词典。请给单词 \"\(word)\" 提供 IPA 音标 + \(to)释义（简洁，1-2 行）。
        输出必须是严格 JSON（不要 Markdown，不要额外文本），格式如下：
        {"phonetic":"/IPA/","meaning":"..."}
        要求：
        - phonetic 必须是 IPA，形如 /.../
        - meaning 不要包含 IPA
        """

        let maxAttempts = 4
        for attempt in 1...maxAttempts {
            let content: String
            do {
                content = try await requestLLM(prompt: prompt, attempt: attempt)
            } catch {
                if attempt == maxAttempts { throw error }
                continue
            }

            if let payload: WordLookupPayload = parseJSON(content, as: WordLookupPayload.self),
               !payload.meaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return WordLookupPayload(
                    phonetic: payload.phonetic?.trimmingCharacters(in: .whitespacesAndNewlines),
                    meaning: payload.meaning.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        }

        throw LLMError.invalidResponse("cannot parse word lookup")
    }

    func lookupWordDetails(_ word: String, target: String) async throws -> WordLookupDetailsPayload {
        guard !config.llmEndpointEffective.isEmpty else { throw LLMError.missingConfig("endpoint") }
        guard !config.llmModelEffective.isEmpty else { throw LLMError.missingConfig("model") }

        let to = target.lowercased() == "zh" ? "中文" : "英文"
        let prompt = """
        你是英语词典。请给单词 \"\(word)\" 提供：
        1) IPA 音标
        2) 多种释义（最多 6 个），每条包含词性 pos、释义 meaning、常用频率 freq。

        输出必须是严格 JSON（不要 Markdown，不要额外文本），格式如下：
        {"phonetic":"/IPA/","senses":[{"pos":"n.","meaning":"...","freq":5}]}

        规则：
        - phonetic 必须是 IPA，形如 /.../
        - meaning 用 \(to)，不要包含 IPA
        - freq 取 1-5 的整数，5 最常用
        - senses 按 freq 从高到低排序（像有道词典那样先给最常用释义）
        """

        let maxAttempts = 4
        for attempt in 1...maxAttempts {
            let content: String
            do {
                content = try await requestLLM(prompt: prompt, attempt: attempt)
            } catch {
                if attempt == maxAttempts { throw error }
                continue
            }

            if var payload: WordLookupDetailsPayload = parseJSON(content, as: WordLookupDetailsPayload.self) {
                payload.phonetic = payload.phonetic?.trimmingCharacters(in: .whitespacesAndNewlines)
                payload.senses = payload.senses
                    .map { WordSense(pos: $0.pos.trimmingCharacters(in: .whitespacesAndNewlines), meaning: $0.meaning.trimmingCharacters(in: .whitespacesAndNewlines), freq: $0.freq) }
                    .filter { !$0.pos.isEmpty && !$0.meaning.isEmpty }
                    .sorted { a, b in
                        if a.freq != b.freq { return a.freq > b.freq }
                        return a.meaning.count < b.meaning.count
                    }
                if !payload.senses.isEmpty { return payload }
            }
        }

        throw LLMError.invalidResponse("cannot parse word details")
    }

    func ask(selection: String, question: String) async throws -> String {
        guard !config.llmEndpointEffective.isEmpty else { throw LLMError.missingConfig("endpoint") }
        guard !config.llmModelEffective.isEmpty else { throw LLMError.missingConfig("model") }

        let systemPrompt = """
        You are a helpful assistant.
        - Answer in the same language as the user's question.
        - Be concise unless the user asks for detail.
        - Use plain text (no JSON).
        """

        let prompt = """
        用户问题：
        \(question)

        选中的文字：
        <<<SELECTION>>>
        \(selection)
        <<<END_SELECTION>>>

        请结合「用户问题」与「选中的文字」给出回复。
        """

        let maxAttempts = 3
        for attempt in 1...maxAttempts {
            let content: String
            do {
                content = try await requestLLM(
                    prompt: prompt,
                    attempt: attempt,
                    temperature: 0.3,
                    maxTokens: 700,
                    systemPrompt: systemPrompt
                )
            } catch {
                if attempt == maxAttempts { throw error }
                continue
            }

            let cleaned = normalizeAssistantText(content)
            if !cleaned.isEmpty { return cleaned }
        }

        throw LLMError.invalidResponse("empty response")
    }

    func smartRead(selection: String, mode: SmartReadMode, didTruncate: Bool) async throws -> String {
        guard !config.llmEndpointEffective.isEmpty else { throw LLMError.missingConfig("endpoint") }
        guard !config.llmModelEffective.isEmpty else { throw LLMError.missingConfig("model") }

        let systemPrompt = """
        You are a driving-friendly narrator.
        - Output plain text only (no JSON, no Markdown).
        - Make it easy to listen to: short paragraphs, clear transitions.
        - If content contains code/URLs/logs, do not read them verbatim unless very short and essential.
        """

        let modeHint: String
        switch mode {
        case .cleanSummary:
            modeHint = """
            任务：把选中内容改写成“适合开车听”的口播稿。
            - 优先讲清楚核心观点、结论、关键步骤/要点。
            - 省略或概括：长代码、堆栈、长命令、长 URL、无意义的符号。
            - 如果必须提到代码：只保留 1-2 行以内的关键片段，其余用自然语言描述。
            - 默认时长：约 1-3 分钟的语音长度（内容太长就概括）。
            """
        case .codeExplain:
            modeHint = """
            任务：把选中代码讲解成“适合开车听”的讲解稿（像你在讲课/讲故事）。
            - 先一句话说它“整体做什么”。
            - 再按模块/函数/流程讲清楚：输入→处理→输出，关键状态与边界条件。
            - 不要逐行朗读代码；最多引用 1-2 行关键代码，其余用自然语言解释。
            - 如果代码很长：先讲结构，再讲最重要的 3-6 个点。
            - 默认时长：约 2-5 分钟语音长度。
            """
        }

        let truncateHint = didTruncate ? "注意：输入内容已被截断（只看到部分片段），回答时请注明“可能不完整”。" : ""

        let prompt = """
        \(modeHint)
        \(truncateHint)

        选中内容：
        <<<SELECTION>>>
        \(selection)
        <<<END_SELECTION>>>

        请直接输出口播稿正文（纯文本）。
        """

        let maxAttempts = 3
        for attempt in 1...maxAttempts {
            let content: String
            do {
                content = try await requestLLM(
                    prompt: prompt,
                    attempt: attempt,
                    temperature: 0.2,
                    maxTokens: 900,
                    systemPrompt: systemPrompt
                )
            } catch {
                if attempt == maxAttempts { throw error }
                continue
            }

            let cleaned = normalizeAssistantText(content)
            if !cleaned.isEmpty { return cleaned }
        }

        throw LLMError.invalidResponse("empty response")
    }

    private func parsePayload(from content: String) -> GeneratedItemPayload? {
        parseJSON(content, as: GeneratedItemPayload.self)
    }

    private func parseJSON<T: Decodable>(_ content: String, as type: T.Type) -> T? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)

        if let data = trimmed.data(using: .utf8),
           let obj = try? decoder.decode(T.self, from: data) {
            return obj
        }

        // 容错：尝试从文本中截取第一个 {...} JSON
        if let start = trimmed.firstIndex(of: "{"),
           let end = trimmed.lastIndex(of: "}") {
            let sub = String(trimmed[start...end])
            if let data = sub.data(using: .utf8),
               let obj = try? decoder.decode(T.self, from: data) {
                return obj
            }
        }
        return nil
    }

    private func normalizeTranslationText(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return "" }

        if s.hasPrefix("```"), let firstNL = s.firstIndex(of: "\n"), let lastFence = s.range(of: "```", options: .backwards) {
            let body = s[s.index(after: firstNL)..<lastFence.lowerBound]
            s = String(body).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let prefixes = ["翻译：", "译文：", "中文：", "英文：", "translation:", "Translation:"]
        for p in prefixes {
            if s.hasPrefix(p) {
                s = String(s.dropFirst(p.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        if (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("“") && s.hasSuffix("”")) {
            s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }

    private func normalizeAssistantText(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return "" }

        if s.hasPrefix("```"),
           let firstNL = s.firstIndex(of: "\n"),
           let lastFence = s.range(of: "```", options: .backwards),
           lastFence.lowerBound > firstNL {
            let body = s[s.index(after: firstNL)..<lastFence.lowerBound]
            s = String(body).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // If the model still outputs JSON, try to extract a common answer field.
        if let data = s.data(using: .utf8),
           let obj = try? decoder.decode([String: String].self, from: data) {
            for key in ["answer", "response", "content", "text"] {
                if let v = obj[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                    return v
                }
            }
        }

        return s
    }

    private func requestLLM(
        prompt: String,
        attempt: Int,
        temperature: Double = 0.7,
        maxTokens: Int = 300,
        systemPrompt: String = "You are a helpful assistant. Output JSON only."
    ) async throws -> String {
        let endpoint = config.llmEndpointEffective
        guard let primaryURL = URL(string: endpoint) else { throw LLMError.invalidURL(endpoint) }

        do {
            return try await requestLLM(
                at: primaryURL,
                prompt: prompt,
                attempt: attempt,
                temperature: temperature,
                maxTokens: maxTokens,
                systemPrompt: systemPrompt
            )
        } catch let LLMError.httpError(code, _) where code == 404 || code == 405 {
            if let altURL = alternateCompletionsURL(from: primaryURL) {
                return try await requestLLM(
                    at: altURL,
                    prompt: prompt,
                    attempt: attempt,
                    temperature: temperature,
                    maxTokens: maxTokens,
                    systemPrompt: systemPrompt
                )
            }
            throw LLMError.httpError(code, "endpoint not found")
        }
    }

    private func requestLLM(
        at url: URL,
        prompt: String,
        attempt: Int,
        temperature: Double,
        maxTokens: Int,
        systemPrompt: String
    ) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let apiKey = config.llmApiKeyEffective
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let body: [String: Any]
        if url.path.contains("/chat/completions") {
            body = [
                "model": config.llmModelEffective,
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": prompt],
                ],
                "temperature": temperature,
                "max_tokens": max(80, maxTokens),
            ]
        } else {
            body = [
                "model": config.llmModelEffective,
                "prompt": prompt,
                "temperature": temperature,
                "max_tokens": max(80, maxTokens),
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

    private func alternateCompletionsURL(from url: URL) -> URL? {
        // /v1/chat/completions <-> /v1/completions
        if url.path.hasSuffix("/chat/completions") {
            let newPath = url.path.replacingOccurrences(of: "/chat/completions", with: "/completions")
            return URL(string: url.absoluteString.replacingOccurrences(of: url.path, with: newPath))
        }
        if url.path.hasSuffix("/completions") {
            let newPath = url.path.replacingOccurrences(of: "/completions", with: "/chat/completions")
            return URL(string: url.absoluteString.replacingOccurrences(of: url.path, with: newPath))
        }
        return nil
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
