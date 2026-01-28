import ApplicationServices
import Carbon.HIToolbox
import Cocoa

private let quickTranslateHotKeySignature: OSType = OSType(0x4D464C45) // "MFLE"
private let quickTranslateHotKeyId: UInt32 = 1

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
final class QuickTranslateController {
    private var mouseMonitor: Any?
    private var debounceWorkItem: DispatchWorkItem?
    private var hideWorkItem: DispatchWorkItem?
    private var currentTask: Task<Void, Never>?
    private var pollTimer: Timer?
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var lastEnsureAttemptAt: CFAbsoluteTime = 0
    private var didShowPermissionHint: Bool = false
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?
    private var lastHotKeyAt: CFAbsoluteTime = 0

    private var lastText: String = ""
    private var pendingPollText: String = ""

    private let store: VocabStore
    private let llm: LLMClient
    private let panel: NSPanel
    private let contentView: QuickTranslateView

    init(store: VocabStore, llm: LLMClient = LLMClient()) {
        self.store = store
        self.llm = llm

        self.contentView = QuickTranslateView(frame: NSRect(x: 0, y: 0, width: 360, height: 120))

        let p = NSPanel(
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
        p.isMovableByWindowBackground = false
        p.contentView = contentView
        p.orderOut(nil)

        self.panel = p

        contentView.onDismiss = { [weak self] in
            self?.hide()
        }
    }

    func applyConfig() {
        stop()
        if AppConfig.shared.quickTranslateEnabled { start() }
    }

    func start() {
        guard isInstalledInApplicationsFolder() else {
            show(original: "Quick Translate disabled", phonetic: nil, translated: "Move the app to /Applications to make macOS permissions stick.")
            return
        }

        requestAccessibilityPromptIfNeeded()

        if AppConfig.shared.quickTranslateTrigger.lowercased() == "auto" {
            requestInputMonitoringPromptIfNeeded()
            ensureMonitors(throttled: false)
            startPolling()
        } else {
            setupHotKeyIfNeeded()
            show(original: "Quick Translate", phonetic: nil, translated: "Select text then press ⌘⌥P")
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
        stopPolling()
        tearDownEventTap()
        tearDownHotKey()
        hide()
    }

    func translateSelectionNow() {
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastHotKeyAt < 0.25 { return }
        lastHotKeyAt = now

        guard AppConfig.shared.quickTranslateEnabled else { return }
        guard shouldHandleNow() else { return }

        guard let text = fetchSelectedText().map(normalizeSelectionForLookup), isReasonable(text) else {
            show(original: "No selection", phonetic: nil, translated: "Select a word/sentence first, then press ⌘⌥P")
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
            do {
                let target = resolveTargetLanguage(for: text)
                let kind = inferItemType(from: text)

                // Word: prefer IPA lookup + cache
                if kind == .word, isEnglishWord(text) {
                    let cached = store.findItem(type: .word, front: text)

                    if let cached {
                        if Task.isCancelled { return }
                        await MainActor.run {
                            self.show(original: text, phonetic: cached.phonetic, translated: cached.back)
                        }
                        _ = saveLookupIfEnabled(itemType: .word, front: text, back: cached.back, phonetic: cached.phonetic, countAsShown: true)

                        if let p = cached.phonetic, !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            return
                        }
                    } else {
                        await MainActor.run { self.show(original: text, phonetic: nil, translated: "Looking up…") }
                    }

                    let payload = try await llm.lookupWord(text, target: target)
                    if Task.isCancelled { return }
                    await MainActor.run {
                        self.show(original: text, phonetic: payload.phonetic, translated: payload.meaning)
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
                        self.show(original: text, phonetic: nil, translated: cached.back)
                    }
                    _ = saveLookupIfEnabled(itemType: kind, front: text, back: cached.back, phonetic: nil, countAsShown: true)
                    return
                }

                await MainActor.run { self.show(original: text, phonetic: nil, translated: "Translating…") }
                let translated = try await llm.translate(text: text, target: target)
                if Task.isCancelled { return }
                await MainActor.run {
                    self.show(original: text, phonetic: nil, translated: translated)
                }
                _ = saveLookupIfEnabled(itemType: kind, front: text, back: translated, phonetic: nil, countAsShown: true)
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    self.show(original: text, phonetic: nil, translated: "Failed: \(error)")
                }
            }
        }
    }

    private func show(original: String, phonetic: String?, translated: String) {
        contentView.render(original: original, phonetic: phonetic, translated: translated)

        let size = contentView.preferredSize(maxWidth: 420)
        panel.setContentSize(size)

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)

        var x = mouse.x + 14
        var y = mouse.y - size.height - 14

        if x + size.width > screenFrame.maxX - 10 {
            x = screenFrame.maxX - size.width - 10
        }
        if x < screenFrame.minX + 10 {
            x = screenFrame.minX + 10
        }
        if y < screenFrame.minY + 10 {
            y = mouse.y + 14
        }
        if y + size.height > screenFrame.maxY - 10 {
            y = screenFrame.maxY - size.height - 10
        }

        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()

        scheduleAutoHide()
    }

    private func scheduleAutoHide() {
        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.hide() }
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    private func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        panel.orderOut(nil)
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
        if trimmed.count > 200 { return false }
        return true
    }

    private func fetchSelectedText() -> String? {
        if let s = fetchSelectedTextViaAccessibility() {
            let t = normalizeText(s)
            return t.isEmpty ? nil : t
        }
        if let s = fetchSelectedTextViaCopyPreservingClipboard() {
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
        let okSelected = AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString, &selected)
        guard okSelected == .success else { return nil }

        if let s = selected as? String, !s.isEmpty { return s }
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

    private func fetchSelectedTextViaCopyPreservingClipboard() -> String? {
        guard AXIsProcessTrusted() else { return nil }

        let pb = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pb)
        let before = pb.changeCount

        sendCopyShortcut()

        for _ in 0..<14 {
            if pb.changeCount != before { break }
            usleep(25_000)
        }

        let text = pb.string(forType: .string)
        snapshot.restore(to: pb)
        return text
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
        show(original: "Quick Translate Status", phonetic: nil, translated: permissionStatusString())
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
        var trimSet = CharacterSet.whitespacesAndNewlines
        trimSet.formUnion(.punctuationCharacters)
        trimSet.formUnion(.symbols)
        return normalized.trimmingCharacters(in: trimSet)
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
    private func saveLookupIfEnabled(itemType: VocabItemType, front: String, back: String, phonetic: String?, countAsShown: Bool) -> VocabItem? {
        guard AppConfig.shared.quickTranslateSaveToWordbook else { return nil }
        let item = store.upsertItem(type: itemType, front: front, back: back, phonetic: phonetic, category: "lookup", source: "lookup")
        guard countAsShown else { return item }
        let countedAsNewWord = (item.type == .word && item.timesShown == 0)
        return store.recordShown(item, countedAsNewWord: countedAsNewWord)
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
                translated: "Accessibility: \(ax ? "OK" : "NO"), Input Monitoring: \(listen ? "OK" : "NO"). Enable them for this app in System Settings."
            )
        } else {
            show(
                original: "Quick Translate needs permission",
                phonetic: nil,
                translated: "Accessibility: \(ax ? "OK" : "NO"). Enable it for this app in System Settings."
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
    private let originalLabel = NSTextField(labelWithString: "")
    private let phoneticLabel = NSTextField(labelWithString: "")
    private let translatedLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")

    var onDismiss: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        card.layer?.cornerRadius = 12
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.separatorColor.cgColor

        originalLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        originalLabel.textColor = .labelColor
        originalLabel.maximumNumberOfLines = 4
        originalLabel.lineBreakMode = .byWordWrapping

        phoneticLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        phoneticLabel.textColor = .secondaryLabelColor
        phoneticLabel.maximumNumberOfLines = 1

        translatedLabel.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        translatedLabel.textColor = .labelColor
        translatedLabel.maximumNumberOfLines = 8
        translatedLabel.lineBreakMode = .byWordWrapping

        hintLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.maximumNumberOfLines = 1
        hintLabel.stringValue = "Click to dismiss"

        let stack = NSStackView(views: [originalLabel, phoneticLabel, translatedLabel, hintLabel])
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

    func render(original: String, phonetic: String?, translated: String) {
        originalLabel.stringValue = original
        let p = (phonetic ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty {
            phoneticLabel.stringValue = ""
            phoneticLabel.isHidden = true
        } else {
            phoneticLabel.stringValue = p
            phoneticLabel.isHidden = false
        }
        translatedLabel.stringValue = translated
    }

    func preferredSize(maxWidth: CGFloat) -> NSSize {
        let minWidth: CGFloat = 220
        let paddingH: CGFloat = 14 * 2
        let paddingV: CGFloat = 12 * 2
        let interSpacing: CGFloat = 8

        let original = originalLabel.stringValue
        let phonetic = phoneticLabel.isHidden ? "" : phoneticLabel.stringValue
        let translated = translatedLabel.stringValue
        let hint = hintLabel.stringValue

        let originalFont = originalLabel.font ?? NSFont.systemFont(ofSize: 14, weight: .semibold)
        let phoneticFont = phoneticLabel.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let translatedFont = translatedLabel.font ?? NSFont.systemFont(ofSize: 14, weight: .regular)
        let hintFont = hintLabel.font ?? NSFont.systemFont(ofSize: 11, weight: .regular)

        let originalSingle = (original as NSString).size(withAttributes: [.font: originalFont]).width
        let phoneticSingle = (phonetic as NSString).size(withAttributes: [.font: phoneticFont]).width
        let translatedSingle = (translated as NSString).size(withAttributes: [.font: translatedFont]).width
        let hintSingle = (hint as NSString).size(withAttributes: [.font: hintFont]).width

        let targetWidth = min(maxWidth, max(minWidth, max(originalSingle, phoneticSingle, translatedSingle, hintSingle) + paddingH))
        let contentWidth = max(80, targetWidth - paddingH)

        func height(_ text: String, font: NSFont) -> CGFloat {
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
        let h3 = height(hint, font: hintFont)
        let lines = phonetic.isEmpty ? 3 : 4
        let totalSpacing = interSpacing * CGFloat(max(0, lines - 1))
        let totalH = paddingV + h1 + hPh + h2 + h3 + totalSpacing

        return NSSize(width: ceil(targetWidth), height: min(280, max(88, totalH)))
    }

    override func mouseDown(with event: NSEvent) {
        onDismiss?()
    }
}
