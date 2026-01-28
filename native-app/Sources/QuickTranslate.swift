import ApplicationServices
import Carbon.HIToolbox
import Cocoa

@MainActor
final class QuickTranslateController {
    private var mouseMonitor: Any?
    private var debounceWorkItem: DispatchWorkItem?
    private var hideWorkItem: DispatchWorkItem?
    private var currentTask: Task<Void, Never>?
    private var pollTimer: Timer?
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?

    private var lastText: String = ""
    private var pendingPollText: String = ""

    private let llm: LLMClient
    private let panel: NSPanel
    private let contentView: QuickTranslateView

    init(llm: LLMClient = LLMClient()) {
        self.llm = llm

        self.contentView = QuickTranslateView(frame: NSRect(x: 0, y: 0, width: 520, height: 180))

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
        if AppConfig.shared.quickTranslateEnabled {
            start()
        } else {
            stop()
        }
    }

    func start() {
        guard mouseMonitor == nil else { return }

        requestAccessibilityPromptIfNeeded()
        requestInputMonitoringPromptIfNeeded()

        setupEventTapIfPossible()

        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            self?.scheduleCheck()
        }

        // Polling helps apps that don't emit global mouse events without Input Monitoring,
        // and also helps apps that expose selected text via Accessibility.
        // It only uses Accessibility selection (no Cmd+C fallback) to avoid spamming copy.
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollSelectionTick()
            }
        }
    }

    func stop() {
        if let m = mouseMonitor { NSEvent.removeMonitor(m) }
        mouseMonitor = nil
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        currentTask?.cancel()
        currentTask = nil
        pollTimer?.invalidate()
        pollTimer = nil
        tearDownEventTap()
        hide()
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
        guard let text = fetchSelectedText(), isReasonable(text) else { return }
        await handleTrigger(text: text)
    }

    private func pollSelectionTick() {
        guard AppConfig.shared.quickTranslateEnabled else { return }
        guard shouldHandleNow() else { return }

        let text = fetchSelectedTextViaAccessibility().map(normalizeText) ?? ""
        if text.isEmpty { pendingPollText = ""; return }
        if !isReasonable(text) { pendingPollText = ""; return }

        // Wait for the selection to be stable for at least two ticks.
        if text == pendingPollText {
            Task { @MainActor in
                await self.handleTrigger(text: text)
            }
        } else {
            pendingPollText = text
        }
    }

    private func handleTrigger(text: String) async {
        if text == lastText { return }
        lastText = text

        currentTask?.cancel()
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let target = resolveTargetLanguage(for: text)
                let translated = try await llm.translate(text: text, target: target)
                if Task.isCancelled { return }
                await MainActor.run {
                    self.show(original: text, translated: translated)
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    self.show(original: text, translated: "Failed: \(error)")
                }
            }
        }
    }

    private func show(original: String, translated: String) {
        contentView.render(original: original, translated: translated)

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)

        let size = panel.frame.size
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
        guard CGPreflightListenEventAccess() else { return nil }

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

    private func normalizeText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        return trimmed.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
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
    private let arrowLabel = NSTextField(labelWithString: "→")
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
        originalLabel.maximumNumberOfLines = 2
        originalLabel.lineBreakMode = .byTruncatingTail

        arrowLabel.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        arrowLabel.textColor = .tertiaryLabelColor

        translatedLabel.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        translatedLabel.textColor = .labelColor
        translatedLabel.maximumNumberOfLines = 4

        hintLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.maximumNumberOfLines = 1
        hintLabel.stringValue = "Click to dismiss"

        let topRow = NSStackView(views: [originalLabel, arrowLabel, translatedLabel])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.distribution = .fill
        topRow.spacing = 8

        let stack = NSStackView(views: [topRow, hintLabel])
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

    func render(original: String, translated: String) {
        originalLabel.stringValue = original
        translatedLabel.stringValue = translated
    }

    override func mouseDown(with event: NSEvent) {
        onDismiss?()
    }
}
