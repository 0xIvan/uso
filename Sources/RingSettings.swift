import AppKit
import ServiceManagement

enum UsageRing: String, CaseIterable {
    case codex, claude

    var title: String { self == .codex ? "Codex" : "Claude" }

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
    private let loginButton = NSButton(checkboxWithTitle: "Start at login", target: nil, action: nil)
    private let updateButton = NSButton(title: "Check for Updates…", target: nil, action: nil)
    var onChange: (() -> Void)?
    var onCheckForUpdates: (() -> Void)?

    init(settings: RingSettings) {
        self.settings = settings
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 320),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Uso Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        let heading = NSTextField(labelWithString: "Menu bar rings")
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        stack.addArrangedSubview(heading)
        for (index, ring) in UsageRing.allCases.enumerated() {
            let button = NSButton(checkboxWithTitle: ring.title, target: self, action: #selector(toggleRing(_:)))
            button.tag = index
            button.state = settings.enabled.contains(ring) ? .on : .off
            stack.addArrangedSubview(button)
        }
        let detail = NSTextField(wrappingLabelWithString: "Weekly outside · 5-hour inside\nOnly reported usage limits appear\n\nGreen: on pace\nYellow: up to 5 percentage points over pace\nRed: more than 5 points over pace or exhausted\nGray: pace unavailable")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        stack.addArrangedSubview(detail)
        loginButton.target = self
        loginButton.action = #selector(toggleStartAtLogin(_:))
        stack.addArrangedSubview(loginButton)
        updateLoginStatus()
        updateButton.target = self
        updateButton.action = #selector(checkForUpdatesPressed)
        updateButton.bezelStyle = .rounded
        updateButton.isEnabled = false
        stack.addArrangedSubview(updateButton)
        window.contentView?.addSubview(stack)
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            ])
            content.layoutSubtreeIfNeeded()
            window.setContentSize(NSSize(width: 400, height: ceil(stack.fittingSize.height) + 48))
        }
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func present() {
        updateLoginStatus()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func updateUpdaterAvailability(_ canCheck: Bool) {
        updateButton.isEnabled = canCheck
    }

    @objc private func checkForUpdatesPressed() { onCheckForUpdates?() }

    func windowDidBecomeKey(_ notification: Notification) {
        updateLoginStatus()
    }

    private func updateLoginStatus() {
        if legacyLoginItem != nil {
            loginButton.state = .on
            loginButton.toolTip = "Uso opens automatically when you sign in."
            return
        }
        switch SMAppService.mainApp.status {
        case .enabled:
            loginButton.state = .on
            loginButton.toolTip = "Uso opens automatically when you sign in."
        case .requiresApproval:
            loginButton.state = .mixed
            loginButton.toolTip = "Approval is required in System Settings. Click to open Login Items."
        default:
            loginButton.state = .off
            loginButton.toolTip = "Open Uso automatically when you sign in."
        }
    }

    private var legacyLoginItem: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/local.codex.usage-rings.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["Label"] as? String == "local.codex.usage-rings",
              plist["RunAtLoad"] as? Bool == true,
              let arguments = plist["ProgramArguments"] as? [String],
              arguments == ["/Applications/Uso.app/Contents/MacOS/Uso"] else { return nil }
        return url
    }

    @objc private func toggleStartAtLogin(_ sender: NSButton) {
        do {
            if sender.state == .off {
                if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
                    try SMAppService.mainApp.unregister()
                }
                // Removing the old installer plist prevents future logins without stopping this running app.
                if let legacyLoginItem { try FileManager.default.removeItem(at: legacyLoginItem) }
            } else if SMAppService.mainApp.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            } else if sender.state == .on {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t change Start at login"
            alert.informativeText = error.localizedDescription
            if let window { alert.beginSheetModal(for: window) }
        }
        updateLoginStatus()
    }

    @objc private func toggleRing(_ sender: NSButton) {
        settings.set(UsageRing.allCases[sender.tag], enabled: sender.state == .on)
        onChange?()
    }
}
