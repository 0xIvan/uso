import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let client: UsageClient
    private let workerQueue = DispatchQueue(label: "local.codex.usage-rings.refresh", qos: .utility)
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let menuItem = NSMenuItem()
    private let menuController = MenuContentViewController()
    private var refreshTimer: Timer?
    private var appearanceObservation: NSKeyValueObservation?
    private var presentation = UsagePresentation(snapshot: nil, issue: nil, isRefreshing: false)
    private var lastValidSnapshot: UsageSnapshot?

    init(codexHome: URL) {
        client = UsageClient(codexHome: codexHome)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        observeAppearance()
        configureStatusItem()
        configureMenu()
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
        button.image = RingRenderer.statusImage(baseLimits: BaseLimits())
        button.imagePosition = .imageOnly
        button.toolTip = "Codex usage is loading…"
        statusItem.isVisible = true
    }

    private func configureMenu() {
        menu.autoenablesItems = false
        menuItem.isEnabled = true
        menuItem.view = menuController.view
        menu.addItem(menuItem)
        statusItem.menu = menu

        menuController.onRefresh = { [weak self] in
            self?.refresh()
        }
        menuController.onQuit = {
            NSApp.terminate(nil)
        }
        menuController.update(presentation)
    }

    private func refresh() {
        guard !presentation.isRefreshing else {
            return
        }
        presentation.isRefreshing = true
        updateInterface()

        workerQueue.async { [weak self] in
            guard let self else {
                return
            }
            let result = self.client.load()
            DispatchQueue.main.async { [weak self] in
                self?.apply(result)
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
        let baseLimits = presentation.snapshot?.baseLimits ?? BaseLimits()
        statusItem.button?.image = RingRenderer.statusImage(baseLimits: baseLimits)
        statusItem.button?.toolTip = tooltipText()
        menuController.update(presentation)
    }

    private func tooltipText() -> String {
        guard let snapshot = presentation.snapshot, snapshot.hasAnyData else {
            if presentation.isRefreshing {
                return "Codex usage is loading…"
            }
            return presentation.issue?.title ?? "No Codex usage data"
        }

        var lines = ["Codex Halo"]
        if let fiveHour = snapshot.baseLimits.fiveHour {
            lines.append("5h: \(UsageFormatting.percent(fiveHour.remainingPercent)) remaining · \(UsageFormatting.resetTime(fiveHour.resetAt))")
        }
        if let weekly = snapshot.baseLimits.weekly {
            lines.append("1w: \(UsageFormatting.percent(weekly.remainingPercent)) remaining · \(UsageFormatting.resetDateText(weekly.resetAt))")
        }
        if !snapshot.additionalLimits.isEmpty {
            lines.append("\(snapshot.additionalLimits.count) additional limit\(snapshot.additionalLimits.count == 1 ? "" : "s")")
        }
        lines.append("\(snapshot.source.rawValue) · Last updated \(UsageFormatting.updated(snapshot.updatedAt))")
        if let issue = presentation.issue {
            lines.append(issue.title)
        }
        return lines.joined(separator: "\n")
    }
}
