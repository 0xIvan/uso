import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let showsSettings: Bool
    private let client: UsageClient
    private let claudeClient = ClaudeUsageClient()
    private let settings = RingSettings()
    private lazy var settingsController = SettingsWindowController(settings: settings)
    private var claudePresentation = UsagePresentation(snapshot: nil, issue: nil, isRefreshing: false)
    private var lastClaudeSnapshot: UsageSnapshot?
    private var lastClaudeRefresh = Date.distantPast
    private let workerQueue = DispatchQueue(label: "local.codex.usage-rings.refresh", qos: .utility)
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let menuItem = NSMenuItem()
    private let menuController = MenuContentViewController()
    private var refreshTimer: Timer?
    private var appearanceObservation: NSKeyValueObservation?
    private var presentation = UsagePresentation(snapshot: nil, issue: nil, isRefreshing: false)
    private var lastValidSnapshot: UsageSnapshot?

    init(codexHome: URL, showsSettings: Bool = false) {
        self.showsSettings = showsSettings
        client = UsageClient(codexHome: codexHome)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        observeAppearance()
        configureStatusItem()
        configureMenu()
        if showsSettings { settingsController.present() }
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        appearanceObservation?.invalidate()
    }

    private func observeAppearance() {
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.initial, .new]) {
            [weak self] application, _ in
            let isDark = application.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let resourceName = isDark ? "AppIcon-dark" : "AppIcon-light"
            guard let url = Bundle.main.url(forResource: resourceName, withExtension: "png"),
                  let image = NSImage(contentsOf: url) else {
                return
            }
            application.applicationIconImage = image
            self?.menuController.appearanceDidChange()
        }
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            return
        }
        button.image = RingRenderer.statusImage(limits: settings.enabled.map { _ in BaseLimits() }, icons: settings.enabled.map(\.icon))
        button.imagePosition = .imageOnly
        button.toolTip = "Uso usage is loading…"
        statusItem.isVisible = true
    }

    private func configureMenu() {
        menu.autoenablesItems = false
        menuItem.isEnabled = true
        menuItem.view = menuController.view
        menu.addItem(menuItem)
        statusItem.menu = menu

        menuController.onRefresh = { [weak self] in
            self?.refresh(forceClaude: true)
        }
        menuController.onSettings = { [weak self] in
            guard let self else { return }
            self.menu.cancelTracking()
            self.settingsController.present()
        }
        settingsController.onChange = { [weak self] in self?.updateInterface() }
        menuController.onQuit = {
            NSApp.terminate(nil)
        }
        menuController.update(presentation)
    }

    private func refresh(forceClaude: Bool = false) {
        guard !presentation.isRefreshing, !claudePresentation.isRefreshing else {
            return
        }
        presentation.isRefreshing = true
        let refreshClaude = Date().timeIntervalSince(lastClaudeRefresh) >= 300
            || (forceClaude && claudePresentation.issue != .rateLimited)
        if refreshClaude {
            claudePresentation.isRefreshing = true
            lastClaudeRefresh = Date()
        }
        updateInterface()

        workerQueue.async { [weak self] in
            guard let self else {
                return
            }
            let result = self.client.load()
            DispatchQueue.main.async { [weak self] in
                self?.apply(result)
            }
            if refreshClaude {
                let claudeResult = self.claudeClient.load()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let resolution = UsageSnapshotPolicy.resolve(result: claudeResult, lastValidSnapshot: self.lastClaudeSnapshot)
                    self.lastClaudeSnapshot = resolution.lastValidSnapshot
                    self.claudePresentation = resolution.presentation
                    self.updateInterface()
                }
            }
        }
    }

    private func apply(_ result: UsageLoadResult) {
        let resolution = UsageSnapshotPolicy.resolve(
            result: result,
            lastValidSnapshot: lastValidSnapshot
        )
        lastValidSnapshot = resolution.lastValidSnapshot
        presentation = resolution.presentation
        updateInterface()
    }

    private func updateInterface() {
        precondition(Thread.isMainThread)
        let rings = settings.enabled
        let image = RingRenderer.statusImage(limits: rings.map { $0.limits(codex: presentation, claude: claudePresentation) }, icons: rings.map(\.icon))
        statusItem.length = image.size.width
        statusItem.button?.image = image
        statusItem.button?.toolTip = tooltipText()
        statusItem.button?.setAccessibilityLabel("Uso usage")
        menuController.update(presentation, claude: claudePresentation)
    }

    private func tooltipText() -> String {
        var lines = ["Uso"]
        for ring in settings.enabled {
            let limits = ring.limits(codex: presentation, claude: claudePresentation)
            for (name, bucket) in [("5h", limits.fiveHour), ("Weekly", limits.weekly)] {
                if let bucket {
                    let pace = UsagePaceCalculator.calculate(bucket: bucket).map(UsageFormatting.paceStatus) ?? "Pace unavailable"
                    lines.append("\(ring.title) \(name): \(UsageFormatting.percent(bucket.remainingPercent)) remaining · \(pace)")
                } else {
                    lines.append("\(ring.title) \(name): unavailable")
                }
            }
        }

        for (name, value) in [("Codex", presentation), ("Claude", claudePresentation)] {
            if let issue = value.issue { lines.append("\(name): \(issue.title)") }
            if let snapshot = value.snapshot { lines.append("\(name): \(snapshot.source.rawValue) · Updated \(UsageFormatting.updated(snapshot.updatedAt))") }
        }
        return lines.joined(separator: "\n")
    }
}
