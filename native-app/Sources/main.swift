import Cocoa

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let config = AppConfig.shared
    private let store = VocabStore()
    private let llm = LLMClient()
    private let overlay = OverlayController()
    private let settingsWC = SettingsWindowController()
    private let quickTranslate = QuickTranslateController()

    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var isReviewMode: Bool = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupMenuBar()
        setupOverlayCallbacks()
        settingsWC.onConfigChanged = { [weak self] in
            self?.overlay.refreshDND()
            self?.quickTranslate.applyConfig()
            self?.restartTimer()
            self?.refreshMenuChecks()
        }

        restartTimer()
        quickTranslate.applyConfig()

        if config.llmEndpoint.isEmpty || config.llmModel.isEmpty {
            settingsWC.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        quickTranslate.stop()
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        let aboutItem = NSMenuItem(title: "About MacForceLearnEnglish", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(aboutItem)

        appMenu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(onSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)

        appMenu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit MacForceLearnEnglish", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.addItem(quitItem)

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)

        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu

        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        NSApp.mainMenu = mainMenu
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let img = NSImage(systemSymbolName: "character.book.closed.fill", accessibilityDescription: "EN") {
            statusItem.button?.image = img
            statusItem.button?.imagePosition = .imageOnly
            statusItem.button?.title = ""
        } else {
            statusItem.button?.title = "EN"
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show Now", action: #selector(onShowNow), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Review", action: #selector(onReview), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Do Not Disturb", action: #selector(onToggleDND), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quick Translate", action: #selector(onToggleQuickTranslate), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(onSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Stats", action: #selector(onStats), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(onQuit), keyEquivalent: "q"))
        statusItem.menu = menu

        refreshMenuChecks()
    }

    private func setupOverlayCallbacks() {
        overlay.onDismiss = { [weak self] in
            self?.isReviewMode = false
            self?.refreshMenuChecks()
        }
        overlay.onNext = { [weak self] in
            Task { await self?.showNext(mode: self?.isReviewMode == true ? .review : .manual) }
        }
        overlay.onGenerateExample = { [weak self] in
            Task { await self?.generateExampleIfPossible() }
        }
        overlay.onToggleDND = { [weak self] in
            self?.toggleDND()
        }
    }

    private func refreshMenuChecks() {
        guard let menu = statusItem.menu else { return }
        for item in menu.items {
            if item.title == "Do Not Disturb" {
                item.state = config.doNotDisturb ? .on : .off
            }
            if item.title == "Quick Translate" {
                item.state = config.quickTranslateEnabled ? .on : .off
            }
            if item.title == "Review" {
                item.state = isReviewMode ? .on : .off
            }
        }
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: max(5, config.intervalSeconds), repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.tick()
            }
        }
    }

    private func toggleDND() {
        config.doNotDisturb.toggle()
        refreshMenuChecks()
        overlay.refreshDND()
    }

    private func shouldReviewOldWordNow() -> Bool {
        let threshold = max(1, config.newWordsBeforeReview)
        return store.data.newWordsSinceLastReview >= threshold
    }

    private func chooseNextAutoMode() -> OverlayMode {
        if isReviewMode { return .review }
        return .auto
    }

    private func existingDedupeKeys() -> Set<String> {
        Set(store.data.items.map { VocabStore.dedupeKey(type: $0.type, front: $0.front) })
    }

    private func pickOrGenerateNext(for mode: OverlayMode) async -> (VocabItem, countedAsNewWord: Bool) {
        if mode == .review {
            if let old = store.pickOldWordForReview() {
                return (old, false)
            }
        }

        if mode == .auto, shouldReviewOldWordNow(), let old = store.pickOldWordForReview() {
            store.resetNewWordCounter()
            return (old, false)
        }

        let generated = try? await llm.generateItem(existingDedupeKeys: existingDedupeKeys())
        if let g = generated {
            _ = store.addItemIfNew(g)
            return (g, g.type == .word)
        }

        // LLM 失败：退回到已有内容
        if mode == .review, let old = store.pickOldWordForReview() {
            return (old, false)
        }
        if let any = store.data.items.randomElement() {
            return (any, false)
        }

        // 最后兜底
        return (
            VocabItem(
                id: UUID(),
                type: .word,
                front: "LLM not ready",
                back: "请在 Settings 配置 endpoint/model，并确保服务可用。",
                phonetic: nil,
                category: nil,
                examples: [],
                createdAt: Date(),
                lastShownAt: nil,
                timesShown: 0
            ),
            false
        )
    }

    private func showOverlay(item: VocabItem, mode: OverlayMode) {
        let autoHide: TimeInterval? = (mode == .review) ? nil : config.displaySeconds
        overlay.show(item: item, mode: mode, autoHideSeconds: autoHide)
    }

    @MainActor
    private func showNext(mode: OverlayMode) async {
        let effectiveMode = (mode == .manual) ? chooseNextAutoMode() : mode
        let (item, countedAsNew) = await pickOrGenerateNext(for: effectiveMode)
        let updated = store.recordShown(item, countedAsNewWord: countedAsNew && item.timesShown == 0)
        showOverlay(item: updated, mode: effectiveMode)
        refreshMenuChecks()
    }

    private func tick() async {
        if config.doNotDisturb { return }
        await showNext(mode: .auto)
    }

    private func generateExampleIfPossible() async {
        guard var item = overlay.currentItem, item.type == .word else { return }
        do {
            let ex = try await llm.generateExample(for: item.front)
            item.examples.append(ex)
            store.updateItem(item)
            overlay.updateCurrentItem(item, revealBack: true)
        } catch {
            NSLog("[llm] example failed: \(error)")
        }
    }

    @objc private func onShowNow() {
        Task { await showNext(mode: .manual) }
    }

    @objc private func onReview() {
        isReviewMode.toggle()
        refreshMenuChecks()
        if isReviewMode {
            Task { await showNext(mode: .review) }
        } else {
            overlay.hide()
        }
    }

    @objc private func onToggleDND() { toggleDND() }

    @objc private func onToggleQuickTranslate() {
        config.quickTranslateEnabled.toggle()
        quickTranslate.applyConfig()
        refreshMenuChecks()
    }

    @objc private func onSettings() { settingsWC.show() }

    @objc private func onStats() {
        let text = store.statsSummary()
        let alert = NSAlert()
        alert.messageText = "Stats"
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func onQuit() {
        NSApp.terminate(nil)
    }
}

@main
struct MacForceLearnEnglishMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
