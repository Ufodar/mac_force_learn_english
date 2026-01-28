import Cocoa

@MainActor
final class WordbookWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let store: VocabStore

    private let searchField = NSSearchField(string: "")
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private let countLabel = NSTextField(labelWithString: "")

    private let tableView = NSTableView()
    private var allRows: [VocabItem] = []
    private var rows: [VocabItem] = []

    private var storeObserver: NSObjectProtocol?

    init(store: VocabStore) {
        self.store = store

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Wordbook"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        buildUI()
        reloadData()

        storeObserver = NotificationCenter.default.addObserver(
            forName: .vocabStoreDidChange,
            object: store,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reloadData()
            }
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let obs = storeObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    func show() {
        if let w = window {
            w.center()
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true

        searchField.placeholderString = "Search word / meaning"
        searchField.target = self
        searchField.action = #selector(onSearchChanged)

        refreshButton.target = self
        refreshButton.action = #selector(onRefresh)
        refreshButton.bezelStyle = .rounded

        countLabel.textColor = .secondaryLabelColor
        countLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)

        let toolbar = NSStackView(views: [searchField, refreshButton, countLabel])
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 10
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        let wordCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("word"))
        wordCol.title = "Word"
        wordCol.width = 160

        let ipaCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ipa"))
        ipaCol.title = "IPA"
        ipaCol.width = 140

        let meaningCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("meaning"))
        meaningCol.title = "Meaning"
        meaningCol.width = 420

        tableView.addTableColumn(wordCol)
        tableView.addTableColumn(ipaCol)
        tableView.addTableColumn(meaningCol)
        tableView.headerView = NSTableHeaderView()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 26
        tableView.allowsMultipleSelection = false

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(toolbar)
        content.addSubview(scroll)

        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            toolbar.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),

            searchField.widthAnchor.constraint(equalToConstant: 320),

            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 10),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    @objc private func onRefresh() {
        reloadData()
    }

    @objc private func onSearchChanged() {
        applyFilter()
        tableView.reloadData()
        updateCountLabel()
    }

    private func reloadData() {
        allRows = lookupWordsSorted()
        applyFilter()
        tableView.reloadData()
        updateCountLabel()
    }

    private func applyFilter() {
        let q = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty {
            rows = allRows
            return
        }
        rows = allRows.filter { item in
            item.front.lowercased().contains(q) || item.back.lowercased().contains(q)
        }
    }

    private func updateCountLabel() {
        if searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            countLabel.stringValue = "\(rows.count) words"
        } else {
            countLabel.stringValue = "\(rows.count)/\(allRows.count)"
        }
    }

    private func lookupWordsSorted() -> [VocabItem] {
        store.data.items
            .filter { $0.type == .word && (($0.source ?? "") == "lookup" || ($0.category ?? "") == "lookup") }
            .sorted { a, b in
                let da = a.lastShownAt ?? a.createdAt
                let db = b.lastShownAt ?? b.createdAt
                return da > db
            }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn else { return nil }
        let item = rows[row]
        let id = tableColumn.identifier

        let field: NSTextField
        if let reused = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField {
            field = reused
        } else {
            field = NSTextField(labelWithString: "")
            field.identifier = id
            field.lineBreakMode = .byTruncatingTail
        }

        switch id.rawValue {
        case "word":
            field.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
            field.stringValue = item.front
        case "ipa":
            field.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            field.textColor = .secondaryLabelColor
            field.stringValue = item.phonetic ?? ""
        default:
            field.font = NSFont.systemFont(ofSize: 13, weight: .regular)
            field.textColor = .labelColor
            field.stringValue = item.back
        }

        return field
    }
}
