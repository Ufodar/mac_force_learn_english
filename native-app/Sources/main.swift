import Cocoa
import CoreServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let config = AppConfig.shared
    private let store = VocabStore()
    private let llm = LLMClient()
    private let offline = OfflineVocabProvider()
    private let overlay = OverlayController()
    private let settingsWC = SettingsWindowController()
    private lazy var quickTranslate = QuickTranslateController(store: store, llm: llm)
    private lazy var wordbookWC = WordbookWindowController(store: store)
    private let mainWC = MainWindowController()

    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var isReviewMode: Bool = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupMenuBar()
        setupOverlayCallbacks()
        warnIfNotInstalledInApplications()

        mainWC.onShowNow = { [weak self] in
            Task { await self?.showNext(mode: .manual) }
        }
        mainWC.onToggleDND = { [weak self] in
            self?.toggleDND()
        }
        mainWC.onToggleReview = { [weak self] in
            self?.onReview()
        }
        mainWC.onToggleQuickTranslate = { [weak self] in
            self?.onToggleQuickTranslate()
        }
        mainWC.onOpenSettings = { [weak self] in
            self?.settingsWC.show()
        }
        mainWC.onOpenWordbook = { [weak self] in
            self?.wordbookWC.show()
        }
        mainWC.onOpenStats = { [weak self] in
            self?.onStats()
        }
        mainWC.onOpenQuickTranslateStatus = { [weak self] in
            self?.quickTranslate.debugShowStatus()
        }
        mainWC.isReviewModeProvider = { [weak self] in
            self?.isReviewMode ?? false
        }
        mainWC.summaryProvider = { [weak self] in
            guard let self else { return "" }
            let offlinePath = self.config.offlineVocabPathEffective
            let offlineOK = self.config.offlineEnabled && !offlinePath.isEmpty && FileManager.default.fileExists(atPath: offlinePath)
            let llmOK = self.config.llmEnabled && !self.config.llmEndpointEffective.isEmpty && !self.config.llmModelEffective.isEmpty
            let words = self.store.data.items.filter { $0.type == .word }.count
            let sentences = self.store.data.items.filter { $0.type == .sentence }.count
            return "Offline: \(offlineOK ? "READY" : "NO")   LLM: \(llmOK ? "READY" : "NO")\nWords: \(words)   Sentences: \(sentences)"
        }

        settingsWC.onConfigChanged = { [weak self] in
            self?.overlay.refreshDND()
            self?.quickTranslate.applyConfig()
            self?.restartTimer()
            self?.refreshMenuChecks()
            self?.mainWC.refresh()
        }
        settingsWC.onRequestQuickTranslateNow = { [weak self] in
            self?.quickTranslate.debugShowStatus()
        }
        settingsWC.onOpenWordbook = { [weak self] in
            self?.wordbookWC.show()
        }

        restartTimer()
        quickTranslate.applyConfig()

        // Only force-open Settings when there is no content source available yet.
        if store.data.items.isEmpty {
            let llmReady = !config.llmEndpointEffective.isEmpty && !config.llmModelEffective.isEmpty
            let offlinePath = config.offlineVocabPathEffective
            let offlineLikelyReady = config.offlineEnabled && !offlinePath.isEmpty && FileManager.default.fileExists(atPath: offlinePath)
            if !llmReady && !offlineLikelyReady {
                settingsWC.show()
            }
        }

        // Show a normal main window (not menu-only) for better usability.
        mainWC.show()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWC.show()
        return true
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
        menu.addItem(NSMenuItem(title: "Quick Translate Status", action: #selector(onQuickTranslateStatus), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Wordbook", action: #selector(onWordbook), keyEquivalent: ""))
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
        mainWC.refresh()
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

        if config.offlineEnabled {
            if let item = await offline.pickItem(
                enabledCategories: config.enabledCategories,
                existingDedupeKeys: existingDedupeKeys(),
                wordWeight: config.wordWeight,
                sentenceWeight: config.sentenceWeight
            ) {
                _ = store.addItemIfNew(item)
                return (item, item.type == .word)
            }
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

    @objc private func onQuickTranslateStatus() {
        quickTranslate.debugShowStatus()
    }

    @objc private func onWordbook() {
        wordbookWC.show()
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

    private func warnIfNotInstalledInApplications() {
        let path = Bundle.main.bundlePath
        let bundleId = Bundle.main.bundleIdentifier ?? ""

        if path.hasPrefix("/Applications/") { return }

        var copies: [String] = []
        if !bundleId.isEmpty {
            var error: Unmanaged<CFError>?
            if let urls = LSCopyApplicationURLsForBundleIdentifier(bundleId as CFString, &error)?.takeRetainedValue() as? [URL] {
                copies = urls.map { $0.path }.sorted()
            }
        }

        let preferredAppPath = "/Applications/MacForceLearnEnglish.app"
        let preferredExists = FileManager.default.fileExists(atPath: preferredAppPath)
        let multipleCopies = copies.count > 1

        let alert = NSAlert()
        alert.messageText = preferredExists
            ? "Open the copy in /Applications"
            : "Move MacForceLearnEnglish.app to /Applications"

        var info = ""
        info += "You are running from:\n\(path)\n\n"
        info += "macOS permissions (Accessibility / Input Monitoring) may keep prompting or not work if you run from a DMG/Downloads/build folder.\n\n"
        info += "Note: if this app is built from source without a signing identity (ad-hoc signature), macOS may treat each rebuild as a new app and require re-granting permissions. A stable code signature (Developer ID / local Code Signing cert) avoids this.\n\n"
        if multipleCopies {
            info += "Copies detected (\(copies.count)):\n"
            info += copies.prefix(6).joined(separator: "\n")
            if copies.count > 6 { info += "\n…" }
            info += "\n\nTip: keep only one copy in /Applications and open it from Finder (not Spotlight) to avoid permission mismatch."
        }

        alert.informativeText = info.trimmingCharacters(in: .whitespacesAndNewlines)
        if preferredExists {
            alert.addButton(withTitle: "Open /Applications Copy")
            alert.addButton(withTitle: "Open /Applications Folder")
            alert.addButton(withTitle: "Continue Here")

            let res = alert.runModal()
            if res == .alertFirstButtonReturn {
                let url = URL(fileURLWithPath: preferredAppPath, isDirectory: true)
                let cfg = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in
                    DispatchQueue.main.async {
                        NSApp.terminate(nil)
                    }
                }
            } else if res == .alertSecondButtonReturn {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
            }
        } else {
            alert.addButton(withTitle: "Open /Applications")
            alert.addButton(withTitle: "Continue")

            let res = alert.runModal()
            if res == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
            }
        }
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
