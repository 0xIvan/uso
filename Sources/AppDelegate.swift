import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let client: UsageClient
    private let workerQueue = DispatchQueue(label: "local.codex.usage-rings.refresh", qos: .utility)
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let popoverController = PopoverViewController()
    private var refreshTimer: Timer?
    private var presentation = UsagePresentation(snapshot: nil, issue: nil, isRefreshing: false)
    private var lastValidSnapshot: UsageSnapshot?

    init(codexHome: URL) {
        client = UsageClient(codexHome: codexHome)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        configurePopover()
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            return
        }
        button.image = RingRenderer.statusImage(baseLimits: BaseLimits())
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(togglePopover)
        button.sendAction(on: [.leftMouseUp])
        button.toolTip = "Codex usage is loading…"
        statusItem.isVisible = true
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = popoverController
        popoverController.onRefresh = { [weak self] in
            self?.refresh()
        }
        popoverController.onQuit = {
            NSApp.terminate(nil)
        }
        popoverController.update(presentation)
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
        popoverController.update(presentation)
    }

    private func tooltipText() -> String {
        guard let snapshot = presentation.snapshot, snapshot.hasAnyData else {
            if presentation.isRefreshing {
                return "Codex usage is loading…"
            }
            return presentation.issue?.title ?? "No Codex usage data"
        }

        var lines = ["Codex Usage"]
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

    @objc private func togglePopover() {
        guard let button = statusItem.button else {
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            if #available(macOS 14.0, *) {
                NSApp.activate()
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
