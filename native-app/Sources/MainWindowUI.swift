import Cocoa

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let config: AppConfig

    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private let dndButton = NSButton(checkboxWithTitle: "Do Not Disturb", target: nil, action: nil)
    private let reviewButton = NSButton(checkboxWithTitle: "Review Mode", target: nil, action: nil)
    private let quickTranslateButton = NSButton(checkboxWithTitle: "Quick Translate", target: nil, action: nil)

    private let showNowButton = NSButton(title: "Show Now", target: nil, action: nil)
    private let settingsButton = NSButton(title: "Settings…", target: nil, action: nil)
    private let wordbookButton = NSButton(title: "Wordbook", target: nil, action: nil)
    private let statsButton = NSButton(title: "Stats", target: nil, action: nil)
    private let qtStatusButton = NSButton(title: "Quick Translate Status", target: nil, action: nil)

    var onShowNow: (() -> Void)?
    var onToggleDND: (() -> Void)?
    var onToggleReview: (() -> Void)?
    var onToggleQuickTranslate: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenWordbook: (() -> Void)?
    var onOpenStats: (() -> Void)?
    var onOpenQuickTranslateStatus: (() -> Void)?

    var isReviewModeProvider: (() -> Bool)?
    var summaryProvider: (() -> String)?

    init(config: AppConfig = .shared) {
        self.config = config
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MacForceLearnEnglish"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildUI()
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        guard let w = window else { return }
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refresh()
    }

    func refresh() {
        dndButton.state = config.doNotDisturb ? .on : .off
        quickTranslateButton.state = config.quickTranslateEnabled ? .on : .off
        reviewButton.state = (isReviewModeProvider?() ?? false) ? .on : .off

        if let text = summaryProvider?() {
            summaryLabel.stringValue = text
        } else {
            summaryLabel.stringValue = ""
        }
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true

        let title = NSTextField(labelWithString: "MacForceLearnEnglish")
        title.font = NSFont.systemFont(ofSize: 20, weight: .semibold)

        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        summaryLabel.maximumNumberOfLines = 6

        dndButton.target = self
        dndButton.action = #selector(onDNDClicked)

        reviewButton.target = self
        reviewButton.action = #selector(onReviewClicked)

        quickTranslateButton.target = self
        quickTranslateButton.action = #selector(onQuickTranslateClicked)

        showNowButton.bezelStyle = .rounded
        showNowButton.target = self
        showNowButton.action = #selector(onShowNowClicked)

        settingsButton.bezelStyle = .rounded
        settingsButton.target = self
        settingsButton.action = #selector(onSettingsClicked)

        wordbookButton.bezelStyle = .rounded
        wordbookButton.target = self
        wordbookButton.action = #selector(onWordbookClicked)

        statsButton.bezelStyle = .rounded
        statsButton.target = self
        statsButton.action = #selector(onStatsClicked)

        qtStatusButton.bezelStyle = .rounded
        qtStatusButton.target = self
        qtStatusButton.action = #selector(onQTStatusClicked)

        let toggles = NSStackView(views: [dndButton, reviewButton, quickTranslateButton])
        toggles.orientation = .horizontal
        toggles.alignment = .centerY
        toggles.spacing = 14

        let actions = NSStackView(views: [showNowButton, settingsButton, wordbookButton, statsButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 12

        let tools = NSStackView(views: [qtStatusButton])
        tools.orientation = .horizontal
        tools.alignment = .centerY
        tools.spacing = 12

        let hint = NSTextField(wrappingLabelWithString: """
        Tips:
        - Overlay: Space show/hide · N next · E new example · D toggle DND · Esc close
        - Quick Translate: select text then press ⌘⌥P (or enable Auto in Settings)
        """)
        hint.textColor = .secondaryLabelColor
        hint.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        hint.maximumNumberOfLines = 6

        let stack = NSStackView(views: [title, summaryLabel, toggles, actions, tools, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
        ])
    }

    @objc private func onShowNowClicked() {
        onShowNow?()
    }

    @objc private func onSettingsClicked() {
        onOpenSettings?()
    }

    @objc private func onWordbookClicked() {
        onOpenWordbook?()
    }

    @objc private func onStatsClicked() {
        onOpenStats?()
    }

    @objc private func onQTStatusClicked() {
        onOpenQuickTranslateStatus?()
    }

    @objc private func onDNDClicked() {
        onToggleDND?()
    }

    @objc private func onReviewClicked() {
        onToggleReview?()
    }

    @objc private func onQuickTranslateClicked() {
        onToggleQuickTranslate?()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        refresh()
    }
}

