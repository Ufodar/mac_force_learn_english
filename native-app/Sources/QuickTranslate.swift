import ApplicationServices
import AVFoundation
import Carbon.HIToolbox
import Cocoa

private let quickTranslateHotKeySignature: OSType = OSType(0x4D464C45) // "MFLE"
private let quickTranslateHotKeyId: UInt32 = 1
private let quickTranslateCopyWaitSeconds: CFAbsoluteTime = 2.8

private let quickTranslateHotKeyHandler: EventHandlerUPP = { _, theEvent, userData in
    guard let theEvent, let userData else { return noErr }

    var hkID = EventHotKeyID()
    let err = GetEventParameter(
        theEvent,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hkID
    )
    if err != noErr { return noErr }
    if hkID.signature != quickTranslateHotKeySignature || hkID.id != quickTranslateHotKeyId { return noErr }

    let controller = Unmanaged<QuickTranslateController>.fromOpaque(userData).takeUnretainedValue()
    Task { @MainActor in
        controller.translateSelectionNow()
    }
    return noErr
}

@MainActor
private final class QuickTranslatePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class QuickTranslateController {
    private var mouseMonitor: Any?
    private var debounceWorkItem: DispatchWorkItem?
    private var currentTask: Task<Void, Never>?
    private var pollTimer: Timer?
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var lastEnsureAttemptAt: CFAbsoluteTime = 0
    private var didShowPermissionHint: Bool = false
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?
    private var lastHotKeyAt: CFAbsoluteTime = 0
    private var isFetchingDetails: Bool = false
    private var outsideClickGlobalMonitor: Any?
    private var outsideClickLocalMonitor: Any?

    private var lastText: String = ""
    private var pendingPollText: String = ""
    private var lastAnchorPoint: NSPoint = .zero
    private var currentLookupWord: String?
    private var currentOriginalForSpeech: String = ""
    private var currentTranslatedForSpeech: String = ""

    private let store: VocabStore
    private let llm: LLMClient
    private let offline: OfflineVocabProvider
    private let speechSynth = AVSpeechSynthesizer()
    private let panel: QuickTranslatePanel
    private let contentView: QuickTranslateView

    init(store: VocabStore, llm: LLMClient = LLMClient(), offline: OfflineVocabProvider = OfflineVocabProvider()) {
        self.store = store
        self.llm = llm
        self.offline = offline

        self.contentView = QuickTranslateView(frame: NSRect(x: 0, y: 0, width: 360, height: 120))

        let p = QuickTranslatePanel(
            contentRect: contentView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.ignoresMouseEvents = false
        p.isMovable = true
        p.isMovableByWindowBackground = true
        p.contentView = contentView
        p.orderOut(nil)

        self.panel = p

        contentView.onDetailsToggled = { [weak self] in
            self?.resizeAndReposition()
        }
        contentView.onRequestMoreMeanings = { [weak self] in
            Task { @MainActor in
                await self?.fetchMoreMeaningsIfNeeded()
            }
        }
        contentView.onSpeakRequested = { [weak self] in
            self?.speakCurrent()
        }
    }

    func applyConfig() {
        stop()
        if AppConfig.shared.quickTranslateEnabled { start() }
    }

    func start() {
        guard isInstalledInApplicationsFolder() else {
            show(
                original: "Quick Translate disabled",
                phonetic: nil,
                translated: "Move the app to /Applications to make macOS permissions stick.",
                isWord: false,
                senses: nil,
                llmUsed: false
            )
            return
        }

        requestAccessibilityPromptIfNeeded()

        if AppConfig.shared.quickTranslateTrigger.lowercased() == "auto" {
            requestInputMonitoringPromptIfNeeded()
            ensureMonitors(throttled: false)
            startPolling()
        } else {
            setupHotKeyIfNeeded()
            show(
                original: "Quick Translate",
                phonetic: nil,
                translated: "Select text then press ⌘⌥P",
                isWord: false,
                senses: nil,
                llmUsed: false
            )
        }

        showPermissionHintIfNeeded()
    }

    func stop() {
        if let m = mouseMonitor { NSEvent.removeMonitor(m) }
        mouseMonitor = nil
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        currentTask?.cancel()
        currentTask = nil
        isFetchingDetails = false
        currentLookupWord = nil
        currentOriginalForSpeech = ""
        currentTranslatedForSpeech = ""
        _ = speechSynth.stopSpeaking(at: .immediate)
        stopPolling()
        tearDownEventTap()
        tearDownHotKey()
        removeOutsideDismissMonitors()
        hide()
    }

    func translateSelectionNow() {
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastHotKeyAt < 0.25 { return }
        lastHotKeyAt = now

        guard AppConfig.shared.quickTranslateEnabled else { return }
        guard shouldHandleNow() else { return }

        guard let raw = fetchSelectedText() else {
            let selectionExists = hasSelectionViaAccessibility()
            show(
                original: selectionExists ? "Selection unavailable" : "No selection",
                phonetic: nil,
                translated: selectionExists
                    ? "Selected text could not be captured (often when content is too large). Try a shorter snippet, then press ⌘⌥P again."
                    : "Select a word/sentence first, then press ⌘⌥P",
                isWord: false,
                senses: nil,
                llmUsed: false
            )
            return
        }

        let text = normalizeSelectionForLookup(raw)
        if text.isEmpty {
            show(
                original: "No selection",
                phonetic: nil,
                translated: "Select a word/sentence first, then press ⌘⌥P",
                isWord: false,
                senses: nil,
                llmUsed: false
            )
            return
        }

        let limit = AppConfig.shared.quickTranslateMaxSelectionChars
        if text.count > limit {
            show(
                original: "Selection too long",
                phonetic: nil,
                translated: "Selected text is \(text.count) chars (limit \(limit)). Select a shorter snippet.",
                isWord: false,
                senses: nil,
                llmUsed: false
            )
            return
        }

        Task { @MainActor in
            await self.handleTrigger(text: text, allowDuplicate: true)
        }
    }

    private func scheduleCheck() {
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                await self?.handleTriggerFromEvent()
            }
        }
        debounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    private func handleTriggerFromEvent() async {
        guard AppConfig.shared.quickTranslateEnabled else { return }

        guard shouldHandleNow() else { return }
        guard let text = fetchSelectedText().map(normalizeSelectionForLookup), isReasonable(text) else { return }
        await handleTrigger(text: text, allowDuplicate: false)
    }

    private func pollSelectionTick() {
        guard AppConfig.shared.quickTranslateEnabled else { return }
        guard AppConfig.shared.quickTranslateTrigger.lowercased() == "auto" else { return }
        guard shouldHandleNow() else { return }

        ensureMonitors(throttled: true)

        let text = fetchSelectedTextViaAccessibility().map(normalizeText) ?? ""
        if text.isEmpty { pendingPollText = ""; return }
        if !isReasonable(text) { pendingPollText = ""; return }

        // Wait for the selection to be stable for at least two ticks.
        if text == pendingPollText {
            Task { @MainActor in
                await self.handleTrigger(text: text, allowDuplicate: false)
            }
        } else {
            pendingPollText = text
        }
    }

    private func handleTrigger(text: String, allowDuplicate: Bool) async {
        if !allowDuplicate, text == lastText { return }
        lastText = text

        currentTask?.cancel()
        currentTask = Task { [weak self] in
            guard let self else { return }
            var didUseLLM = false
            do {
                let target = resolveTargetLanguage(for: text)
                let kind = inferItemType(from: text)
                let preferOffline = AppConfig.shared.offlineEnabled && target == "zh"
                let llmReady = isLLMReady()

                // Word: prefer IPA lookup + cache
                if kind == .word, isEnglishWord(text) {
                    let cached = store.findItem(type: .word, front: text)

                    if let cached {
                        if Task.isCancelled { return }
                        await MainActor.run {
                            self.show(
                                original: text,
                                phonetic: cached.phonetic,
                                translated: cached.back,
                                isWord: true,
                                senses: cached.senses,
                                llmUsed: false
                            )
                        }
                        _ = saveLookupIfEnabled(itemType: .word, front: text, back: cached.back, phonetic: cached.phonetic, countAsShown: true)

                        if let p = cached.phonetic, !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            return
                        }
                    } else {
                        await MainActor.run {
                            self.show(original: text, phonetic: nil, translated: "Looking up…", isWord: true, senses: nil, llmUsed: nil)
                        }
                    }

                    if preferOffline, let offlineResult = await offline.lookupWord(text) {
                        if Task.isCancelled { return }
                        await MainActor.run {
                            self.show(
                                original: text,
                                phonetic: offlineResult.phonetic,
                                translated: offlineResult.meaning,
                                isWord: true,
                                senses: offlineResult.senses,
                                llmUsed: false
                            )
                        }
                        _ = saveLookupIfEnabled(
                            itemType: .word,
                            front: text,
                            back: offlineResult.meaning,
                            phonetic: offlineResult.phonetic,
                            senses: offlineResult.senses,
                            source: "offline",
                            countAsShown: (cached == nil)
                        )
                        return
                    }

                    if !llmReady {
                        if Task.isCancelled { return }
                        await MainActor.run {
                            self.show(
                                original: text,
                                phonetic: cached?.phonetic,
                                translated: "Offline dictionary has no match and LLM is not configured.",
                                isWord: true,
                                senses: cached?.senses,
                                llmUsed: false
                            )
                        }
                        return
                    }

                    didUseLLM = true
                    let payload = try await llm.lookupWord(text, target: target)
                    if Task.isCancelled { return }
                    await MainActor.run {
                        self.show(
                            original: text,
                            phonetic: payload.phonetic,
                            translated: payload.meaning,
                            isWord: true,
                            senses: cached?.senses,
                            llmUsed: true
                        )
                    }
                    _ = saveLookupIfEnabled(
                        itemType: .word,
                        front: text,
                        back: payload.meaning,
                        phonetic: payload.phonetic,
                        countAsShown: (cached == nil)
                    )
                    return
                }

                if let cached = store.findItem(type: kind, front: text) {
                    if Task.isCancelled { return }
                    await MainActor.run {
                        self.show(original: text, phonetic: nil, translated: cached.back, isWord: false, senses: nil, llmUsed: false)
                    }
                    _ = saveLookupIfEnabled(itemType: kind, front: text, back: cached.back, phonetic: nil, countAsShown: true)
                    return
                }

                if preferOffline, let sentence = await offline.lookupSentence(text) {
                    if Task.isCancelled { return }
                    await MainActor.run {
                        self.show(original: text, phonetic: nil, translated: sentence.back, isWord: false, senses: nil, llmUsed: false)
                    }
                    _ = saveLookupIfEnabled(
                        itemType: kind,
                        front: text,
                        back: sentence.back,
                        phonetic: nil,
                        senses: nil,
                        source: "offline",
                        countAsShown: true
                    )
                    return
                }

                if !llmReady {
                    if Task.isCancelled { return }
                    await MainActor.run {
                        self.show(
                            original: text,
                            phonetic: nil,
                            translated: "Offline dictionary has no match and LLM is not configured.",
                            isWord: false,
                            senses: nil,
                            llmUsed: false
                        )
                    }
                    return
                }

                await MainActor.run { self.show(original: text, phonetic: nil, translated: "Translating…", isWord: false, senses: nil, llmUsed: nil) }
                didUseLLM = true
                let translated = try await llm.translate(text: text, target: target)
                if Task.isCancelled { return }
                await MainActor.run {
                    self.show(original: text, phonetic: nil, translated: translated, isWord: false, senses: nil, llmUsed: true)
                }
                _ = saveLookupIfEnabled(itemType: kind, front: text, back: translated, phonetic: nil, countAsShown: true)
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    self.show(
                        original: text,
                        phonetic: nil,
                        translated: "Failed: \(error)",
                        isWord: false,
                        senses: nil,
                        llmUsed: didUseLLM ? true : false
                    )
                }
            }
        }
    }

    private func show(original: String, phonetic: String?, translated: String, isWord: Bool, senses: [WordSense]?, llmUsed: Bool?) {
        currentLookupWord = (isWord && isEnglishWord(original)) ? original : nil
        currentOriginalForSpeech = original
        currentTranslatedForSpeech = translated
        contentView.render(original: original, phonetic: phonetic, translated: translated, isWord: isWord, senses: senses, llmUsed: llmUsed)

        lastAnchorPoint = NSEvent.mouseLocation
        resizeAndReposition()
        panel.orderFrontRegardless()
        installOutsideDismissMonitors()
    }

    private func resizeAndReposition() {
        let size = contentView.preferredSize(maxWidth: 520)
        panel.setContentSize(size)

        let anchor = lastAnchorPoint
        let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)

        var x = anchor.x + 14
        var y = anchor.y - size.height - 14

        if x + size.width > screenFrame.maxX - 10 {
            x = screenFrame.maxX - size.width - 10
        }
        if x < screenFrame.minX + 10 {
            x = screenFrame.minX + 10
        }
        if y < screenFrame.minY + 10 {
            y = anchor.y + 14
        }
        if y + size.height > screenFrame.maxY - 10 {
            y = screenFrame.maxY - size.height - 10
        }

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func hide() {
        removeOutsideDismissMonitors()
        _ = speechSynth.stopSpeaking(at: .immediate)
        panel.orderOut(nil)
    }

    private func speakCurrent() {
        let original = currentOriginalForSpeech.trimmingCharacters(in: .whitespacesAndNewlines)
        let translated = currentTranslatedForSpeech.trimmingCharacters(in: .whitespacesAndNewlines)
        if original.isEmpty, translated.isEmpty { return }

        let textToRead: String
        if containsCJK(original), !translated.isEmpty, !containsCJK(translated) {
            textToRead = translated
        } else {
            textToRead = original.isEmpty ? translated : original
        }
        if textToRead.isEmpty { return }

        if speechSynth.isSpeaking {
            _ = speechSynth.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: textToRead)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        if let voice = bestVoice(for: textToRead) {
            utterance.voice = voice
        }
        speechSynth.speak(utterance)
    }

    private func bestVoice(for text: String) -> AVSpeechSynthesisVoice? {
        let wantZh = containsCJK(text)
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let prefixes = wantZh ? ["zh-Hans", "zh-CN", "zh"] : ["en-US", "en-GB", "en"]
        for p in prefixes {
            if let v = AVSpeechSynthesisVoice(language: p) { return v }
        }
        for v in voices {
            let locale = v.language
            if wantZh {
                if locale.lowercased().hasPrefix("zh") { return v }
            } else {
                if locale.lowercased().hasPrefix("en") { return v }
            }
        }
        return voices.first
    }

    private func resolveTargetLanguage(for text: String) -> String {
        let target = AppConfig.shared.quickTranslateTarget.lowercased()
        if target == "auto" {
            return containsCJK(text) ? "en" : "zh"
        }
        if target == "zh" { return "zh" }
        return "en"
    }

    private func shouldHandleNow() -> Bool {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let mine = Bundle.main.bundleIdentifier ?? ""
        return !mine.isEmpty && front != mine
    }

    private func isReasonable(_ text: String) -> Bool {
        let trimmed = normalizeText(text)
        if trimmed.isEmpty { return false }
        if trimmed.count > AppConfig.shared.quickTranslateMaxSelectionChars { return false }
        return true
    }

    private func fetchSelectedText() -> String? {
        if let s = fetchSelectedTextViaAccessibility() {
            let t = normalizeText(s)
            return t.isEmpty ? nil : t
        }
        if let s = fetchSelectedTextViaCopyPreservingClipboard(maxWaitSeconds: quickTranslateCopyWaitSeconds) {
            let t = normalizeText(s)
            return t.isEmpty ? nil : t
        }
        if let s = fetchSelectedTextViaCopyPreservingClipboard(maxWaitSeconds: quickTranslateCopyWaitSeconds + 1.6) {
            let t = normalizeText(s)
            return t.isEmpty ? nil : t
        }
        return nil
    }

    private func fetchSelectedTextViaAccessibility() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let okFocused = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused)
        guard okFocused == .success, let focused else { return nil }

        var selected: CFTypeRef?
        let element = focused as! AXUIElement
        let okSelected = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected)
        if okSelected == .success, let s = selected as? String, !s.isEmpty { return s }

        // Some apps expose range but not kAXSelectedTextAttribute.
        var rangeRef: CFTypeRef?
        let okRange = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef)
        if okRange == .success, let rangeRef {
            let rangeValue = rangeRef as! AXValue
            var range = CFRange(location: 0, length: 0)
            let hasRange = withUnsafeMutablePointer(to: &range) { ptr in
                AXValueGetValue(rangeValue, .cfRange, UnsafeMutableRawPointer(ptr))
            }
            if hasRange, range.length > 0 {
                var out: CFTypeRef?
                let okParam = AXUIElementCopyParameterizedAttributeValue(
                    element,
                    kAXStringForRangeParameterizedAttribute as CFString,
                    rangeValue,
                    &out
                )
                if okParam == .success, let s = out as? String, !s.isEmpty { return s }
            }
        }

        return nil
    }

    private struct PasteboardSnapshot {
        var items: [[String: Data]]

        static func capture(from pb: NSPasteboard) -> PasteboardSnapshot {
            let items: [[String: Data]] = pb.pasteboardItems?.map { item in
                var dict: [String: Data] = [:]
                for t in item.types {
                    if let data = item.data(forType: t) {
                        dict[t.rawValue] = data
                    }
                }
                return dict
            } ?? []
            return PasteboardSnapshot(items: items)
        }

        func restore(to pb: NSPasteboard) {
            pb.clearContents()
            let pbItems: [NSPasteboardItem] = items.map { dict in
                let it = NSPasteboardItem()
                for (type, data) in dict {
                    it.setData(data, forType: NSPasteboard.PasteboardType(type))
                }
                return it
            }
            _ = pb.writeObjects(pbItems)
        }
    }

    private func fetchSelectedTextViaCopyPreservingClipboard(maxWaitSeconds: CFAbsoluteTime = quickTranslateCopyWaitSeconds) -> String? {
        guard AXIsProcessTrusted() else { return nil }

        let pb = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pb)
        let before = pb.changeCount

        sendCopyShortcut()

        let deadline = CFAbsoluteTimeGetCurrent() + max(0.4, maxWaitSeconds)
        while pb.changeCount == before, CFAbsoluteTimeGetCurrent() < deadline {
            usleep(20_000)
        }

        guard pb.changeCount != before else {
            snapshot.restore(to: pb)
            return nil
        }

        var text = pb.string(forType: .string)
        if (text ?? "").isEmpty {
            let settleDeadline = CFAbsoluteTimeGetCurrent() + 0.35
            while (text ?? "").isEmpty, CFAbsoluteTimeGetCurrent() < settleDeadline {
                usleep(20_000)
                text = pb.string(forType: .string)
            }
        }
        snapshot.restore(to: pb)
        return text
    }

    private func hasSelectionViaAccessibility() -> Bool {
        guard AXIsProcessTrusted() else { return false }

        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let okFocused = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused)
        guard okFocused == .success, let focused else { return false }
        let element = focused as! AXUIElement

        var selected: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success,
           let s = selected as? String,
           !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }

        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let rangeRef {
            let rangeValue = rangeRef as! AXValue
            var range = CFRange(location: 0, length: 0)
            let hasRange = withUnsafeMutablePointer(to: &range) { ptr in
                AXValueGetValue(rangeValue, .cfRange, UnsafeMutableRawPointer(ptr))
            }
            if hasRange, range.length > 0 {
                return true
            }
        }

        return false
    }

    private func sendCopyShortcut() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    private func requestAccessibilityPromptIfNeeded() {
        if AXIsProcessTrusted() { return }
        let key = kAXTrustedCheckOptionPrompt.takeRetainedValue() as String
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func requestInputMonitoringPromptIfNeeded() {
        if CGPreflightListenEventAccess() { return }
        _ = CGRequestListenEventAccess()
    }

    func debugShowStatus() {
        show(original: "Quick Translate Status", phonetic: nil, translated: permissionStatusString(), isWord: false, senses: nil, llmUsed: false)
    }

    private func fetchMoreMeaningsIfNeeded() async {
        guard let word = currentLookupWord else { return }
        if isFetchingDetails { return }
        isFetchingDetails = true
        defer { isFetchingDetails = false }

        if let cached = store.findItem(type: .word, front: word), let senses = cached.senses, !senses.isEmpty {
            contentView.setSenses(senses)
            if let p = cached.phonetic { contentView.setPhonetic(p) }
            resizeAndReposition()
            return
        }

        contentView.setLLMUsed(nil)
        contentView.setDetailsText("Loading…")
        resizeAndReposition()

        do {
            let target = resolveTargetLanguage(for: word)
            let payload = try await llm.lookupWordDetails(word, target: target)
            if Task.isCancelled { return }

            let existing = store.findItem(type: .word, front: word)
            let bestBack = existing?.back.isEmpty == false ? existing?.back : payload.senses.first?.meaning
            let bestPhonetic = (payload.phonetic?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
                ? existing?.phonetic
                : payload.phonetic

            _ = store.upsertItem(
                type: .word,
                front: word,
                back: bestBack ?? "",
                phonetic: bestPhonetic,
                category: existing?.category ?? "lookup",
                source: existing?.source ?? "lookup",
                senses: payload.senses
            )

            contentView.setSenses(payload.senses)
            if let p = bestPhonetic { contentView.setPhonetic(p) }
            contentView.setLLMUsed(true)
            resizeAndReposition()
        } catch {
            contentView.setDetailsText("Failed to load meanings: \(error)")
            contentView.setLLMUsed(true)
            resizeAndReposition()
        }
    }

    private func setupHotKeyIfNeeded() {
        guard hotKeyRef == nil else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            quickTranslateHotKeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &hotKeyHandlerRef
        )
        if installStatus != noErr {
            NSLog("[quick_translate] InstallEventHandler failed: \(installStatus)")
            hotKeyHandlerRef = nil
            return
        }

        let hkID = EventHotKeyID(signature: quickTranslateHotKeySignature, id: quickTranslateHotKeyId)
        let modifiers = UInt32(cmdKey | optionKey)
        let keyCode = UInt32(kVK_ANSI_P)
        let registerStatus = RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if registerStatus != noErr {
            NSLog("[quick_translate] RegisterEventHotKey failed: \(registerStatus)")
            hotKeyRef = nil
        }
    }

    private func tearDownHotKey() {
        if let hk = hotKeyRef {
            UnregisterEventHotKey(hk)
        }
        hotKeyRef = nil

        if let h = hotKeyHandlerRef {
            RemoveEventHandler(h)
        }
        hotKeyHandlerRef = nil
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollSelectionTick()
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        pendingPollText = ""
    }

    private func normalizeText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        return trimmed.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private func normalizeSelectionForLookup(_ text: String) -> String {
        let normalized = normalizeText(text)
        if normalized.isEmpty { return "" }
        var trimSet = CharacterSet.whitespacesAndNewlines
        trimSet.formUnion(.punctuationCharacters)
        trimSet.formUnion(.symbols)
        let maybeWord = normalized.trimmingCharacters(in: trimSet)
        if isEnglishWord(maybeWord) {
            return maybeWord
        }
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func inferItemType(from text: String) -> VocabItemType {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.range(of: "\\s", options: .regularExpression) != nil { return .sentence }
        if t.range(of: "^[A-Za-z][A-Za-z\\-']*$", options: .regularExpression) != nil { return .word }
        return .sentence
    }

    private func isEnglishWord(_ text: String) -> Bool {
        text.range(of: "^[A-Za-z][A-Za-z\\-']*$", options: .regularExpression) != nil
    }

    @discardableResult
    private func saveLookupIfEnabled(
        itemType: VocabItemType,
        front: String,
        back: String,
        phonetic: String?,
        senses: [WordSense]? = nil,
        source: String = "lookup",
        countAsShown: Bool
    ) -> VocabItem? {
        guard AppConfig.shared.quickTranslateSaveToWordbook else { return nil }
        let item = store.upsertItem(
            type: itemType,
            front: front,
            back: back,
            phonetic: phonetic,
            category: "lookup",
            source: source,
            senses: senses
        )
        guard countAsShown else { return item }
        let countedAsNewWord = (item.type == .word && item.timesShown == 0)
        return store.recordShown(item, countedAsNewWord: countedAsNewWord)
    }

    private func isLLMReady() -> Bool {
        if !AppConfig.shared.llmEnabled { return false }
        if AppConfig.shared.llmEndpointEffective.isEmpty { return false }
        if AppConfig.shared.llmModelEffective.isEmpty { return false }
        return true
    }

    private func installOutsideDismissMonitors() {
        removeOutsideDismissMonitors()

        outsideClickLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.window === self.panel {
                return event
            }
            self.hide()
            return event
        }

        outsideClickGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            guard let self else { return }
            let p = NSEvent.mouseLocation
            if !self.panel.frame.contains(p) {
                Task { @MainActor in
                    self.hide()
                }
            }
        }
    }

    private func removeOutsideDismissMonitors() {
        if let m = outsideClickLocalMonitor {
            NSEvent.removeMonitor(m)
        }
        outsideClickLocalMonitor = nil
        if let m = outsideClickGlobalMonitor {
            NSEvent.removeMonitor(m)
        }
        outsideClickGlobalMonitor = nil
    }

    private func setupEventTapIfPossible() {
        guard eventTap == nil else { return }

        let mask = (1 << CGEventType.leftMouseUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<QuickTranslateController>.fromOpaque(refcon).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = controller.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            if type == .leftMouseUp {
                DispatchQueue.main.async {
                    controller.scheduleCheck()
                }
            }
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        eventTapSource = source
    }

    private func tearDownEventTap() {
        if let source = eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTapSource = nil
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
        }
        eventTap = nil
    }

    private func ensureMonitors(throttled: Bool) {
        let now = CFAbsoluteTimeGetCurrent()
        if throttled, now - lastEnsureAttemptAt < 3 { return }
        lastEnsureAttemptAt = now

        if eventTap == nil {
            setupEventTapIfPossible()
            if eventTap == nil {
                NSLog("[quick_translate] event tap unavailable (check Input Monitoring permission)")
            }
        }

        if mouseMonitor == nil {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
                self?.scheduleCheck()
            }
            if mouseMonitor == nil {
                NSLog("[quick_translate] global monitor unavailable (check Input Monitoring permission)")
            }
        }
    }

    private func showPermissionHintIfNeeded() {
        if didShowPermissionHint { return }
        let ax = AXIsProcessTrusted()
        let listen = CGPreflightListenEventAccess()
        if needsInputMonitoring() {
            if ax && listen { return }
        } else {
            if ax { return }
        }
        didShowPermissionHint = true
        if needsInputMonitoring() {
            show(
                original: "Quick Translate needs permissions",
                phonetic: nil,
                translated: "Accessibility: \(ax ? "OK" : "NO"), Input Monitoring: \(listen ? "OK" : "NO"). Enable them for this app in System Settings.",
                isWord: false,
                senses: nil,
                llmUsed: false
            )
        } else {
            show(
                original: "Quick Translate needs permission",
                phonetic: nil,
                translated: "Accessibility: \(ax ? "OK" : "NO"). Enable it for this app in System Settings.",
                isWord: false,
                senses: nil,
                llmUsed: false
            )
        }
    }

    private func permissionStatusString() -> String {
        let ax = AXIsProcessTrusted()
        let listen = CGPreflightListenEventAccess()
        let inApps = isInstalledInApplicationsFolder()
        let path = Bundle.main.bundlePath
        return "Accessibility: \(ax ? "OK" : "NO")\nInput Monitoring: \(listen ? "OK" : "NO")\nInstalled in /Applications: \(inApps ? "YES" : "NO")\nApp: \(path)"
    }

    private func isInstalledInApplicationsFolder() -> Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
    }

    private func needsInputMonitoring() -> Bool {
        AppConfig.shared.quickTranslateTrigger.lowercased() == "auto"
    }

    private func containsCJK(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x4E00...0x9FFF: return true // CJK Unified Ideographs
            case 0x3400...0x4DBF: return true // CJK Unified Ideographs Extension A
            default: continue
            }
        }
        return false
    }
}

final class QuickTranslateView: NSView {
    private let card = NSView()
    private let originalLabel = NSTextField(string: "")
    private let phoneticLabel = NSTextField(string: "")
    private let translatedLabel = NSTextField(string: "")
    private let detailsLabel = NSTextField(string: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private let llmStatusLabel = NSTextField(labelWithString: "")
    private let readButton = NSButton(title: "Read", target: nil, action: nil)
    private let moreButton = NSButton(title: "More", target: nil, action: nil)

    var onDetailsToggled: (() -> Void)?
    var onRequestMoreMeanings: (() -> Void)?
    var onSpeakRequested: (() -> Void)?

    private var isWord: Bool = false
    private var llmUsed: Bool?
    private var senses: [WordSense] = []
    private var detailsVisible: Bool = false
    private var lastKey: String = ""

    override var mouseDownCanMoveWindow: Bool { true }

    private func applyCardColors() {
        // Note: converting dynamic system colors to CGColor freezes them; refresh on appearance changes.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            card.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
            card.layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.borderWidth = 1
        applyCardColors()

        configureSelectableTextField(originalLabel)
        originalLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        originalLabel.textColor = .labelColor
        originalLabel.maximumNumberOfLines = 4
        originalLabel.lineBreakMode = .byWordWrapping

        configureSelectableTextField(phoneticLabel)
        phoneticLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        phoneticLabel.textColor = .secondaryLabelColor
        phoneticLabel.maximumNumberOfLines = 1
        phoneticLabel.isHidden = true

        configureSelectableTextField(translatedLabel)
        translatedLabel.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        translatedLabel.textColor = .labelColor
        translatedLabel.maximumNumberOfLines = 0
        translatedLabel.lineBreakMode = .byCharWrapping

        configureSelectableTextField(detailsLabel)
        detailsLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        detailsLabel.textColor = .labelColor
        detailsLabel.maximumNumberOfLines = 12
        detailsLabel.lineBreakMode = .byWordWrapping
        detailsLabel.isHidden = true

        hintLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.maximumNumberOfLines = 1
        hintLabel.stringValue = "Drag to move · click outside to close"

        llmStatusLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        llmStatusLabel.maximumNumberOfLines = 1
        setLLMUsed(false)

        readButton.bezelStyle = .inline
        readButton.controlSize = .small
        readButton.target = self
        readButton.action = #selector(onReadClicked)
        readButton.isHidden = false

        moreButton.bezelStyle = .inline
        moreButton.controlSize = .small
        moreButton.target = self
        moreButton.action = #selector(onMoreClicked)
        moreButton.isHidden = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let bottomRow = NSStackView(views: [hintLabel, spacer, llmStatusLabel, readButton, moreButton])
        bottomRow.orientation = .horizontal
        bottomRow.alignment = .centerY
        bottomRow.distribution = .fill
        bottomRow.spacing = 10

        let stack = NSStackView(views: [originalLabel, phoneticLabel, translatedLabel, detailsLabel, bottomRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(stack)
        addSubview(card)

        card.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyCardColors()
    }

    func render(original: String, phonetic: String?, translated: String, isWord: Bool, senses: [WordSense]?, llmUsed: Bool?) {
        originalLabel.stringValue = original
        setPhonetic(phonetic)
        translatedLabel.stringValue = formattedTranslatedText(translated, isWord: isWord)
        self.isWord = isWord
        self.senses = senses ?? []
        setLLMUsed(llmUsed)

        let key = original
        if key != lastKey {
            detailsVisible = false
            detailsLabel.isHidden = true
        }
        lastKey = key

        updateMoreButtonVisibility()
        if detailsVisible {
            updateDetailsText()
        }
    }

    func setPhonetic(_ phonetic: String?) {
        let p = (phonetic ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty {
            phoneticLabel.stringValue = ""
            phoneticLabel.isHidden = true
        } else {
            phoneticLabel.stringValue = p
            phoneticLabel.isHidden = false
        }
    }

    func setSenses(_ senses: [WordSense]) {
        self.senses = senses
        updateMoreButtonVisibility()
        if detailsVisible {
            updateDetailsText()
        }
    }

    func setDetailsText(_ text: String) {
        detailsLabel.stringValue = text
    }

    func setLLMUsed(_ used: Bool?) {
        llmUsed = used
        switch used {
        case .some(true):
            llmStatusLabel.stringValue = "LLM: YES"
            llmStatusLabel.textColor = .systemGreen
        case .some(false):
            llmStatusLabel.stringValue = "LLM: NO"
            llmStatusLabel.textColor = .secondaryLabelColor
        case .none:
            llmStatusLabel.stringValue = "LLM: …"
            llmStatusLabel.textColor = .tertiaryLabelColor
        }
    }

    private func configureSelectableTextField(_ field: NSTextField) {
        field.isEditable = false
        field.isSelectable = true
        field.isBordered = false
        field.drawsBackground = false
        field.usesSingleLineMode = false
        field.focusRingType = .none
        field.lineBreakMode = .byWordWrapping
        if let cell = field.cell as? NSTextFieldCell {
            cell.wraps = true
            cell.isScrollable = false
            cell.usesSingleLineMode = false
            cell.lineBreakMode = field.lineBreakMode
        }
    }

    private func formattedTranslatedText(_ text: String, isWord: Bool) -> String {
        var out = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.isEmpty { return out }
        if isWord { return out }

        out = out.replacingOccurrences(of: "[ \\t]*\\n[ \\t]*", with: "\n", options: .regularExpression)

        // For long single-paragraph translations, split by punctuation first.
        if !out.contains("\n"), out.count >= 90 {
            out = out.replacingOccurrences(of: "([。！？；])", with: "$1\n", options: .regularExpression)
            out = out.replacingOccurrences(of: "([.!?;])\\s+", with: "$1\n", options: .regularExpression)
        }

        // Still one long line: hard-wrap by character count for readability.
        if !out.contains("\n"), out.count >= 140 {
            out = wrapLongLine(out, limit: containsCJK(out) ? 26 : 68)
        }

        out = out.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return out
    }

    private func wrapLongLine(_ text: String, limit: Int) -> String {
        guard limit >= 8 else { return text }
        var result = ""
        var count = 0
        for ch in text {
            result.append(ch)
            if ch == "\n" {
                count = 0
                continue
            }
            count += 1
            if count >= limit {
                if ch != " " {
                    result.append("\n")
                }
                count = 0
            }
        }
        return result
    }

    private func containsCJK(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x4E00...0x9FFF: return true
            case 0x3400...0x4DBF: return true
            default: continue
            }
        }
        return false
    }

    private func updateMoreButtonVisibility() {
        moreButton.isHidden = !isWord
        moreButton.title = detailsVisible ? "Less" : "More"
    }

    private func updateDetailsText() {
        if senses.isEmpty {
            detailsLabel.stringValue = "Loading…"
            return
        }
        var lines: [String] = []
        for (idx, s) in senses.enumerated() {
            let rank = max(1, min(5, s.freq))
            lines.append("\(idx + 1). \(s.pos) (\(rank)) \(s.meaning)")
        }
        detailsLabel.stringValue = lines.joined(separator: "\n")
    }

    @objc private func onMoreClicked() {
        guard isWord else { return }
        detailsVisible.toggle()
        detailsLabel.isHidden = !detailsVisible
        updateMoreButtonVisibility()
        if detailsVisible {
            updateDetailsText()
            if senses.isEmpty {
                onRequestMoreMeanings?()
            }
        }
        onDetailsToggled?()
    }

    @objc private func onReadClicked() {
        onSpeakRequested?()
    }

    func preferredSize(maxWidth: CGFloat) -> NSSize {
        let minWidth: CGFloat = 220
        let paddingH: CGFloat = 14 * 2
        let paddingV: CGFloat = 12 * 2
        let interSpacing: CGFloat = 8

        let original = originalLabel.stringValue
        let phonetic = phoneticLabel.isHidden ? "" : phoneticLabel.stringValue
        let translated = translatedLabel.stringValue
        let details = (detailsVisible && !detailsLabel.isHidden) ? detailsLabel.stringValue : ""
        let hint = hintLabel.stringValue
        let llmStatus = llmStatusLabel.stringValue
        let read = readButton.title
        let more = moreButton.isHidden ? "" : moreButton.title

        let originalFont = originalLabel.font ?? NSFont.systemFont(ofSize: 14, weight: .semibold)
        let phoneticFont = phoneticLabel.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let translatedFont = translatedLabel.font ?? NSFont.systemFont(ofSize: 14, weight: .regular)
        let detailsFont = detailsLabel.font ?? NSFont.systemFont(ofSize: 13, weight: .regular)
        let hintFont = hintLabel.font ?? NSFont.systemFont(ofSize: 11, weight: .regular)

        func maxLineWidth(_ text: String, font: NSFont) -> CGFloat {
            if text.isEmpty { return 0 }
            let lines = text.split(separator: "\n").map(String.init)
            return lines.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        }

        let originalSingle = (original as NSString).size(withAttributes: [.font: originalFont]).width
        let phoneticSingle = (phonetic as NSString).size(withAttributes: [.font: phoneticFont]).width
        let translatedSingle = (translated as NSString).size(withAttributes: [.font: translatedFont]).width
        let detailsSingle = maxLineWidth(details, font: detailsFont)
        let hintSingle = (hint as NSString).size(withAttributes: [.font: hintFont]).width
        let llmSingle = (llmStatus as NSString).size(withAttributes: [.font: hintFont]).width
        let readSingle = (read as NSString).size(withAttributes: [.font: hintFont]).width
        let moreSingle = (more as NSString).size(withAttributes: [.font: hintFont]).width
        // bottomRow: hint + spacer + llm + read + (optional) more
        let bottomRowSingle = hintSingle + 20 + llmSingle + 10 + readSingle + (moreButton.isHidden ? 0 : (10 + moreSingle))

        let targetWidth = min(maxWidth, max(minWidth, max(originalSingle, phoneticSingle, translatedSingle, detailsSingle, bottomRowSingle) + paddingH))
        let contentWidth = max(80, targetWidth - paddingH)

        func height(_ text: String, font: NSFont) -> CGFloat {
            if text.isEmpty { return 0 }
            let rect = (text as NSString).boundingRect(
                with: NSSize(width: contentWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font],
                context: nil
            )
            return ceil(rect.height)
        }

        let h1 = height(original, font: originalFont)
        let hPh = phonetic.isEmpty ? 0 : height(phonetic, font: phoneticFont)
        let h2 = height(translated, font: translatedFont)
        let hDetails = details.isEmpty ? 0 : height(details, font: detailsFont)
        let hBottom = height(hint, font: hintFont)

        var visibleBlocks = 1 // original
        if !phonetic.isEmpty { visibleBlocks += 1 }
        visibleBlocks += 1 // translated
        if !details.isEmpty { visibleBlocks += 1 }
        visibleBlocks += 1 // bottom row

        let totalSpacing = interSpacing * CGFloat(max(0, visibleBlocks - 1))
        let totalH = paddingV + h1 + hPh + h2 + hDetails + hBottom + totalSpacing

        return NSSize(width: ceil(targetWidth), height: min(560, max(88, totalH)))
    }

}
