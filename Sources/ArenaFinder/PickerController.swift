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
    private let accountLabel = PanelStyle.label("Connect your account", color: .secondaryLabelColor)
    private let statusLabel = PanelStyle.label("", color: .secondaryLabelColor, wrapping: true)
    private let optionsButton = NSPopUpButton(frame: .zero, pullsDown: true)
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 330),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Are.na x Finder"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentView = PanelSurface(color: PanelStyle.background, radius: 0)
        super.init(window: window)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false

        let title = PanelStyle.label("Are.na x Finder", size: 20)
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let heading = NSStackView(views: [title, NSView(), optionsButton])
        heading.alignment = .centerY
        configureMenu()
        addRow(heading)
        addRow(accountLabel)

        tokenField.placeholderString = "Personal access token"
        tokenField.setAccessibilityLabel("Are.na personal access token")
        tokenField.heightAnchor.constraint(equalToConstant: 28).isActive = true
        connectButton = button("Connect", #selector(connect))
        let help = PanelStyle.label("Use a token with write access to upload from Finder. Your token is saved in Keychain.", wrapping: true)
        setup = PanelStyle.surface(around: column([help, tokenField,
            NSStackView(views: [button("Get access token", #selector(openTokens)), connectButton])]))
        addRow(setup)

        channelPicker.onChange = { [weak self] in self?.refresh() }
        finderButton = button("Add to Finder", #selector(showSelectedChannel))
        finderButton.keyEquivalent = "\r"
        finderButton.bezelColor = .controlAccentColor
        addButton = button("Add by URL…", #selector(addChannel))
        let actions = NSStackView(views: [finderButton, addButton])
        actions.spacing = 8
        channelPanel = PanelStyle.surface(around: column([
            PanelStyle.label("Channel", color: .secondaryLabelColor), channelPicker, actions
        ]))
        addRow(channelPanel)
        addRow(PanelStyle.label("Copy or drag files into a writable channel folder in Finder to upload.", wrapping: true))
        addRow(statusLabel)
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 48)
        ])
        refresh()
        Task {
            do { if let token = try TokenStore.read() { await authenticate(token) } }
            catch { message = error.localizedDescription; refresh() }
        }
    }

    required init?(coder: NSCoder) { nil }
    private var selected: Destination? { store.destinations.first { $0.id == channelPicker.selectedID } }
    private var finderChannels: [FinderChannel] { (try? ProviderPaths.configuration().channels) ?? [] }
    private var selectionIsInFinder: Bool { selected.map { choice in finderChannels.contains { $0.id == choice.channelID } } ?? false }

    private func configureMenu() {
        let menu = NSMenu(); menu.autoenablesItems = false; menu.delegate = self
        let title = NSMenuItem(title: "Options", action: nil, keyEquivalent: "")
        title.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Options")
        menu.addItem(title)
        refreshItem = menuItem("Refresh channels and Finder", #selector(refreshAll), in: menu)
        moreItem = menuItem("Load more channels…", #selector(loadMore), in: menu)
        menu.addItem(.separator())
        accountItem = menuItem("Account…", #selector(showAccount), in: menu)
        reviewItem = menuItem("Review interrupted uploads…", #selector(reviewFinderUploads), in: menu)
        optionsButton.menu = menu
        optionsButton.imagePosition = .imageOnly
        optionsButton.isBordered = false
        optionsButton.setAccessibilityLabel("Options")
        optionsButton.toolTip = "Account, refresh, and upload recovery"
        optionsButton.widthAnchor.constraint(equalToConstant: 32).isActive = true
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
        let directory = try? ProviderPaths.groupDirectory().appendingPathComponent("provider-live")
        let interrupted = directory.flatMap { try? ProviderEngine.interruptedUploads(in: $0) } ?? []
        reviewItem.isHidden = interrupted.isEmpty
        reviewItem.isEnabled = !loading
    }
    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
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
        accountLabel.stringValue = user.map { account in
            let count = finderChannels.count
            return "\(account.name) · \(count) \(count == 1 ? "folder" : "folders") in Finder"
        } ?? (loading ? "Connecting…" : "Connect your account")
        connectButton.isEnabled = !loading
        tokenField.isEnabled = !loading
        finderButton.title = selectionIsInFinder ? "Open in Finder" : "Add to Finder"
        finderButton.isEnabled = client != nil && selected != nil && !loading
        addButton.isEnabled = client != nil && !loading
        statusLabel.stringValue = message
        statusLabel.isHidden = message.isEmpty
        updateMenu()
        fitWindow()
    }
    @objc private func openTokens() { NSWorkspace.shared.open(URL(string: "https://www.are.na/settings/personal-access-tokens")!) }
    @objc private func showAccount() { setup.isHidden.toggle(); fitWindow() }
    @objc private func connect() {
        let token = tokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !loading else { return }
        Task { await authenticate(token) }
    }
    private func authenticate(_ token: String) async {
        guard !loading else { return }
        loading = true; client = nil; user = nil; message = ""; refresh()
        defer { loading = false; refresh() }
        do {
            let candidate = ArenaClient(token: token)
            let account = try await candidate.me()
            try FinderBridge.validateAccount(account.id)
            try store.setAccount(account.id)
            try TokenStore.save(token)
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
            message = errors.isEmpty ? "Up to date." : errors.joined(separator: "\n")
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
        alert.informativeText = "Paste an Are.na channel URL. Private and shared channels work when your account can access them."
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
