import ApplicationServices
import Cocoa
import CoreServices

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let endpointField = NSTextField(string: "")
    private let modelField = NSTextField(string: "")
    private let apiKeyField = NSSecureTextField(string: "")

    private let intervalField = NSTextField(string: "")
    private let displayField = NSTextField(string: "")
    private let newBeforeReviewField = NSTextField(string: "")

    private let enableLLMButton = NSButton(checkboxWithTitle: "Enable LLM", target: nil, action: nil)
    private let dndButton = NSButton(checkboxWithTitle: "Do Not Disturb", target: nil, action: nil)
    private let quickTranslateButton = NSButton(checkboxWithTitle: "Quick Translate", target: nil, action: nil)
    private let quickTranslateSaveButton = NSButton(checkboxWithTitle: "Save to Wordbook", target: nil, action: nil)
    private let quickTranslateTriggerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let quickTranslateTargetPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    private let catCS = NSButton(checkboxWithTitle: "cs", target: nil, action: nil)
    private let catGaokao = NSButton(checkboxWithTitle: "gaokao3500", target: nil, action: nil)
    private let catCet4 = NSButton(checkboxWithTitle: "cet4", target: nil, action: nil)
    private let catCet6 = NSButton(checkboxWithTitle: "cet6", target: nil, action: nil)

    private let statusLabel = NSTextField(labelWithString: "")
    private let diagnosticsLabel = NSTextField(wrappingLabelWithString: "")
    private var diagnosticsTimer: Timer?

    var onConfigChanged: (() -> Void)?
    var onRequestQuickTranslateNow: (() -> Void)?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 700),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildUI()
        loadFromConfig()
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        if let w = window {
            w.center()
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        startDiagnosticsTimer()
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2

        diagnosticsLabel.textColor = .secondaryLabelColor
        diagnosticsLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        diagnosticsLabel.maximumNumberOfLines = 9

        endpointField.placeholderString = "LLM base or endpoint, e.g. http://127.0.0.1:1234/v1  (or .../v1/chat/completions)"
        modelField.placeholderString = "model"
        apiKeyField.placeholderString = "apiKey (optional)"
        intervalField.placeholderString = "interval seconds (e.g. 1200)"
        displayField.placeholderString = "display seconds (e.g. 12)"
        newBeforeReviewField.placeholderString = "new words before review (e.g. 3)"

        let saveButton = NSButton(title: "Save", target: self, action: #selector(onSave))
        saveButton.bezelStyle = .rounded

        let testButton = NSButton(title: "Test LLM", target: self, action: #selector(onTest))
        testButton.bezelStyle = .rounded

        let requestPermButton = NSButton(title: "Request Permissions", target: self, action: #selector(onRequestPermissions))
        requestPermButton.bezelStyle = .rounded

        let openAXButton = NSButton(title: "Open Accessibility", target: self, action: #selector(onOpenAccessibility))
        openAXButton.bezelStyle = .rounded

        let openIMButton = NSButton(title: "Open Input Monitoring", target: self, action: #selector(onOpenInputMonitoring))
        openIMButton.bezelStyle = .rounded

        let tryQuickTranslateButton = NSButton(title: "Quick Translate Status", target: self, action: #selector(onTryQuickTranslateNow))
        tryQuickTranslateButton.bezelStyle = .rounded

        let copyDiagnosticsButton = NSButton(title: "Copy Diagnostics", target: self, action: #selector(onCopyDiagnostics))
        copyDiagnosticsButton.bezelStyle = .rounded

        let form = NSStackView()
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 10
        form.translatesAutoresizingMaskIntoConstraints = false

        func row(_ title: String, _ field: NSView) -> NSView {
            let label = NSTextField(labelWithString: title)
            label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            let stack = NSStackView(views: [label, field])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 4
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 520).isActive = true
            return stack
        }

        enableLLMButton.target = self
        enableLLMButton.action = #selector(onToggleLLM)
        dndButton.target = self
        dndButton.action = #selector(onToggleDND)
        quickTranslateButton.target = self
        quickTranslateButton.action = #selector(onToggleQuickTranslate)

        quickTranslateSaveButton.target = self
        quickTranslateSaveButton.action = #selector(onToggleQuickTranslateSave)

        quickTranslateTriggerPopup.addItems(withTitles: ["Hotkey (⌘⌥P)", "Auto on selection"])
        quickTranslateTriggerPopup.target = self
        quickTranslateTriggerPopup.action = #selector(onQuickTranslateTriggerChanged)

        quickTranslateTargetPopup.addItems(withTitles: ["English", "Chinese", "Auto"])
        quickTranslateTargetPopup.target = self
        quickTranslateTargetPopup.action = #selector(onQuickTranslateTargetChanged)

        [catCS, catGaokao, catCet4, catCet6].forEach { b in
            b.target = self
            b.action = #selector(onCategoryChanged)
        }

        let catsRow = NSStackView(views: [catCS, catGaokao, catCet4, catCet6])
        catsRow.orientation = .horizontal
        catsRow.alignment = .centerY
        catsRow.spacing = 14

        let toggles = NSStackView(views: [enableLLMButton, dndButton, quickTranslateButton, quickTranslateSaveButton])
        toggles.orientation = .horizontal
        toggles.alignment = .centerY
        toggles.spacing = 14

        let buttons = NSStackView(views: [saveButton, testButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 12

        let diagButtonsRow1 = NSStackView(views: [requestPermButton, openAXButton, openIMButton])
        diagButtonsRow1.orientation = .horizontal
        diagButtonsRow1.alignment = .centerY
        diagButtonsRow1.spacing = 12

        let diagButtonsRow2 = NSStackView(views: [tryQuickTranslateButton, copyDiagnosticsButton])
        diagButtonsRow2.orientation = .horizontal
        diagButtonsRow2.alignment = .centerY
        diagButtonsRow2.spacing = 12

        form.addArrangedSubview(toggles)
        form.addArrangedSubview(row("Endpoint", endpointField))
        form.addArrangedSubview(row("Model", modelField))
        form.addArrangedSubview(row("API Key", apiKeyField))
        form.addArrangedSubview(row("Interval Seconds", intervalField))
        form.addArrangedSubview(row("Display Seconds", displayField))
        form.addArrangedSubview(row("New Words Before Review", newBeforeReviewField))
        form.addArrangedSubview(row("Quick Translate Trigger", quickTranslateTriggerPopup))
        form.addArrangedSubview(row("Quick Translate Target", quickTranslateTargetPopup))
        form.addArrangedSubview(NSTextField(labelWithString: "Categories"))
        form.addArrangedSubview(catsRow)
        form.addArrangedSubview(buttons)
        form.addArrangedSubview(statusLabel)
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.widthAnchor.constraint(equalToConstant: 520).isActive = true
        form.addArrangedSubview(separator)
        form.addArrangedSubview(NSTextField(labelWithString: "Diagnostics"))
        form.addArrangedSubview(diagnosticsLabel)
        form.addArrangedSubview(diagButtonsRow1)
        form.addArrangedSubview(diagButtonsRow2)

        content.addSubview(form)
        NSLayoutConstraint.activate([
            form.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            form.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            form.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
        ])
    }

    private func loadFromConfig() {
        let c = AppConfig.shared
        enableLLMButton.state = c.llmEnabled ? .on : .off
        dndButton.state = c.doNotDisturb ? .on : .off
        quickTranslateButton.state = c.quickTranslateEnabled ? .on : .off
        quickTranslateSaveButton.state = c.quickTranslateSaveToWordbook ? .on : .off

        switch c.quickTranslateTrigger.lowercased() {
        case "auto":
            quickTranslateTriggerPopup.selectItem(at: 1)
        default:
            quickTranslateTriggerPopup.selectItem(at: 0)
        }

        switch c.quickTranslateTarget.lowercased() {
        case "zh":
            quickTranslateTargetPopup.selectItem(at: 1)
        case "auto":
            quickTranslateTargetPopup.selectItem(at: 2)
        default:
            quickTranslateTargetPopup.selectItem(at: 0)
        }
        quickTranslateSaveButton.isEnabled = c.quickTranslateEnabled
        quickTranslateTriggerPopup.isEnabled = c.quickTranslateEnabled
        quickTranslateTargetPopup.isEnabled = c.quickTranslateEnabled

        endpointField.stringValue = c.llmEndpoint.isEmpty ? c.llmEndpointEffective : c.llmEndpoint
        modelField.stringValue = c.llmModel.isEmpty ? c.llmModelEffective : c.llmModel
        apiKeyField.stringValue = c.llmApiKey.isEmpty ? c.llmApiKeyEffective : c.llmApiKey

        intervalField.stringValue = String(Int(c.intervalSeconds))
        displayField.stringValue = String(Int(c.displaySeconds))
        newBeforeReviewField.stringValue = String(c.newWordsBeforeReview)

        let enabled = Set(c.enabledCategories)
        catCS.state = enabled.contains("cs") ? .on : .off
        catGaokao.state = enabled.contains("gaokao3500") ? .on : .off
        catCet4.state = enabled.contains("cet4") ? .on : .off
        catCet6.state = enabled.contains("cet6") ? .on : .off
    }

    @objc private func onSave() {
        let c = AppConfig.shared
        c.llmEnabled = enableLLMButton.state == .on
        c.doNotDisturb = dndButton.state == .on
        c.quickTranslateEnabled = quickTranslateButton.state == .on
        c.quickTranslateSaveToWordbook = quickTranslateSaveButton.state == .on
        c.llmEndpoint = endpointField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        c.llmModel = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        c.llmApiKey = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        if let v = Double(intervalField.stringValue) { c.intervalSeconds = max(5, v) }
        if let v = Double(displayField.stringValue) { c.displaySeconds = max(2, v) }
        if let v = Int(newBeforeReviewField.stringValue) { c.newWordsBeforeReview = max(1, v) }

        onQuickTranslateTriggerChanged()
        onQuickTranslateTargetChanged()
        onCategoryChanged()
        statusLabel.stringValue = "Saved."
        onConfigChanged?()
    }

    @objc private func onTest() {
        statusLabel.stringValue = "Testing..."
        let client = LLMClient()
        Task {
            do {
                let dummy = try await client.generateExample(for: "algorithm")
                statusLabel.stringValue = "OK: \(dummy.en.prefix(80))"
            } catch {
                statusLabel.stringValue = "Failed: \(error)"
            }
        }
    }

    @objc private func onRequestPermissions() {
        requestAccessibilityPromptIfNeeded()
        requestInputMonitoringPromptIfNeeded()
        updateDiagnostics()
    }

    @objc private func onOpenAccessibility() {
        openPrivacyPane(anchor: "Privacy_Accessibility")
    }

    @objc private func onOpenInputMonitoring() {
        openPrivacyPane(anchor: "Privacy_ListenEvent")
    }

    @objc private func onTryQuickTranslateNow() {
        onRequestQuickTranslateNow?()
    }

    @objc private func onCopyDiagnostics() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(diagnosticsLabel.stringValue, forType: .string)
        statusLabel.stringValue = "Diagnostics copied."
    }

    @objc private func onToggleLLM() {
        AppConfig.shared.llmEnabled = enableLLMButton.state == .on
        onConfigChanged?()
    }

    @objc private func onToggleDND() {
        AppConfig.shared.doNotDisturb = dndButton.state == .on
        onConfigChanged?()
    }

    @objc private func onToggleQuickTranslate() {
        AppConfig.shared.quickTranslateEnabled = quickTranslateButton.state == .on
        let enabled = quickTranslateButton.state == .on
        quickTranslateSaveButton.isEnabled = enabled
        quickTranslateTriggerPopup.isEnabled = enabled
        quickTranslateTargetPopup.isEnabled = enabled
        onConfigChanged?()
    }

    @objc private func onToggleQuickTranslateSave() {
        AppConfig.shared.quickTranslateSaveToWordbook = quickTranslateSaveButton.state == .on
        onConfigChanged?()
    }

    @objc private func onQuickTranslateTriggerChanged() {
        switch quickTranslateTriggerPopup.indexOfSelectedItem {
        case 1:
            AppConfig.shared.quickTranslateTrigger = "auto"
        default:
            AppConfig.shared.quickTranslateTrigger = "hotkey"
        }
        onConfigChanged?()
    }

    @objc private func onQuickTranslateTargetChanged() {
        switch quickTranslateTargetPopup.indexOfSelectedItem {
        case 1:
            AppConfig.shared.quickTranslateTarget = "zh"
        case 2:
            AppConfig.shared.quickTranslateTarget = "auto"
        default:
            AppConfig.shared.quickTranslateTarget = "en"
        }
        onConfigChanged?()
    }

    @objc private func onCategoryChanged() {
        var cats: [String] = []
        if catCS.state == .on { cats.append("cs") }
        if catGaokao.state == .on { cats.append("gaokao3500") }
        if catCet4.state == .on { cats.append("cet4") }
        if catCet6.state == .on { cats.append("cet6") }
        AppConfig.shared.enabledCategories = cats.isEmpty ? ["cs"] : cats
        onConfigChanged?()
    }

    func windowWillClose(_ notification: Notification) {
        stopDiagnosticsTimer()
    }

    private func startDiagnosticsTimer() {
        stopDiagnosticsTimer()
        updateDiagnostics()
        diagnosticsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateDiagnostics()
            }
        }
    }

    private func stopDiagnosticsTimer() {
        diagnosticsTimer?.invalidate()
        diagnosticsTimer = nil
    }

    private func updateDiagnostics() {
        let bundlePath = Bundle.main.bundlePath
        let bundleId = Bundle.main.bundleIdentifier ?? "(unknown bundle id)"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

        let ax = AXIsProcessTrusted()
        let listen = CGPreflightListenEventAccess()
        let inApplications = bundlePath.hasPrefix("/Applications/")

        let copies = appCopies(bundleId: bundleId)
        let copiesLine = copies.isEmpty ? "Copies found: ?" : "Copies found: \(copies.count)"
        let copiesDetails = copies.prefix(3).joined(separator: "\n")

        diagnosticsLabel.stringValue = [
            "App: \(bundlePath)",
            "Bundle: \(bundleId) v\(version) (\(build))",
            "Accessibility: \(ax ? "OK" : "NO")    Input Monitoring: \(listen ? "OK" : "NO")",
            "Installed in /Applications: \(inApplications ? "YES" : "NO")",
            copiesLine,
            copiesDetails.isEmpty ? nil : "First copies:\n\(copiesDetails)",
            "Tip: if prompts repeat, delete other copies and open /Applications/MacForceLearnEnglish.app.",
        ]
        .compactMap { $0 }
        .joined(separator: "\n")
    }

    private func appCopies(bundleId: String) -> [String] {
        var error: Unmanaged<CFError>?
        guard let urls = LSCopyApplicationURLsForBundleIdentifier(bundleId as CFString, &error)?.takeRetainedValue() as? [URL] else {
            return []
        }
        return urls.map { $0.path }.sorted()
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

    private func openPrivacyPane(anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
