import AppKit
import ServiceManagement

enum UsageRing: String, CaseIterable {
    case codex, claude

    var title: String { self == .codex ? "Codex" : "Claude" }

    var loginCommand: String { self == .codex ? "codex login" : "claude auth login" }

    var icon: NSImage? {
        let name = self == .codex ? "CodexLogo" : "ClaudeLogo"
        let fileExtension = self == .codex ? "png" : "svg"
        return Bundle.main.url(forResource: name, withExtension: fileExtension).flatMap(NSImage.init(contentsOf:))
    }

    func limits(codex: UsagePresentation, claude: UsagePresentation) -> BaseLimits {
        (self == .codex ? codex : claude).snapshot?.baseLimits ?? BaseLimits()
    }

    func hasUnstartedWindow(_ bucket: LimitBucket) -> Bool {
        self == .claude && bucket.windowMinutes == 300 && bucket.usedPercent == 0 && bucket.resetAt == nil
    }
}

final class RingSettings {
    private let defaults: UserDefaults
    private let key = "enabledUsageProviders"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var resetNotificationsEnabled: Bool {
        get { defaults.object(forKey: "resetNotificationsEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "resetNotificationsEnabled") }
    }

    var enabled: [UsageRing] {
        guard let values = defaults.stringArray(forKey: key) else {
            guard let legacy = defaults.stringArray(forKey: "enabledUsageRings") else { return UsageRing.allCases }
            let migrated = UsageRing.allCases.filter { provider in legacy.contains { $0.hasPrefix(provider.rawValue) } }
            defaults.set(migrated.map(\.rawValue), forKey: key)
            return migrated
        }
        return UsageRing.allCases.filter { values.contains($0.rawValue) }
    }

    func set(_ ring: UsageRing, enabled: Bool) {
        var selection = self.enabled
        selection.removeAll { $0 == ring }
        if enabled { selection.append(ring) }
        defaults.set(selection.map(\.rawValue), forKey: key)
    }

    func visible(codex: UsagePresentation, claude: UsagePresentation) -> [UsageRing] {
        enabled.filter { ($0 == .codex ? codex : claude).hasSignIn }
    }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let settings: RingSettings
    private let formWidth: CGFloat = 472
    private let contentStack = NSStackView()
    private let loginButton = NSSwitch()
    private let loginReviewButton = NSButton(title: "Review…", target: nil, action: nil)
    private let notificationsButton = NSSwitch()
    private let notificationsStatus = NSTextField(wrappingLabelWithString: "")
    private let updateButton = NSButton(title: "Check for Updates…", target: nil, action: nil)
    private let guideButton = NSButton(title: "Ring guide", target: nil, action: nil)
    private let guidePopover = NSPopover()
    var onChange: (() -> Void)?
    var onCheckForUpdates: (() -> Void)?

    init(settings: RingSettings) {
        self.settings = settings
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 540),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Uso Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        configureControls()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 22
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let providerRows = UsageRing.allCases.enumerated().map { index, provider in
            let toggle = NSSwitch()
            toggle.target = self
            toggle.action = #selector(toggleRing(_:))
            toggle.controlSize = .small
            toggle.tag = index
            toggle.state = settings.enabled.contains(provider) ? .on : .off
            toggle.setAccessibilityLabel("Show \(provider.title) in menu bar")
            toggle.toolTip = "Show \(provider.title) usage in the menu bar."
            let image = provider.icon
            return settingRow(title: provider.title, detail: nil, image: image, control: toggle)
        }
        contentStack.addArrangedSubview(section("Menu bar", rows: providerRows, footer: nil, accessory: guideButton))

        let notificationRow = settingRow(title: "Limit reset alerts",
                                         detail: nil,
                                         image: symbol("bell.badge"), control: notificationsButton)
        styleCaption(notificationsStatus)
        notificationsStatus.isHidden = true
        contentStack.addArrangedSubview(section("Notifications", rows: [notificationRow], footer: notificationsStatus, accessory: nil))

        let loginControls = NSStackView(views: [loginReviewButton, loginButton])
        loginControls.spacing = 10
        loginControls.detachesHiddenViews = true
        let loginRow = settingRow(title: "Open at login", detail: nil,
                                  image: symbol("power"), control: loginControls)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let updateRow = settingRow(title: "Software updates",
                                   detail: NSTextField(wrappingLabelWithString: version.map { "Version \($0)" } ?? "Development build"),
                                   image: symbol("arrow.triangle.2.circlepath"), control: updateButton)
        contentStack.addArrangedSubview(section("General", rows: [loginRow, updateRow], footer: nil, accessory: nil))

        if let content = window.contentView {
            content.addSubview(contentStack)
            NSLayoutConstraint.activate([
                contentStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
                contentStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
                contentStack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            ])
        }
        updateLoginStatus()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    private func configureControls() {
        loginButton.target = self
        loginButton.controlSize = .small
        loginButton.action = #selector(toggleStartAtLogin(_:))
        loginButton.setAccessibilityLabel("Open Uso at login")
        loginReviewButton.target = self
        loginReviewButton.action = #selector(reviewLoginItemsPressed)
        loginReviewButton.bezelStyle = .rounded
        loginReviewButton.controlSize = .small
        loginReviewButton.isHidden = true
        notificationsButton.target = self
        notificationsButton.controlSize = .small
        notificationsButton.action = #selector(toggleNotifications(_:))
        notificationsButton.state = settings.resetNotificationsEnabled ? .on : .off
        notificationsButton.setAccessibilityLabel("Notify about usage resets")
        notificationsButton.setAccessibilityHelp("Notify when Codex or Claude has more usage available, or when new Codex reset credits arrive.")
        updateButton.target = self
        updateButton.action = #selector(checkForUpdatesPressed)
        updateButton.bezelStyle = .rounded
        updateButton.controlSize = .small
        updateButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        updateButton.isEnabled = false
        guideButton.target = self
        guideButton.action = #selector(showRingGuide(_:))
        guideButton.isBordered = false
        guideButton.font = .systemFont(ofSize: 11)
        guideButton.contentTintColor = .secondaryLabelColor
        guideButton.image = symbol("questionmark.circle")
        guideButton.imagePosition = .imageLeading
        guideButton.imageHugsTitle = true
    }

    func present() {
        updateLoginStatus()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func updateUpdaterAvailability(_ canCheck: Bool) {
        updateButton.isEnabled = canCheck
    }

    func updateNotificationStatus(_ text: String?) {
        notificationsButton.state = settings.resetNotificationsEnabled ? .on : .off
        let message = text ?? ""
        guard notificationsStatus.stringValue != message else { return }
        notificationsStatus.stringValue = message
        notificationsStatus.isHidden = message.isEmpty
        resizeToFitContent()
    }

    private func section(_ title: String, rows: [NSView], footer: NSTextField?, accessory: NSView?) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        let headingRow = NSStackView(views: [heading, NSView()] + (accessory.map { [$0] } ?? []))
        headingRow.alignment = .centerY
        headingRow.widthAnchor.constraint(equalToConstant: formWidth).isActive = true
        let stack = NSStackView(views: [headingRow, groupedRows(rows)] + (footer.map { [$0] } ?? []))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.detachesHiddenViews = true
        stack.widthAnchor.constraint(equalToConstant: formWidth).isActive = true
        return stack
    }

    private func groupedRows(_ rows: [NSView]) -> NSView {
        var views: [NSView] = []
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let divider = NSBox()
                divider.boxType = .separator
                views.append(divider)
            }
            views.append(row)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let box = NSBox()
        box.boxType = .custom
        box.fillColor = .controlBackgroundColor
        box.borderColor = .separatorColor.withAlphaComponent(0.45)
        box.borderWidth = 0.5
        box.cornerRadius = 10
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: formWidth),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -12),
        ])
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return box
    }

    private func settingRow(title: String, detail: NSTextField?, image: NSImage?, control: NSView) -> NSView {
        let icon = NSImageView()
        icon.image = image
        icon.contentTintColor = .secondaryLabelColor
        icon.imageScaling = .scaleProportionallyDown
        icon.setAccessibilityElement(false)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),
        ])
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        let text = NSStackView(views: [label] + (detail.map { [$0] } ?? []))
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if let detail {
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .secondaryLabelColor
            detail.preferredMaxLayoutWidth = 320
            detail.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
        }
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let row = NSStackView(views: [icon, text, spacer, control])
        row.distribution = .fill
        row.alignment = .centerY
        row.spacing = 12
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
        return row
    }

    private func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
    }

    private func styleCaption(_ field: NSTextField) {
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        field.preferredMaxLayoutWidth = formWidth
        field.widthAnchor.constraint(equalToConstant: formWidth).isActive = true
    }

    private func resizeToFitContent() {
        guard let window else { return }
        window.contentView?.layoutSubtreeIfNeeded()
        let size = NSSize(width: 520, height: ceil(contentStack.fittingSize.height) + 48)
        if window.contentView?.frame.size != size { window.setContentSize(size) }
    }

    @objc private func toggleNotifications(_ sender: NSSwitch) {
        settings.resetNotificationsEnabled = sender.state == .on
        onChange?()
    }

    @objc private func checkForUpdatesPressed() { onCheckForUpdates?() }

    @objc private func reviewLoginItemsPressed() { SMAppService.openSystemSettingsLoginItems() }

    func windowDidBecomeKey(_ notification: Notification) {
        updateLoginStatus()
    }

    private func updateLoginStatus() {
        loginReviewButton.isHidden = true
        if !legacyLoginItems.isEmpty || SMAppService.mainApp.status == .enabled {
            loginButton.state = .on
            loginButton.toolTip = "Opens automatically when you sign in."
        } else if SMAppService.mainApp.status == .requiresApproval {
            loginButton.state = .on
            loginButton.toolTip = "Approval required in System Settings."
            loginReviewButton.isHidden = false
        } else {
            loginButton.state = .off
            loginButton.toolTip = "Open Uso automatically when you sign in."
        }
        resizeToFitContent()
    }

    @objc private func showRingGuide(_ sender: NSButton) {
        if guidePopover.isShown { guidePopover.close(); return }
        let heading = NSTextField(labelWithString: "Reading the rings")
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        let limits = BaseLimits(fiveHour: LimitBucket(usedPercent: 20, windowMinutes: 300, resetAt: Date().addingTimeInterval(14400).timeIntervalSince1970),
                                weekly: LimitBucket(usedPercent: 20, windowMinutes: 10080, resetAt: Date().addingTimeInterval(483840).timeIntervalSince1970))
        let rings = NSImageView(image: RingRenderer.statusImage(limits: [limits]))
        rings.imageScaling = .scaleProportionallyUpOrDown
        rings.setAccessibilityLabel("\(BaseLimitRole.weekly.title) on the outer ring, \(BaseLimitRole.fiveHour.title) on the inner ring")
        NSLayoutConstraint.activate([
            rings.widthAnchor.constraint(equalToConstant: 44),
            rings.heightAnchor.constraint(equalToConstant: 44),
        ])
        let ringLabels = NSStackView(views: [NSTextField(labelWithString: "Outer ring · \(BaseLimitRole.weekly.title)"), NSTextField(labelWithString: "Inner ring · \(BaseLimitRole.fiveHour.title)")])
        ringLabels.orientation = .vertical
        ringLabels.alignment = .leading
        ringLabels.spacing = 3
        let ringRow = NSStackView(views: [rings, ringLabels])
        ringRow.spacing = 12
        let explanation = NSTextField(wrappingLabelWithString: "Colors compare your usage with the time elapsed in each window.")
        explanation.font = .systemFont(ofSize: 12)
        explanation.textColor = .secondaryLabelColor
        explanation.preferredMaxLayoutWidth = 286
        let stack = NSStackView(views: [heading, ringRow, explanation])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        for (title, detail, color) in [
            ("Green · On pace", "Within the allowance for the time elapsed.", NSColor.systemGreen),
            ("Yellow · Slightly over pace", "Up to 5 percentage points ahead.", NSColor.systemYellow),
            ("Red · Over pace or exhausted", "More than 5 points ahead, or no usage left.", NSColor.systemRed),
            ("Gray · Pace unavailable", "Timing information is not available.", NSColor.secondaryLabelColor),
        ] {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.textColor = color
            let description = NSTextField(wrappingLabelWithString: detail)
            description.font = .systemFont(ofSize: 11)
            description.textColor = .secondaryLabelColor
            description.preferredMaxLayoutWidth = 286
            let row = NSStackView(views: [label, description])
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = 3
            stack.addArrangedSubview(row)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: 286).isActive = true
        let controller = NSViewController()
        controller.view = NSView()
        controller.view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: controller.view.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor, constant: -20),
        ])
        controller.preferredContentSize = NSSize(width: 326, height: ceil(stack.fittingSize.height) + 40)
        guidePopover.behavior = .transient
        guidePopover.contentViewController = controller
        guidePopover.contentSize = controller.preferredContentSize
        guidePopover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxX)
    }

    private var legacyLoginItems: [URL] {
        [BundleIdentityMigration.legacyIdentifier, BundleIdentityMigration.currentIdentifier].compactMap { identifier in
            let url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/LaunchAgents/\(identifier).plist")
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  plist["Label"] as? String == identifier,
                  plist["RunAtLoad"] as? Bool == true,
                  let arguments = plist["ProgramArguments"] as? [String],
                  arguments == ["/Applications/Uso.app/Contents/MacOS/Uso"] else { return nil }
            return url
        }
    }

    @objc private func toggleStartAtLogin(_ sender: NSSwitch) {
        do {
            if sender.state == .off {
                if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
                    try SMAppService.mainApp.unregister()
                }
                // Removing the old installer plist prevents future logins without stopping this running app.
                for url in legacyLoginItems { try FileManager.default.removeItem(at: url) }
                UserDefaults.standard.removeObject(forKey: BundleIdentityMigration.pendingLoginItemKey)
            } else if SMAppService.mainApp.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            } else if sender.state == .on {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
            UserDefaults.standard.set(sender.state == .on, forKey: "openAtLogin")
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t update the login preference"
            alert.informativeText = error.localizedDescription
            if let window { alert.beginSheetModal(for: window) }
        }
        updateLoginStatus()
    }

    @objc private func toggleRing(_ sender: NSSwitch) {
        settings.set(UsageRing.allCases[sender.tag], enabled: sender.state == .on)
        onChange?()
    }
}
