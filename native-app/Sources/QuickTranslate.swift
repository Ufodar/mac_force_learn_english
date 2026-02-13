import ApplicationServices
import AVFoundation
import Carbon.HIToolbox
import Cocoa

private let quickTranslateHotKeySignature: OSType = OSType(0x4D464C45) // "MFLE"
private let quickTranslateTranslateHotKeyId: UInt32 = 1
private let quickTranslateAskHotKeyId: UInt32 = 2
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
    if hkID.signature != quickTranslateHotKeySignature { return noErr }

    let controller = Unmanaged<QuickTranslateController>.fromOpaque(userData).takeUnretainedValue()
    Task { @MainActor in
        switch hkID.id {
        case quickTranslateTranslateHotKeyId:
            controller.translateSelectionNow()
        case quickTranslateAskHotKeyId:
            controller.askSelectionNow()
        default:
            break
        }
    }
    return noErr
}

@MainActor
private final class QuickTranslatePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class QuickAskPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class QuickTranslateController {
    private enum SpeechPreference {
        case auto
        case original
        case translated
    }

    private var mouseMonitor: Any?
    private var debounceWorkItem: DispatchWorkItem?
    private var currentTask: Task<Void, Never>?
    private var pollTimer: Timer?
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var lastEnsureAttemptAt: CFAbsoluteTime = 0
    private var didShowPermissionHint: Bool = false
    private var translateHotKeyRef: EventHotKeyRef?
    private var askHotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?
    private var lastTranslateHotKeyAt: CFAbsoluteTime = 0
    private var lastAskHotKeyAt: CFAbsoluteTime = 0
    private var isFetchingDetails: Bool = false
    private var outsideClickGlobalMonitor: Any?
    private var outsideClickLocalMonitor: Any?
    private var askOutsideClickGlobalMonitor: Any?
    private var askOutsideClickLocalMonitor: Any?
    private var askKeyLocalMonitor: Any?

    private var lastText: String = ""
    private var pendingPollText: String = ""
    private var lastAnchorPoint: NSPoint = .zero
    private var pendingAskSelection: String = ""
    private var askAnchorPoint: NSPoint = .zero
    private var askPreviousApp: NSRunningApplication?
    private var currentLookupWord: String?
    private var currentOriginalForSpeech: String = ""
    private var currentTranslatedForSpeech: String = ""
    private var currentSpeechPreference: SpeechPreference = .auto

    private let store: VocabStore
    private let llm: LLMClient
    private let offline: OfflineVocabProvider
    private let speechSynth = AVSpeechSynthesizer()
    private let panel: QuickTranslatePanel
    private let contentView: QuickTranslateView
    private let askPanel: QuickAskPanel
    private let askView: QuickAskView

    init(store: VocabStore, llm: LLMClient = LLMClient(), offline: OfflineVocabProvider = OfflineVocabProvider()) {
        self.store = store
        self.llm = llm
        self.offline = offline

        let bubbleView = QuickTranslateView(frame: NSRect(x: 0, y: 0, width: 360, height: 120))
        self.contentView = bubbleView

        let bubblePanel = QuickTranslatePanel(
            contentRect: bubbleView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        bubblePanel.isOpaque = false
        bubblePanel.backgroundColor = .clear
        bubblePanel.hasShadow = true
        bubblePanel.hidesOnDeactivate = false
        bubblePanel.level = .statusBar
        bubblePanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        bubblePanel.ignoresMouseEvents = false
        bubblePanel.isMovable = true
        bubblePanel.isMovableByWindowBackground = true
        bubblePanel.contentView = bubbleView
        bubblePanel.orderOut(nil)

        self.panel = bubblePanel

        let askView = QuickAskView(frame: NSRect(x: 0, y: 0, width: 420, height: 148))
        self.askView = askView

        let askPanel = QuickAskPanel(
            contentRect: askView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        askPanel.isOpaque = false
        askPanel.backgroundColor = .clear
        askPanel.hasShadow = true
        askPanel.hidesOnDeactivate = false
        askPanel.level = .statusBar
        askPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        askPanel.ignoresMouseEvents = false
        askPanel.isMovable = true
        askPanel.isMovableByWindowBackground = true
        askPanel.contentView = askView
        askPanel.orderOut(nil)
        self.askPanel = askPanel

        bubbleView.onDetailsToggled = { [weak self] in
            self?.resizeAndReposition()
        }
        bubbleView.onRequestMoreMeanings = { [weak self] in
            Task { @MainActor in
                await self?.fetchMoreMeaningsIfNeeded()
            }
        }
        bubbleView.onSpeakRequested = { [weak self] in
            self?.speakCurrent()
        }

        askView.onCancel = { [weak self] in
            self?.hideAskPanel(restoreFocus: true)
        }
        askView.onSubmit = { [weak self] prompt in
            self?.submitAsk(prompt: prompt)
        }
        askView.onReadDirect = { [weak self] in
            self?.readSelectionDirectFromAskPanel()
        }
        askView.onReadSmart = { [weak self] in
            self?.readSelectionSmartFromAskPanel()
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
        setupHotKeyIfNeeded()

        if AppConfig.shared.quickTranslateTrigger.lowercased() == "auto" {
            requestInputMonitoringPromptIfNeeded()
            ensureMonitors(throttled: false)
            startPolling()
        } else {
            show(
                original: "Quick Translate",
                phonetic: nil,
                translated: "Select text then press ⌘⌥P (translate) or ⌘⌥0 (ask/read)",
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
        hideAskPanel(restoreFocus: false)
        hide()
    }

    func translateSelectionNow() {
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastTranslateHotKeyAt < 0.25 { return }
        lastTranslateHotKeyAt = now

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

    func askSelectionNow() {
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastAskHotKeyAt < 0.25 { return }
        lastAskHotKeyAt = now

        guard AppConfig.shared.quickTranslateEnabled else { return }
        guard shouldHandleNow() else { return }

        guard let raw = fetchSelectedTextForAsk() else {
            if speechSynth.isSpeaking {
                _ = speechSynth.stopSpeaking(at: .immediate)
                show(
                    original: "Speech",
                    phonetic: nil,
                    translated: "Stopped.",
                    isWord: false,
                    senses: nil,
                    llmUsed: false,
                    speechPreference: .translated
                )
                return
            }
            let selectionExists = hasSelectionViaAccessibility()
            show(
                original: selectionExists ? "Selection unavailable" : "No selection",
                phonetic: nil,
                translated: selectionExists
                    ? "Selected text could not be captured. Try a shorter snippet, then press ⌘⌥0 again."
                    : "Select text first, then press ⌘⌥0",
                isWord: false,
                senses: nil,
                llmUsed: false
            )
            return
        }

        let text = raw
        if text.isEmpty {
            if speechSynth.isSpeaking {
                _ = speechSynth.stopSpeaking(at: .immediate)
                show(
                    original: "Speech",
                    phonetic: nil,
                    translated: "Stopped.",
                    isWord: false,
                    senses: nil,
                    llmUsed: false,
                    speechPreference: .translated
                )
                return
            }
            show(
                original: "No selection",
                phonetic: nil,
                translated: "Select text first, then press ⌘⌥0",
                isWord: false,
                senses: nil,
                llmUsed: false
            )
            return
        }

        let hardLimit = 80_000
        let captured = text.count > hardLimit ? String(text.prefix(hardLimit)) : text

        askPreviousApp = NSWorkspace.shared.frontmostApplication
        pendingAskSelection = captured
        askAnchorPoint = NSEvent.mouseLocation
        showAskPanel()
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

    private func show(
        original: String,
        phonetic: String?,
        translated: String,
        isWord: Bool,
        senses: [WordSense]?,
        llmUsed: Bool?,
        anchor: NSPoint? = nil,
        speechPreference: SpeechPreference = .auto
    ) {
        currentLookupWord = (isWord && isEnglishWord(original)) ? original : nil
        currentOriginalForSpeech = original
        currentTranslatedForSpeech = translated
        currentSpeechPreference = speechPreference
        contentView.render(original: original, phonetic: phonetic, translated: translated, isWord: isWord, senses: senses, llmUsed: llmUsed)

        lastAnchorPoint = anchor ?? NSEvent.mouseLocation
        resizeAndReposition()
        panel.orderFrontRegardless()
        installOutsideDismissMonitors()
    }

    private func resizeAndReposition() {
        let anchor = lastAnchorPoint
        let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main
        let screenFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let margin: CGFloat = 10

        let availableWidth = max(1, screenFrame.width - margin * 2)
        let availableHeight = max(1, screenFrame.height - margin * 2)
        let maxWidth = min(520, availableWidth)
        var size = contentView.preferredSize(maxWidth: maxWidth)
        size.width = min(size.width, availableWidth)
        size.height = min(size.height, availableHeight)
        panel.setContentSize(size)

        var x = anchor.x + 14
        var y = anchor.y - size.height - 14

        if x + size.width > screenFrame.maxX - margin {
            x = screenFrame.maxX - size.width - margin
        }
        if x < screenFrame.minX + margin {
            x = screenFrame.minX + margin
        }
        if y < screenFrame.minY + margin {
            y = anchor.y + 14
        }
        if y + size.height > screenFrame.maxY - margin {
            y = screenFrame.maxY - size.height - margin
        }
        if y < screenFrame.minY + margin {
            y = screenFrame.minY + margin
        }

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func hide() {
        removeOutsideDismissMonitors()
        _ = speechSynth.stopSpeaking(at: .immediate)
        panel.orderOut(nil)
    }

    private func showAskPanel() {
        let selection = pendingAskSelection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selection.isEmpty else { return }

        askView.reset(selection: selection)
        resizeAndRepositionAskPanel()
        askPanel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        askView.focusPrompt()
        installAskDismissMonitors()
    }

    private func resizeAndRepositionAskPanel() {
        let anchor = askAnchorPoint == .zero ? NSEvent.mouseLocation : askAnchorPoint
        let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main
        let screenFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let margin: CGFloat = 10

        let availableWidth = max(1, screenFrame.width - margin * 2)
        let availableHeight = max(1, screenFrame.height - margin * 2)
        let maxWidth = min(560, availableWidth)
        var size = askView.preferredSize(maxWidth: maxWidth)
        size.width = min(size.width, availableWidth)
        size.height = min(size.height, availableHeight)
        askPanel.setContentSize(size)

        var x = anchor.x + 14
        var y = anchor.y - size.height - 14

        if x + size.width > screenFrame.maxX - margin {
            x = screenFrame.maxX - size.width - margin
        }
        if x < screenFrame.minX + margin {
            x = screenFrame.minX + margin
        }
        if y < screenFrame.minY + margin {
            y = anchor.y + 14
        }
        if y + size.height > screenFrame.maxY - margin {
            y = screenFrame.maxY - size.height - margin
        }
        if y < screenFrame.minY + margin {
            y = screenFrame.minY + margin
        }

        askPanel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func submitAsk(prompt: String) {
        let question = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if question.isEmpty {
            NSSound.beep()
            askView.focusPrompt()
            return
        }

        let selection = pendingAskSelection.trimmingCharacters(in: .whitespacesAndNewlines)
        if selection.isEmpty {
            hideAskPanel(restoreFocus: true)
            return
        }

        guard isLLMReady() else {
            show(
                original: "LLM not configured",
                phonetic: nil,
                translated: "Open Settings… and set endpoint/model/apiKey first.",
                isWord: false,
                senses: nil,
                llmUsed: false,
                anchor: askAnchorPoint,
                speechPreference: .translated
            )
            return
        }

        let anchor = askAnchorPoint == .zero ? NSEvent.mouseLocation : askAnchorPoint
        let prev = askPreviousApp
        hideAskPanel(restoreFocus: false)

        show(
            original: selection,
            phonetic: nil,
            translated: "Asking…",
            isWord: false,
            senses: nil,
            llmUsed: nil,
            anchor: anchor,
            speechPreference: .translated
        )
        prev?.activate(options: [])

        currentTask?.cancel()
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let answer = try await self.llm.ask(selection: selection, question: question)
                if Task.isCancelled { return }
                await MainActor.run {
                    self.show(
                        original: selection,
                        phonetic: nil,
                        translated: answer,
                        isWord: false,
                        senses: nil,
                        llmUsed: true,
                        anchor: anchor,
                        speechPreference: .translated
                    )
                    self.speakText(answer)
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    self.show(
                        original: selection,
                        phonetic: nil,
                        translated: "Failed: \(error)",
                        isWord: false,
                        senses: nil,
                        llmUsed: true,
                        anchor: anchor,
                        speechPreference: .translated
                    )
                }
            }
        }
    }

    private func readSelectionDirectFromAskPanel() {
        let selection = pendingAskSelection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selection.isEmpty else {
            NSSound.beep()
            return
        }

        let anchor = askAnchorPoint == .zero ? NSEvent.mouseLocation : askAnchorPoint
        let prev = askPreviousApp
        hideAskPanel(restoreFocus: false)
        prev?.activate(options: [])

        show(
            original: selection,
            phonetic: nil,
            translated: "Reading…",
            isWord: false,
            senses: nil,
            llmUsed: false,
            anchor: anchor,
            speechPreference: .original
        )
        speakText(selection)
    }

    private func readSelectionSmartFromAskPanel() {
        let selection = pendingAskSelection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selection.isEmpty else {
            NSSound.beep()
            return
        }

        guard isLLMReady() else {
            show(
                original: "Smart Read unavailable",
                phonetic: nil,
                translated: "LLM is not configured. Open Settings… and set endpoint/model/apiKey first.",
                isWord: false,
                senses: nil,
                llmUsed: false,
                anchor: askAnchorPoint,
                speechPreference: .translated
            )
            return
        }

        let anchor = askAnchorPoint == .zero ? NSEvent.mouseLocation : askAnchorPoint
        let prev = askPreviousApp
        hideAskPanel(restoreFocus: false)
        prev?.activate(options: [])

        show(
            original: selection,
            phonetic: nil,
            translated: "Smart reading…",
            isWord: false,
            senses: nil,
            llmUsed: nil,
            anchor: anchor,
            speechPreference: .translated
        )

        currentTask?.cancel()
        currentTask = Task { [weak self] in
            guard let self else { return }
            let mode: LLMClient.SmartReadMode = self.seemsLikeCode(selection) ? .codeExplain : .cleanSummary
            let llmSendLimit = max(8_000, AppConfig.shared.quickTranslateMaxSelectionChars)
            let (excerpt, didTruncate) = self.makeLLMExcerpt(selection, maxChars: llmSendLimit)
            do {
                let result = try await self.llm.smartRead(selection: excerpt, mode: mode, didTruncate: didTruncate)
                if Task.isCancelled { return }
                await MainActor.run {
                    self.show(
                        original: selection,
                        phonetic: nil,
                        translated: result,
                        isWord: false,
                        senses: nil,
                        llmUsed: true,
                        anchor: anchor,
                        speechPreference: .translated
                    )
                    self.speakText(result)
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    self.show(
                        original: selection,
                        phonetic: nil,
                        translated: "Failed: \(error)",
                        isWord: false,
                        senses: nil,
                        llmUsed: true,
                        anchor: anchor,
                        speechPreference: .translated
                    )
                }
            }
        }
    }

    private func hideAskPanel(restoreFocus: Bool) {
        removeAskDismissMonitors()
        askPanel.orderOut(nil)

        pendingAskSelection = ""
        askAnchorPoint = .zero
        let prev = askPreviousApp
        askPreviousApp = nil
        if restoreFocus, let prev {
            prev.activate(options: [])
        }
    }

    private func installAskDismissMonitors() {
        removeAskDismissMonitors()

        askOutsideClickLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.window === self.askPanel { return event }
            self.hideAskPanel(restoreFocus: true)
            return event
        }

        askOutsideClickGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            guard let self else { return }
            let p = NSEvent.mouseLocation
            if !self.askPanel.frame.contains(p) {
                Task { @MainActor in
                    self.hideAskPanel(restoreFocus: true)
                }
            }
        }

        askKeyLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.window !== self.askPanel { return event }

            if event.keyCode == 53 { // esc
                _ = self.speechSynth.stopSpeaking(at: .immediate)
                self.hideAskPanel(restoreFocus: true)
                return nil
            }
            if let chars = event.charactersIgnoringModifiers?.lowercased() {
                if chars == "1" {
                    self.readSelectionDirectFromAskPanel()
                    return nil
                }
                if chars == "2" {
                    self.readSelectionSmartFromAskPanel()
                    return nil
                }
                if (chars == "r" || chars == "s"), self.askView.isPromptEmpty() {
                    if chars == "r" {
                        self.readSelectionDirectFromAskPanel()
                    } else {
                        self.readSelectionSmartFromAskPanel()
                    }
                    return nil
                }
            }
            return event
        }
    }

    private func removeAskDismissMonitors() {
        if let m = askOutsideClickLocalMonitor {
            NSEvent.removeMonitor(m)
        }
        askOutsideClickLocalMonitor = nil
        if let m = askOutsideClickGlobalMonitor {
            NSEvent.removeMonitor(m)
        }
        askOutsideClickGlobalMonitor = nil
        if let m = askKeyLocalMonitor {
            NSEvent.removeMonitor(m)
        }
        askKeyLocalMonitor = nil
    }

    private func speakCurrent() {
        let original = currentOriginalForSpeech.trimmingCharacters(in: .whitespacesAndNewlines)
        let translated = currentTranslatedForSpeech.trimmingCharacters(in: .whitespacesAndNewlines)
        if original.isEmpty, translated.isEmpty { return }

        let textToRead: String
        switch currentSpeechPreference {
        case .translated:
            textToRead = translated.isEmpty ? original : translated
        case .original:
            textToRead = original.isEmpty ? translated : original
        case .auto:
            if seemsLikeCode(original), !translated.isEmpty {
                textToRead = translated
            } else if containsCJK(original), !translated.isEmpty, !containsCJK(translated) {
                textToRead = translated
            } else {
                textToRead = original.isEmpty ? translated : original
            }
        }

        speakText(textToRead)
    }

    private func speakText(_ raw: String) {
        let text = normalizeSpeechText(raw)
        if text.isEmpty { return }

        if speechSynth.isSpeaking {
            _ = speechSynth.stopSpeaking(at: .immediate)
        }

        let chunks = splitForSpeech(text)
        for chunk in chunks {
            let utterance = AVSpeechUtterance(string: chunk)
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            if let voice = bestVoice(for: chunk) {
                utterance.voice = voice
            }
            speechSynth.speak(utterance)
        }
    }

    private func normalizeSpeechText(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return "" }

        // Remove common markdown fences to reduce noisy speech.
        s = s.replacingOccurrences(of: "```", with: "")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func splitForSpeech(_ text: String) -> [String] {
        let maxChunk = 900
        let normalized = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        let paragraphs = normalized.components(separatedBy: "\n\n")

        var rough: [String] = []
        var buffer = ""

        func flush() {
            let t = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { rough.append(t) }
            buffer = ""
        }

        for p in paragraphs {
            let para = p.trimmingCharacters(in: .whitespacesAndNewlines)
            if para.isEmpty { continue }
            if buffer.isEmpty {
                buffer = para
            } else if buffer.count + 2 + para.count <= maxChunk {
                buffer += "\n\n" + para
            } else {
                flush()
                buffer = para
            }
        }
        flush()

        var final: [String] = []
        for c in rough {
            if c.count <= maxChunk {
                final.append(c)
                continue
            }

            var current = ""
            for ch in c {
                current.append(ch)
                if current.count >= maxChunk || "。！？.!?".contains(ch) {
                    let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { final.append(t) }
                    current = ""
                }
            }
            let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { final.append(t) }
        }

        return final.isEmpty ? rough : final
    }

    private func seemsLikeCode(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return false }
        if t.contains("```") { return true }

        let lower = t.lowercased()
        let codeHints = ["func ", "class ", "struct ", "enum ", "let ", "var ", "import ", "public ", "private ", "return ", "if ", "else ", "for ", "while "]
        if codeHints.contains(where: { lower.contains($0) }) { return true }

        let symbols = "{}();[]=<>"
        let symbolCount = t.filter { symbols.contains($0) }.count
        let letterCount = t.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        if symbolCount >= 80 && Double(symbolCount) / Double(max(1, letterCount)) > 0.22 { return true }

        // Many short lines that look like code.
        let lines = t.split(separator: "\n")
        if lines.count >= 8 {
            let codeLineCount = lines.filter { line in
                let s = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if s.isEmpty { return false }
                if s.hasPrefix("//") || s.hasPrefix("#") { return true }
                if s.contains("{") || s.contains("}") || s.hasSuffix(";") { return true }
                if s.contains("->") || s.contains("=>") { return true }
                return false
            }.count
            if Double(codeLineCount) / Double(lines.count) >= 0.45 { return true }
        }

        return false
    }

    private func makeLLMExcerpt(_ text: String, maxChars: Int) -> (String, Bool) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count <= maxChars { return (t, false) }
        let headCount = max(400, maxChars / 2)
        let tailCount = max(400, maxChars - headCount)
        let head = String(t.prefix(headCount))
        let tail = String(t.suffix(tailCount))
        return (head + "\n\n...[TRUNCATED]...\n\n" + tail, true)
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

    private func fetchSelectedTextForAsk() -> String? {
        if let s = fetchSelectedTextViaAccessibility() {
            let t = normalizeTextPreservingNewlines(s)
            return t.isEmpty ? nil : t
        }
        if let s = fetchSelectedTextViaCopyPreservingClipboard(maxWaitSeconds: quickTranslateCopyWaitSeconds) {
            let t = normalizeTextPreservingNewlines(s)
            return t.isEmpty ? nil : t
        }
        if let s = fetchSelectedTextViaCopyPreservingClipboard(maxWaitSeconds: quickTranslateCopyWaitSeconds + 1.6) {
            let t = normalizeTextPreservingNewlines(s)
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
        guard translateHotKeyRef == nil || askHotKeyRef == nil else { return }

        if hotKeyHandlerRef == nil {
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
        }

        let modifiers = UInt32(cmdKey | optionKey)
        if translateHotKeyRef == nil {
            let hkID = EventHotKeyID(signature: quickTranslateHotKeySignature, id: quickTranslateTranslateHotKeyId)
            let keyCode = UInt32(kVK_ANSI_P)
            let registerStatus = RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &translateHotKeyRef)
            if registerStatus != noErr {
                NSLog("[quick_translate] RegisterEventHotKey (translate) failed: \(registerStatus)")
                translateHotKeyRef = nil
            }
        }
        if askHotKeyRef == nil {
            let hkID = EventHotKeyID(signature: quickTranslateHotKeySignature, id: quickTranslateAskHotKeyId)
            let keyCode = UInt32(kVK_ANSI_0)
            let registerStatus = RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &askHotKeyRef)
            if registerStatus != noErr {
                NSLog("[quick_translate] RegisterEventHotKey (ask) failed: \(registerStatus)")
                askHotKeyRef = nil
            }
        }
    }

    private func tearDownHotKey() {
        if let hk = translateHotKeyRef {
            UnregisterEventHotKey(hk)
        }
        translateHotKeyRef = nil
        if let hk = askHotKeyRef {
            UnregisterEventHotKey(hk)
        }
        askHotKeyRef = nil

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

    private func normalizeTextPreservingNewlines(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return "" }
        s = s.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return s
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

@MainActor
final class QuickAskView: NSView {
    private let card = NSView()
    private let titleLabel = NSTextField(labelWithString: "Ask")
    private let readButton = NSButton(title: "Read", target: nil, action: nil)
    private let smartReadButton = NSButton(title: "Smart Read", target: nil, action: nil)
    private let selectionLabel = NSTextField(labelWithString: "")
    private let promptField = NSTextField(string: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let sendButton = NSButton(title: "Send", target: nil, action: nil)

    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onReadDirect: (() -> Void)?
    var onReadSmart: (() -> Void)?

    private func applyCardColors() {
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

        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.maximumNumberOfLines = 1

        readButton.bezelStyle = .inline
        readButton.controlSize = .small
        readButton.target = self
        readButton.action = #selector(onReadClicked)

        smartReadButton.bezelStyle = .inline
        smartReadButton.controlSize = .small
        smartReadButton.target = self
        smartReadButton.action = #selector(onSmartReadClicked)

        selectionLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        selectionLabel.textColor = .secondaryLabelColor
        selectionLabel.lineBreakMode = .byWordWrapping
        selectionLabel.maximumNumberOfLines = 3

        promptField.placeholderString = "Ask about the selection…"
        promptField.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        promptField.target = self
        promptField.action = #selector(onSendTriggered)

        hintLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.maximumNumberOfLines = 1
        hintLabel.stringValue = "1/R: Read · 2/S: Smart Read · Enter: Ask · Esc: close"

        cancelButton.bezelStyle = .inline
        cancelButton.controlSize = .small
        cancelButton.target = self
        cancelButton.action = #selector(onCancelClicked)

        sendButton.bezelStyle = .inline
        sendButton.controlSize = .small
        sendButton.target = self
        sendButton.action = #selector(onSendTriggered)

        let topSpacer = NSView()
        topSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        topSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let topRow = NSStackView(views: [titleLabel, topSpacer, readButton, smartReadButton])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.distribution = .fill
        topRow.spacing = 10

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let bottomRow = NSStackView(views: [hintLabel, spacer, cancelButton, sendButton])
        bottomRow.orientation = .horizontal
        bottomRow.alignment = .centerY
        bottomRow.distribution = .fill
        bottomRow.spacing = 10

        let stack = NSStackView(views: [topRow, selectionLabel, promptField, bottomRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 10
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

    func reset(selection: String) {
        titleLabel.stringValue = "Ask (⌘⌥0)"
        selectionLabel.stringValue = formatSelectionPreview(selection)
        promptField.stringValue = ""
        promptField.placeholderString = "Type your question…"
    }

    func focusPrompt() {
        window?.makeFirstResponder(promptField)
    }

    func isPromptEmpty() -> Bool {
        promptField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func preferredSize(maxWidth: CGFloat) -> NSSize {
        let targetWidth = max(1, min(maxWidth, 560))
        return NSSize(width: ceil(targetWidth), height: 156)
    }

    private func formatSelectionPreview(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > 240 {
            s = String(s.prefix(240)) + "…"
        }
        return "Selected: \(s)"
    }

    @objc private func onCancelClicked() {
        onCancel?()
    }

    @objc private func onSendTriggered() {
        onSubmit?(promptField.stringValue)
    }

    @objc private func onReadClicked() {
        onReadDirect?()
    }

    @objc private func onSmartReadClicked() {
        onReadSmart?()
    }
}

final class QuickTranslateView: NSView {
    private let card = NSView()
    private let originalLabel = NSTextField(string: "")
    private let phoneticLabel = NSTextField(string: "")
    private let translatedScroll = NSScrollView()
    private let translatedTextView = NSTextView()
    private var translatedHeightConstraint: NSLayoutConstraint?
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

        translatedTextView.isEditable = false
        translatedTextView.isSelectable = true
        translatedTextView.isRichText = false
        translatedTextView.drawsBackground = false
        translatedTextView.textContainerInset = NSSize(width: 0, height: 2)
        translatedTextView.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        translatedTextView.textColor = .labelColor
        translatedTextView.isVerticallyResizable = true
        translatedTextView.isHorizontallyResizable = false
        translatedTextView.minSize = NSSize(width: 0, height: 0)
        translatedTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        translatedTextView.autoresizingMask = [.width]
        translatedTextView.textContainer?.containerSize = NSSize(width: 520, height: CGFloat.greatestFiniteMagnitude)
        translatedTextView.textContainer?.widthTracksTextView = true
        translatedTextView.textContainer?.lineBreakMode = .byCharWrapping
        translatedTextView.textContainer?.lineFragmentPadding = 0

        translatedScroll.borderType = .noBorder
        translatedScroll.drawsBackground = false
        translatedScroll.hasVerticalScroller = true
        translatedScroll.hasHorizontalScroller = false
        translatedScroll.autohidesScrollers = true
        translatedScroll.scrollerStyle = .overlay
        translatedScroll.documentView = translatedTextView
        translatedScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        translatedScroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        translatedScroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
        translatedScroll.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

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

        let stack = NSStackView(views: [originalLabel, phoneticLabel, translatedScroll, detailsLabel, bottomRow])
        stack.orientation = .vertical
        stack.alignment = .width
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

        let heightC = translatedScroll.heightAnchor.constraint(equalToConstant: 22)
        heightC.priority = .required
        heightC.isActive = true
        translatedHeightConstraint = heightC
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyCardColors()
    }

    override func layout() {
        super.layout()
        // Ensure line wrapping matches the current scroll view width.
        let w = max(60, translatedScroll.contentSize.width)
        translatedTextView.textContainer?.containerSize = NSSize(width: w, height: CGFloat.greatestFiniteMagnitude)
        translatedTextView.textContainer?.widthTracksTextView = true
    }

    func render(original: String, phonetic: String?, translated: String, isWord: Bool, senses: [WordSense]?, llmUsed: Bool?) {
        originalLabel.stringValue = original
        setPhonetic(phonetic)
        setTranslatedText(formattedTranslatedText(translated, isWord: isWord))
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

    private func setTranslatedText(_ text: String) {
        let font = translatedTextView.font ?? NSFont.systemFont(ofSize: 14, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ]
        translatedTextView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attrs))
        translatedTextView.scrollToBeginningOfDocument(nil)
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
        let translated = translatedTextView.string
        let details = (detailsVisible && !detailsLabel.isHidden) ? detailsLabel.stringValue : ""
        let hint = hintLabel.stringValue
        let llmStatus = llmStatusLabel.stringValue
        let read = readButton.title
        let more = moreButton.isHidden ? "" : moreButton.title

        let originalFont = originalLabel.font ?? NSFont.systemFont(ofSize: 14, weight: .semibold)
        let phoneticFont = phoneticLabel.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let translatedFont = translatedTextView.font ?? NSFont.systemFont(ofSize: 14, weight: .regular)
        let detailsFont = detailsLabel.font ?? NSFont.systemFont(ofSize: 13, weight: .regular)
        let hintFont = hintLabel.font ?? NSFont.systemFont(ofSize: 11, weight: .regular)

        func maxLineWidth(_ text: String, font: NSFont) -> CGFloat {
            if text.isEmpty { return 0 }
            let lines = text.split(separator: "\n").map(String.init)
            return lines.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        }

        let originalSingle = (original as NSString).size(withAttributes: [.font: originalFont]).width
        let phoneticSingle = (phonetic as NSString).size(withAttributes: [.font: phoneticFont]).width
        let translatedSingle = maxLineWidth(translated, font: translatedFont)
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
        let translatedInsetsV: CGFloat = 4
        let h2 = height(translated, font: translatedFont) + translatedInsetsV
        let hDetails = details.isEmpty ? 0 : height(details, font: detailsFont)
        let hBottom = height(hint, font: hintFont)

        var visibleBlocks = 1 // original
        if !phonetic.isEmpty { visibleBlocks += 1 }
        visibleBlocks += 1 // translated
        if !details.isEmpty { visibleBlocks += 1 }
        visibleBlocks += 1 // bottom row

        let totalSpacing = interSpacing * CGFloat(max(0, visibleBlocks - 1))
        let maxBubbleHeight: CGFloat = 420
        let fixedH = paddingV + h1 + hPh + hDetails + hBottom + totalSpacing
        let maxTranslatedVisible = max(0, maxBubbleHeight - fixedH)
        let minTranslatedVisible = ceil(NSLayoutManager().defaultLineHeight(for: translatedFont)) + translatedInsetsV
        let translatedVisible = min(max(h2, minTranslatedVisible), maxTranslatedVisible)
        let totalH = fixedH + translatedVisible

        translatedHeightConstraint?.constant = translatedVisible

        return NSSize(width: ceil(targetWidth), height: min(maxBubbleHeight, max(88, totalH)))
    }

}
