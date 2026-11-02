import AppKit
import Foundation
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let showsSettings: Bool
    private let client: UsageClient
    private let claudeClient = ClaudeUsageClient()
    private let grokClient = GrokUsageClient()
    private let cursorClient = CursorUsageClient()
    private let settings = RingSettings()
    private let resetNotifications = ResetNotifications()
    private lazy var settingsController = SettingsWindowController(settings: settings)
    private var lastRefresh: [UsageRing: Date] = [:]
    private let workerQueue = DispatchQueue(label: "com.ivan.uso.refresh", qos: .utility)
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let menuItem = NSMenuItem()
    private let menuController = MenuContentViewController()
    private var refreshTimer: Timer?
    private var wakeObservation: NSObjectProtocol?
    private var appearanceObservation: NSKeyValueObservation?
    private let updaterController = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    private var updaterObservation: NSKeyValueObservation?
    private var presentations = Dictionary(uniqueKeysWithValues: UsageRing.allCases.map { ($0, UsagePresentation.notLoaded) })

    init(codexHome: URL, showsSettings: Bool = false) {
        self.showsSettings = showsSettings
        client = UsageClient(codexHome: codexHome)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        do {
            try BundleIdentityMigration.restoreLoginItem()
        } catch {
            fputs("Uso: could not restore the login item: \(error.localizedDescription)\n", stderr)
        }
        observeAppearance()
        configureStatusItem()
        configureMenu()
        resetNotifications.onStatusChange = { [weak self] text in
            self?.settingsController.updateNotificationStatus(text)
        }
        updaterObservation = updaterController.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let canCheck = updater.canCheckForUpdates
            DispatchQueue.main.async { [weak self] in
                self?.settingsController.updateUpdaterAvailability(canCheck)
            }
        }
        updaterController.startUpdater()
        if showsSettings { settingsController.present() }
        wakeObservation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh(.wake)
        }
        refresh(.scheduled)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refresh(.scheduled)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        if let wakeObservation { NSWorkspace.shared.notificationCenter.removeObserver(wakeObservation) }
        appearanceObservation?.invalidate()
        updaterObservation?.invalidate()
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
        button.image = RingRenderer.statusImage(limits: [])
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
            self?.refresh(.menu)
        }
        menuController.onSettings = { [weak self] in
            guard let self else { return }
            self.menu.cancelTracking()
            self.settingsController.present()
        }
        settingsController.onChange = { [weak self] in self?.settingsDidChange() }
        settingsController.onCheckForUpdates = { [weak self] in
            guard let self, self.updaterController.updater.canCheckForUpdates else { return }
            self.updaterController.checkForUpdates(nil)
        }
        menuController.onQuit = {
            NSApp.terminate(nil)
        }
        menuController.update(presentations, enabled: settings.enabled)
    }

    private func settingsDidChange() {
        let enabled = settings.enabled
        for provider in UsageRing.allCases where !enabled.contains(provider) {
            presentations[provider] = .notLoaded
        }
        refresh(.settingsChanged)
    }

    private func refresh(_ trigger: RefreshTrigger) {
        let due = trigger.due(enabled: settings.enabled, presentations: presentations, lastRefresh: lastRefresh, now: Date())
        for provider in due {
            presentations[provider]?.isRefreshing = true
            lastRefresh[provider] = Date()
        }
        updateInterface()

        workerQueue.async { [weak self] in
            for provider in due {
                guard let self else { return }
                guard self.settings.enabled.contains(provider) else { continue }
                let result = self.load(provider, trigger: trigger)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.settings.enabled.contains(provider) else { return }
                    self.presentations[provider] = UsageSnapshotPolicy.resolve(result: result)
                    self.updateInterface()
                }
            }
        }
    }

    private func load(_ provider: UsageRing, trigger: RefreshTrigger) -> UsageLoadResult {
        switch provider {
        case .codex: return client.load()
        case .claude: return claudeClient.load()
        case .grok: return grokClient.load(retryingDeclinedKeychain: trigger.retriesDeclinedKeychain)
        case .cursor: return cursorClient.load()
        }
    }

    private func updateInterface() {
        precondition(Thread.isMainThread)
        resetNotifications.synchronize(settings: settings, presentations: presentations)
        let rings = settings.visible(presentations)
        let image = RingRenderer.statusImage(limits: rings.map { $0.limits(in: presentations) }, icons: rings.map(\.icon))
        statusItem.length = image.size.width
        statusItem.button?.image = image
        statusItem.button?.toolTip = tooltipText()
        statusItem.button?.setAccessibilityLabel("Uso usage")
        menuController.update(presentations, enabled: settings.enabled)
    }

    private func tooltipText() -> String {
        var lines = ["Uso"]
        for ring in settings.visible(presentations) {
            let limits = ring.limits(in: presentations)
            for (role, bucket) in [(BaseLimitRole.fiveHour, limits.fiveHour), (.weekly, limits.weekly)] {
                guard let bucket else { continue }
                let detail: String
                if bucket.remainingPercent <= 0 {
                    detail = UsageFormatting.limitReached(bucket)
                } else {
                    let pace = ring.hasUnstartedWindow(bucket) ? "Window not started" : UsagePaceCalculator.calculate(bucket: bucket).flatMap(UsageFormatting.paceStatus)
                    detail = "\(UsageFormatting.percent(bucket.remainingPercent)) remaining" + (pace.map { " · \($0)" } ?? "")
                }
                lines.append("\(ring.title) \(role.title(for: bucket)): \(detail)")
            }
        }

        for provider in UsageRing.allCases {
            guard let value = presentations[provider], value.hasSignIn else { continue }
            if let issue = value.issue { lines.append("\(provider.title): \(issue.title(for: provider))") }
            if let snapshot = value.snapshot { lines.append("\(provider.title): \(snapshot.source.rawValue) · Updated \(UsageFormatting.updated(snapshot.updatedAt))") }
        }
        return lines.joined(separator: "\n")
    }
}
