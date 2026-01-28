import Cocoa

final class OverlayView: NSView {
    private let card = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let phoneticLabel = NSTextField(labelWithString: "")
    private let backLabel = NSTextField(labelWithString: "")
    private let exampleLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")

    var onToggleBack: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onNext: (() -> Void)?
    var onGenerateExample: (() -> Void)?
    var onToggleDND: (() -> Void)?

    private func applyCardColors() {
        // Note: converting dynamic system colors to CGColor freezes them; refresh on appearance changes.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            card.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
            card.layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor

        card.wantsLayer = true
        card.layer?.cornerRadius = 14
        card.layer?.borderWidth = 1
        applyCardColors()

        titleLabel.font = NSFont.systemFont(ofSize: 30, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 3

        phoneticLabel.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        phoneticLabel.alignment = .center
        phoneticLabel.textColor = .secondaryLabelColor
        phoneticLabel.maximumNumberOfLines = 2

        backLabel.font = NSFont.systemFont(ofSize: 18, weight: .regular)
        backLabel.alignment = .center
        backLabel.textColor = .labelColor
        backLabel.maximumNumberOfLines = 10

        exampleLabel.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        exampleLabel.alignment = .center
        exampleLabel.textColor = .secondaryLabelColor
        exampleLabel.maximumNumberOfLines = 8

        hintLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        hintLabel.alignment = .center
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.maximumNumberOfLines = 2

        let stack = NSStackView(views: [titleLabel, phoneticLabel, backLabel, exampleLabel, hintLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.distribution = .fill
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(stack)
        addSubview(card)

        card.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 760),
            card.widthAnchor.constraint(greaterThanOrEqualToConstant: 520),
            card.heightAnchor.constraint(lessThanOrEqualToConstant: 420),

            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyCardColors()
    }

    func render(item: VocabItem, showBack: Bool, dnd: Bool) {
        titleLabel.stringValue = item.front

        if item.type == .word, let p = item.phonetic, !p.isEmpty {
            phoneticLabel.stringValue = "音标: \(p)"
            phoneticLabel.isHidden = false
        } else {
            phoneticLabel.stringValue = ""
            phoneticLabel.isHidden = true
        }

        backLabel.stringValue = showBack ? item.back : ""
        backLabel.isHidden = !showBack

        if showBack, item.type == .word, let ex = item.examples.last {
            let zh = ex.zh.isEmpty ? "" : "\n\(ex.zh)"
            exampleLabel.stringValue = "例句: \(ex.en)\(zh)"
            exampleLabel.isHidden = false
        } else {
            exampleLabel.stringValue = ""
            exampleLabel.isHidden = true
        }

        let dndText = dnd ? "DND: ON" : "DND: OFF"
        hintLabel.stringValue = "Space 显示/隐藏释义 · N 下一条 · E 新例句 · D 切换勿扰 · Esc 关闭 · \(dndText)"
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if card.frame.contains(point) {
            onToggleBack?()
        } else {
            onDismiss?()
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: // space
            onToggleBack?()
        case 53: // esc
            onDismiss?()
        default:
            if let chars = event.charactersIgnoringModifiers?.lowercased() {
                if chars == "n" { onNext?(); return }
                if chars == "e" { onGenerateExample?(); return }
                if chars == "d" { onToggleDND?(); return }
            }
            super.keyDown(with: event)
        }
    }
}

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class OverlayController {
    private var panels: [OverlayPanel] = []
    private var views: [OverlayView] = []

    private var hideWorkItem: DispatchWorkItem?
    private var previousApp: NSRunningApplication?

    private(set) var currentItem: VocabItem?
    private(set) var showBack: Bool = false
    private(set) var mode: OverlayMode = .auto

    var onDismiss: (() -> Void)?
    var onNext: (() -> Void)?
    var onGenerateExample: (() -> Void)?
    var onToggleDND: (() -> Void)?

    func show(item: VocabItem, mode: OverlayMode, autoHideSeconds: TimeInterval?) {
        currentItem = item
        self.mode = mode
        showBack = false

        previousApp = NSWorkspace.shared.frontmostApplication

        ensurePanels()
        for v in views {
            v.render(item: item, showBack: showBack, dnd: AppConfig.shared.doNotDisturb)
        }

        for (idx, p) in panels.enumerated() {
            if idx == 0 {
                p.makeKeyAndOrderFront(nil)
            } else {
                p.orderFront(nil)
            }
        }
        NSApp.activate(ignoringOtherApps: true)

        scheduleAutoHide(seconds: autoHideSeconds)
    }

    func updateCurrentItem(_ item: VocabItem, revealBack: Bool? = nil) {
        currentItem = item
        if let revealBack {
            showBack = revealBack
        }
        for v in views {
            v.render(item: item, showBack: showBack, dnd: AppConfig.shared.doNotDisturb)
        }
    }

    func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        for p in panels { p.orderOut(nil) }
        currentItem = nil

        if let prev = previousApp {
            prev.activate(options: [])
        }
        previousApp = nil
    }

    func toggleBack() {
        guard let item = currentItem else { return }
        showBack.toggle()
        for v in views {
            v.render(item: item, showBack: showBack, dnd: AppConfig.shared.doNotDisturb)
        }
    }

    func refreshDND() {
        guard let item = currentItem else { return }
        for v in views {
            v.render(item: item, showBack: showBack, dnd: AppConfig.shared.doNotDisturb)
        }
    }

    private func scheduleAutoHide(seconds: TimeInterval?) {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        guard let seconds, seconds > 0 else { return }
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.hide()
                self?.onDismiss?()
            }
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func ensurePanels() {
        let screens = NSScreen.screens
        if panels.count == screens.count { return }

        panels.forEach { $0.close() }
        panels = []
        views = []

        for (idx, screen) in screens.enumerated() {
            let panel = OverlayPanel(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true

            let view = OverlayView(frame: screen.frame)
            view.onToggleBack = { [weak self] in self?.toggleBack() }
            view.onDismiss = { [weak self] in
                self?.hide()
                self?.onDismiss?()
            }
            view.onNext = { [weak self] in self?.onNext?() }
            view.onGenerateExample = { [weak self] in self?.onGenerateExample?() }
            view.onToggleDND = { [weak self] in self?.onToggleDND?() }

            panel.contentView = view
            if idx == 0 {
                panel.makeFirstResponder(view)
            }

            panels.append(panel)
            views.append(view)
        }
    }
}
