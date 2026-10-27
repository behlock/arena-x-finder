import AppKit
import ArenaCore

@MainActor
final class PickerController: NSWindowController {
    private let store: Store
    private let uploader: Uploader
    private var urls: [URL]
    private var client: ArenaClient?
    private var user: ArenaUser?
    private var nextPage: Int?
    private var loading = false
    private var submitted = false
    private var message = "Connect your Are.na account to get started."
    private var skipped: [String] = []
    private let stack = NSStackView()
    private let tokenField = NSSecureTextField()
    private let channelPicker = DestinationPicker()
    private let sendButton = CircularSendButton(title: "Send", target: nil, action: nil)
    private let statusLabel = PanelStyle.label("", color: .secondaryLabelColor, wrapping: true)
    private let accountLabel = PanelStyle.label("Are.na x Finder", size: 18)
    private var setup: NSView!
    private var preview: ImagePreviewStrip?
    private var accountButton: NSButton!
    private var connectButton: NSButton!
    private var refreshButton: NSButton!
    private var moreButton: NSButton!
    private var addButton: NSButton!
    private var resumeButton: NSButton!
    private var discardButton: NSButton!
    private var reviewButton: NSButton!
    private var queueLabel = PanelStyle.label("", color: .secondaryLabelColor, wrapping: true)

    init(store: Store, uploader: Uploader, urls: [URL]) {
        self.store = store; self.uploader = uploader; self.urls = urls
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 480),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Are.na x Finder"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentView = PanelSurface(color: PanelStyle.background, radius: 0)
        super.init(window: window)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        accountButton = button("Account…", #selector(showAccount))
        addRow(NSStackView(views: [accountLabel, accountButton]))
        if !urls.isEmpty {
            let preview = ImagePreviewStrip(urls: urls)
            preview.onSizeChange = { [weak self] in self?.fitWindow() }
            preview.onRemove = { [weak self] index in
                guard let self, !self.busy, !self.submitted else { return }
                self.urls.remove(at: index); self.refresh()
            }
            self.preview = preview; addRow(preview)
        }
        tokenField.placeholderString = "Personal access token (write access)"
        tokenField.setAccessibilityLabel("Are.na personal access token")
        tokenField.heightAnchor.constraint(equalToConstant: 28).isActive = true
        connectButton = button("Connect", #selector(connect))
        let help = PanelStyle.label("Create a token with write access, then paste it here. It is saved in your Mac’s Keychain.", wrapping: true)
        let setupStack = column([help, tokenField, NSStackView(views: [button("Get access token ↗", #selector(openTokens)), connectButton])])
        setup = PanelStyle.surface(around: setupStack); addRow(setup)
        channelPicker.onChange = { [weak self] in self?.refresh() }
        sendButton.target = self; sendButton.action = #selector(send)
        sendButton.keyEquivalent = "\r"; sendButton.isBordered = false
        sendButton.setAccessibilityLabel("Send images to Are.na")
        sendButton.widthAnchor.constraint(equalToConstant: 54).isActive = true
        sendButton.heightAnchor.constraint(equalToConstant: 54).isActive = true
        let sendRow = NSStackView(views: [channelPicker, sendButton])
        sendRow.spacing = 12; sendRow.alignment = .centerY
        channelPicker.widthAnchor.constraint(equalTo: sendRow.widthAnchor, constant: -66).isActive = true
        addRow(PanelStyle.surface(around: sendRow))
        refreshButton = button("Refresh", #selector(reloadChannels))
        moreButton = button("Load more", #selector(loadMore))
        addButton = button("Add channel URL…", #selector(addChannel))
        addRow(NSStackView(views: [refreshButton, moreButton, addButton]))
        addRow(statusLabel)
        addRow(queueLabel)
        resumeButton = button("Resume", #selector(resume))
        reviewButton = button("Review upload…", #selector(review))
        discardButton = button("Discard batch…", #selector(discard))
        addRow(NSStackView(views: [resumeButton, reviewButton, discardButton]))
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 48)
        ])
        uploader.onChange = { [weak self] in
            guard let self else { return }
            if !self.uploader.status.isEmpty { self.message = self.uploader.status }
            self.refresh()
        }
        refresh()
        Task {
            do { if let token = try TokenStore.read() { await authenticate(token) } }
            catch { message = error.localizedDescription; refresh() }
        }
    }

    required init?(coder: NSCoder) { nil }
    private var busy: Bool { loading || store.isPreparingImages || uploader.isRunning }
    private var selected: Destination? { store.destinations.first { $0.id == channelPicker.selectedID } }
    private var uncertain: (Job, QueuedImage)? {
        for job in store.jobs {
            if let image = job.images.first(where: { job.creating.contains($0.id) && job.blockIDs[$0.id] == nil && !job.completed.contains($0.id) }) { return (job, image) }
        }
        return nil
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }
    private func column(_ views: [NSView]) -> NSStackView {
        let result = NSStackView(views: views)
        result.orientation = .vertical; result.alignment = .leading; result.spacing = 10
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
        window?.center()
        super.showWindow(sender)
    }

    private func refresh() {
        channelPicker.update(store.destinations, rememberedID: store.lastDestinationID)
        channelPicker.isEnabled = client != nil && !busy && !submitted
        preview?.allowsRemoval = !busy && !submitted
        sendButton.isEnabled = client != nil && selected != nil && !urls.isEmpty && !busy && !submitted && store.jobs.isEmpty
        sendButton.phase = uploader.isRunning || store.isPreparingImages ? .sending : .ready
        accountLabel.stringValue = user.map { "Connected as \($0.name)" } ?? "Are.na x Finder"
        accountLabel.font = .systemFont(ofSize: user == nil ? 18 : 14, weight: .medium)
        accountButton.isEnabled = !busy
        connectButton.isEnabled = !busy
        tokenField.isEnabled = !busy
        refreshButton.isEnabled = client != nil && !busy
        moreButton.isEnabled = client != nil && nextPage != nil && !busy
        addButton.isEnabled = client != nil && !busy
        resumeButton.isEnabled = client != nil && !busy && !store.jobs.isEmpty && uncertain == nil
        reviewButton.isHidden = uncertain == nil
        reviewButton.isEnabled = !busy
        discardButton.isEnabled = !busy && !store.jobs.isEmpty
        let queued = store.jobs.reduce(0) { $0 + $1.images.count - $1.completed.count }
        queueLabel.stringValue = queued == 0 ? "" : "\(queued) image(s) queued. Next: \(store.jobs.first!.destination.name)."
        queueLabel.isHidden = queued == 0
        statusLabel.stringValue = uploader.isRunning ? uploader.status : message
        if !skipped.isEmpty { statusLabel.stringValue += "\nSkipped: " + skipped.joined(separator: "\n") }
        fitWindow()
    }

    @objc private func openTokens() { NSWorkspace.shared.open(URL(string: "https://www.are.na/settings/personal-access-tokens")!) }
    @objc private func showAccount() { setup.isHidden.toggle(); fitWindow() }
    @objc private func connect() {
        let token = tokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !busy else { return }
        Task { await authenticate(token) }
    }
    private func authenticate(_ token: String) async {
        guard !loading else { return }
        loading = true; client = nil; user = nil; message = "Connecting…"; refresh()
        defer { loading = false; refresh() }
        do {
            let candidate = ArenaClient(token: token)
            let account = try await candidate.me()
            try store.setAccount(account.id)
            try TokenStore.save(token)
            client = candidate; user = account
            tokenField.stringValue = ""; setup.isHidden = true
            message = urls.isEmpty ? "Select images in Finder, then choose Services → Send to Are.na." : "Choose a channel and send."
            try await fetchChannels(page: 1)
        } catch { message = error.localizedDescription }
    }
    private func fetchChannels(page: Int) async throws {
        guard let client, let user else { return }
        let result = try await client.channels(userID: user.id, page: page)
        for channel in result.data where channel.can?.add_to != false { try store.save(channel.destination) }
        nextPage = result.meta.next_page
        if store.destinations.isEmpty { message = "No channels loaded. Add a channel URL, or load the next page." }
    }
    @objc private func reloadChannels() { loadChannels(page: 1) }
    @objc private func loadMore() { if let nextPage { loadChannels(page: nextPage) } }
    private func loadChannels(page: Int) {
        guard !busy else { return }
        loading = true; refresh()
        Task {
            do { try await fetchChannels(page: page); message = "Channels updated." }
            catch { message = error.localizedDescription }
            loading = false; refresh()
        }
    }
    @objc private func addChannel() {
        guard !busy, let client, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Add an Are.na channel"
        alert.informativeText = "Paste a channel URL or slug. This also works for shared channels you can add to."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 26))
        alert.accessoryView = field
        alert.addButton(withTitle: "Add"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let input = field.stringValue
            self.loading = true; self.refresh()
            Task { @MainActor in
                do {
                    let channel = try await client.channel(input)
                    guard channel.can?.add_to == true else { throw BridgeError.message("You don’t have permission to add to this channel.") }
                    try self.store.save(channel.destination)
                    self.message = "Added \(channel.title)."
                } catch { self.message = error.localizedDescription }
                self.loading = false; self.refresh()
            }
        }
        window.makeFirstResponder(field)
    }
    @objc private func send() {
        guard !busy, !submitted, store.jobs.isEmpty, let client, let user, let destination = selected, !urls.isEmpty else { return }
        loading = true; message = "Preparing images…"; refresh()
        Task {
            do {
                let channel = try await client.channel(destination.slug)
                guard channel.id == destination.channelID, channel.can?.add_to == true else {
                    throw BridgeError.message("You can no longer add to this channel. Choose another destination.")
                }
                let result = try await store.enqueue(urls, destination: destination)
                submitted = true; skipped = result.skipped; loading = false
                await uploader.run(client: client, accountID: user.id, jobID: result.job.id)
            } catch { message = error.localizedDescription }
            loading = false; refresh()
        }
    }
    @objc private func resume() {
        guard !busy, uncertain == nil, let client, let user else { return }
        Task { await uploader.run(client: client, accountID: user.id); refresh() }
    }
    @objc private func review() {
        guard !busy, let (job, image) = uncertain, let window else { return }
        NSWorkspace.shared.open(job.destination.url)
        let alert = NSAlert()
        alert.messageText = "Was \(image.name) added?"
        alert.informativeText = "Check \(job.destination.name) in Are.na. The connection was interrupted before we could save the result. Only retry if the image is missing."
        alert.addButton(withTitle: "Already added"); alert.addButton(withTitle: "Missing — allow retry"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            do {
                if response == .alertFirstButtonReturn { try self.store.acknowledge(jobID: job.id, imageID: image.id) }
                else if response == .alertSecondButtonReturn { try self.store.updateJob(job.id) { $0.creating.remove(image.id); $0.lastError = nil } }
            } catch { self.message = error.localizedDescription }
            self.refresh()
        }
    }
    @objc private func discard() {
        guard !busy, let job = store.jobs.first, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Discard the queued batch for \(job.destination.name)?"
        alert.informativeText = "This removes the local queued copies. Your original files and blocks already added to Are.na stay in place."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Discard batch")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertSecondButtonReturn else { return }
            do { try self.store.discard(jobID: job.id); self.message = "Queued batch discarded." }
            catch { self.message = error.localizedDescription }
            self.refresh()
        }
    }
}
