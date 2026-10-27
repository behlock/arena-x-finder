import AppKit
import ArenaCore
import ArenaProvider

/// Manages Finder locations. File transfers belong to the File Provider.
@MainActor
final class PickerController: NSWindowController, NSMenuDelegate {
    private let store: Store
    private var client: ArenaClient?
    private var user: ArenaUser?
    private var nextPage: Int?
    private var loading = false
    private var message = ""
    private let stack = NSStackView()
    private let tokenField = NSSecureTextField()
    private let channelPicker = DestinationPicker()
    private let statusLabel = PanelStyle.label("", color: .secondaryLabelColor, wrapping: true)
    private let optionsButton = PointingHandButton(frame: .zero)
    private let optionsMenu = NSMenu()
    private var footer: NSView!
    private var setup: NSView!
    private var channelPanel: NSView!
    private var connectButton: NSButton!
    private var finderButton: NSButton!
    private var addButton: NSButton!
    private var refreshItem: NSMenuItem!
    private var moreItem: NSMenuItem!
    private var reviewItem: NSMenuItem!
    private var accountItem: NSMenuItem!

    init(store: Store) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 180),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Are.na x Finder"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentView = PanelSurface(color: PanelStyle.background, radius: 0)
        super.init(window: window)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false

        configureMenu()

        tokenField.placeholderString = "Personal access token"
        tokenField.setAccessibilityLabel("Are.na personal access token")
        tokenField.heightAnchor.constraint(equalToConstant: 30).isActive = true
        connectButton = button("Connect", #selector(connect))
        let help = PanelStyle.label("Connect to Are.na", size: 17)
        setup = PanelStyle.surface(around: column([help, tokenField,
            NSStackView(views: [button("Get token", #selector(openTokens)), connectButton])]))
        addRow(setup)

        channelPicker.onChange = { [weak self] in self?.refresh() }
        finderButton = button("Add to Finder", #selector(showSelectedChannel))
        finderButton.keyEquivalent = "\r"
        finderButton.contentTintColor = .systemBlue
        addButton = button("Add by URL…", #selector(addChannel))
        channelPicker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        channelPicker.setContentHuggingPriority(.defaultLow, for: .horizontal)
        finderButton.widthAnchor.constraint(equalToConstant: 138).isActive = true
        let channelRow = NSStackView(views: [channelPicker, finderButton])
        channelRow.alignment = .centerY
        channelRow.spacing = 8
        channelPicker.widthAnchor.constraint(equalTo: channelRow.widthAnchor, constant: -146).isActive = true
        channelPanel = PanelStyle.surface(around: channelRow)
        addRow(channelPanel)
        addButton.font = .systemFont(ofSize: 12)
        addButton.contentTintColor = .secondaryLabelColor
        addButton.widthAnchor.constraint(equalToConstant: 112).isActive = true
        let footerRow = NSStackView(views: [addButton, NSView(), optionsButton])
        footerRow.alignment = .centerY
        footer = footerRow
        addRow(footerRow)
        addRow(statusLabel)
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 48)
        ])
        refresh()
        Task {
            do { if let token = try TokenStore.read() { await authenticate(token, saveToken: false) } }
            catch { message = error.localizedDescription; refresh() }
        }
    }

    required init?(coder: NSCoder) { nil }
    private var selected: Destination? { store.destinations.first { $0.id == channelPicker.selectedID } }
    private var finderChannels: [FinderChannel] { (try? ProviderPaths.configuration().channels) ?? [] }
    private var selectionIsInFinder: Bool { selected.map { choice in finderChannels.contains { $0.id == choice.channelID } } ?? false }

    private func configureMenu() {
        let menu = optionsMenu
        menu.autoenablesItems = false; menu.delegate = self
        refreshItem = menuItem("Refresh", #selector(refreshAll), in: menu)
        moreItem = menuItem("Load more channels…", #selector(loadMore), in: menu)
        menu.addItem(.separator())
        accountItem = menuItem("Account…", #selector(showAccount), in: menu)
        reviewItem = menuItem("Review interrupted uploads…", #selector(reviewFinderUploads), in: menu)
        optionsButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Options")
        optionsButton.imagePosition = .imageOnly
        optionsButton.isBordered = false
        optionsButton.target = self
        optionsButton.action = #selector(showOptions)
        optionsButton.contentTintColor = .secondaryLabelColor
        optionsButton.setAccessibilityLabel("Options")
        optionsButton.toolTip = "Account and refresh"
        optionsButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        optionsButton.heightAnchor.constraint(equalToConstant: 28).isActive = true
    }
    @objc private func showOptions() {
        optionsMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: optionsButton.bounds.maxY + 4), in: optionsButton)
    }
    private func menuItem(_ title: String, _ action: Selector, in menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self; menu.addItem(item); return item
    }
    func menuWillOpen(_ menu: NSMenu) { updateMenu() }
    private func updateMenu() {
        refreshItem.isEnabled = client != nil && !loading
        moreItem.isHidden = nextPage == nil
        moreItem.isEnabled = client != nil && !loading
        accountItem.isEnabled = !loading
        accountItem.title = user.map { "Account: \($0.name)…" } ?? "Account…"
        let directory = try? ProviderPaths.groupDirectory().appendingPathComponent("provider-live")
        let interrupted = directory.flatMap { try? ProviderEngine.interruptedUploads(in: $0) } ?? []
        reviewItem.isHidden = interrupted.isEmpty
        reviewItem.isEnabled = !loading
    }
    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = PanelPillButton(frame: .zero)
        button.title = title; button.target = self; button.action = action
        button.font = .systemFont(ofSize: 14)
        button.heightAnchor.constraint(equalToConstant: 38).isActive = true
        return button
    }
    private func column(_ views: [NSView]) -> NSStackView {
        let result = NSStackView(views: views)
        result.orientation = .vertical; result.alignment = .leading; result.spacing = 12
        views.forEach { $0.widthAnchor.constraint(equalTo: result.widthAnchor).isActive = true }
        return result
    }
    private func addRow(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    private func fitWindow() {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let height = ceil(stack.fittingSize.height) + 72
        var frame = window.frame
        let delta = height - content.bounds.height
        frame.size.height += delta; frame.origin.y -= delta / 2
        window.setFrame(frame, display: true)
    }
    override func showWindow(_ sender: Any?) {
        refresh()
        window?.center()
        super.showWindow(sender)
    }
    private func refresh() {
        channelPicker.update(store.destinations, rememberedID: store.lastDestinationID)
        channelPicker.isEnabled = client != nil && !loading
        channelPanel.isHidden = client == nil
        setup.isHidden = client != nil || loading
        footer.isHidden = client == nil
        connectButton.isEnabled = !loading
        tokenField.isEnabled = !loading
        finderButton.title = selectionIsInFinder ? "Open in Finder" : "Add to Finder"
        finderButton.isEnabled = client != nil && selected != nil && !loading
        addButton.isEnabled = client != nil && !loading
        statusLabel.stringValue = client == nil && loading ? "Connecting…" : message
        statusLabel.isHidden = statusLabel.stringValue.isEmpty
        updateMenu()
        fitWindow()
    }
    @objc private func openTokens() { NSWorkspace.shared.open(URL(string: "https://www.are.na/settings/personal-access-tokens")!) }
    @objc private func showAccount() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Are.na account"
        alert.informativeText = "Enter a new token to reconnect."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 28))
        field.placeholderString = "Personal access token"
        field.setAccessibilityLabel("Are.na personal access token")
        alert.accessoryView = field
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Get token")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertThirdButtonReturn { self.openTokens(); return }
            guard response == .alertFirstButtonReturn else { return }
            let token = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { return }
            Task { await self.authenticate(token) }
        }
        window.makeFirstResponder(field)
    }
    @objc private func connect() {
        let token = tokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !loading else { return }
        Task { await authenticate(token) }
    }
    private func authenticate(_ token: String, saveToken: Bool = true) async {
        guard !loading else { return }
        loading = true; client = nil; user = nil; message = ""; refresh()
        defer { loading = false; refresh() }
        do {
            let candidate = ArenaClient(token: token)
            let account = try await candidate.me()
            try FinderBridge.validateAccount(account.id)
            try store.setAccount(account.id)
            if saveToken { try TokenStore.save(token) }
            client = candidate; user = account
            tokenField.stringValue = ""; setup.isHidden = true
            try await fetchChannels(page: 1)
        } catch { message = error.localizedDescription }
    }
    private func fetchChannels(page: Int) async throws {
        guard let client, let user else { return }
        let result = try await client.channels(userID: user.id, page: page)
        for channel in result.data { try store.save(channel.destination) }
        nextPage = result.meta.next_page
        if store.destinations.isEmpty { message = "No channels found. Add one by URL." }
    }
    @objc private func showSelectedChannel() {
        guard !loading, let client, let user, let selected else { return }
        let alreadyAdded = selectionIsInFinder
        loading = true; message = alreadyAdded ? "Opening folder…" : "Adding folder…"; refresh()
        Task {
            do {
                if alreadyAdded { try await FinderBridge.revealChannel(selected.channelID) }
                else {
                    let channel = try await client.channel(selected.slug)
                    try await FinderBridge.addChannel(channel, accountID: user.id)
                }
                message = ""
            } catch { message = error.localizedDescription }
            loading = false; refresh()
        }
    }
    @objc private func refreshAll() {
        guard !loading, client != nil else { return }
        loading = true; message = "Refreshing…"; refresh()
        Task {
            var errors: [String] = []
            do { try await fetchChannels(page: 1) } catch { errors.append(error.localizedDescription) }
            if !finderChannels.isEmpty {
                do { try await FinderBridge.refresh() } catch { errors.append(error.localizedDescription) }
            }
            message = errors.isEmpty ? "" : errors.joined(separator: "\n")
            loading = false; refresh()
        }
    }
    @objc private func reviewFinderUploads() {
        guard let window else { return }
        do { try FinderBridge.reviewUploads(window: window) }
        catch { message = error.localizedDescription; refresh() }
    }
    @objc private func loadMore() {
        guard !loading, let nextPage else { return }
        loading = true; message = "Loading channels…"; refresh()
        Task {
            do { try await fetchChannels(page: nextPage); message = "" }
            catch { message = error.localizedDescription }
            loading = false; refresh()
        }
    }
    @objc private func addChannel() {
        guard !loading, let client, let user, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Add a channel to Finder"
        alert.informativeText = "Paste an Are.na channel URL."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 26))
        field.placeholderString = "https://www.are.na/…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Add to Finder"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let input = field.stringValue
            self.loading = true; self.message = "Adding folder…"; self.refresh()
            Task { @MainActor in
                do {
                    let channel = try await client.channel(input)
                    try self.store.save(channel.destination)
                    self.channelPicker.update(self.store.destinations, rememberedID: self.store.lastDestinationID)
                    self.channelPicker.select(channel.destination.id)
                    try await FinderBridge.addChannel(channel, accountID: user.id)
                    self.message = ""
                } catch { self.message = error.localizedDescription }
                self.loading = false; self.refresh()
            }
        }
        window.makeFirstResponder(field)
    }
}
