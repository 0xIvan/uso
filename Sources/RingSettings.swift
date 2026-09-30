import AppKit

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

final class SettingsWindowController: NSWindowController {
    private let settings: RingSettings
    var onChange: (() -> Void)?

    init(settings: RingSettings) {
        self.settings = settings
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 265),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Uso Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
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
        let detail = NSTextField(wrappingLabelWithString: "Weekly outside · 5-hour inside\n\nGreen: on pace\nYellow: up to 5 percentage points over pace\nRed: more than 5 points over pace or exhausted\nGray: pace or usage unavailable")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        stack.addArrangedSubview(detail)
        window.contentView?.addSubview(stack)
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            ])
        }
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func toggleRing(_ sender: NSButton) {
        settings.set(UsageRing.allCases[sender.tag], enabled: sender.state == .on)
        onChange?()
    }
}
