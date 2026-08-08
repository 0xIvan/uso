import AppKit

final class PopoverViewController: NSViewController {
    var onRefresh: (() -> Void)?
    var onQuit: (() -> Void)?

    private var presentation = UsagePresentation.loading

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 210))
        rebuild()
    }

    func update(_ presentation: UsagePresentation) {
        self.presentation = presentation
        guard isViewLoaded else {
            return
        }
        rebuild()
    }

    private func rebuild() {
        view.subviews.forEach { $0.removeFromSuperview() }

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            content.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -12),
        ])

        content.addArrangedSubview(headerView())

        if let snapshot = presentation.snapshot, snapshot.hasAnyData {
            addSnapshot(snapshot, to: content)
        } else {
            content.addArrangedSubview(emptyStateView())
        }

        content.addArrangedSubview(separator())
        content.addArrangedSubview(controlsView())

        view.layoutSubtreeIfNeeded()
        let height = ceil(content.fittingSize.height) + 26
        preferredContentSize = NSSize(width: 320, height: min(max(height, 190), 520))
        view.frame.size = preferredContentSize
    }

    private func headerView() -> NSView {
        let title = label("Codex Usage", size: 15, weight: .semibold, color: .labelColor)
        let freshness: NSTextField
        if let snapshot = presentation.snapshot, snapshot.hasAnyData {
            freshness = label(
                "\(snapshot.source.rawValue) · Last updated \(UsageFormatting.updated(snapshot.updatedAt))",
                size: 11,
                weight: .regular,
                color: .secondaryLabelColor
            )
        } else if presentation.isRefreshing {
            freshness = label("Refreshing…", size: 11, weight: .regular, color: .secondaryLabelColor)
        } else {
            freshness = label("No current snapshot", size: 11, weight: .regular, color: .secondaryLabelColor)
        }

        let stack = NSStackView(views: [title, freshness])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        return stack
    }

    private func addSnapshot(_ snapshot: UsageSnapshot, to content: NSStackView) {
        if let issue = presentation.issue {
            content.addArrangedSubview(messageLabel(issue.title))
        }
        if let fiveHour = snapshot.baseLimits.fiveHour {
            content.addArrangedSubview(limitRow(
                role: .fiveHour,
                bucket: fiveHour
            ))
        }
        if let weekly = snapshot.baseLimits.weekly {
            content.addArrangedSubview(limitRow(
                role: .weekly,
                bucket: weekly
            ))
        }

        let additionalLimits = PopoverLimitFilter.visibleAdditionalLimits(snapshot.additionalLimits)
        guard !additionalLimits.isEmpty else {
            return
        }
        content.addArrangedSubview(sectionLabel("ADDITIONAL LIMITS"))
        for limit in additionalLimits {
            content.addArrangedSubview(additionalRow(limit))
        }
    }

    private func limitRow(role: BaseLimitRole, bucket: LimitBucket) -> NSView {
        let name: String
        let resetText: String
        switch role {
        case .fiveHour:
            name = "5h"
            resetText = UsageFormatting.resetTime(bucket.resetAt)
        case .weekly:
            name = "1w"
            resetText = UsageFormatting.resetDateText(bucket.resetAt)
        }

        let nameLabel = label(name, size: 13, weight: .semibold, color: .labelColor)
        let resetLabel = label(resetText, size: 11, weight: .regular, color: .secondaryLabelColor)
        let textStack = NSStackView(views: [nameLabel, resetLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2

        let pace = UsagePaceCalculator.calculate(bucket: bucket)
        let tintColor = RingPalette.color(forRemaining: bucket.remainingPercent)
        let percentLabel = label(
            "\(UsageFormatting.percent(bucket.remainingPercent)) remaining",
            size: 12,
            weight: .semibold,
            color: tintColor
        )
        percentLabel.alignment = .right
        percentLabel.setContentHuggingPriority(.required, for: .horizontal)

        let header = NSStackView(views: [textStack, flexibleSpacer(), percentLabel])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.widthAnchor.constraint(equalToConstant: 288).isActive = true

        guard let pace else {
            return header
        }

        let status = label(
            UsageFormatting.paceStatus(pace),
            size: 11,
            weight: .semibold,
            color: tintColor
        )
        let paceBar = UsagePaceBarView(pace: pace, tintColor: tintColor)
        paceBar.widthAnchor.constraint(equalToConstant: 288).isActive = true

        let used = label(
            "\(UsageFormatting.percent(pace.usedPercent)) used",
            size: 9,
            weight: .regular,
            color: .tertiaryLabelColor
        )
        let expected = label(
            "On pace \(UsageFormatting.percent(pace.expectedUsedPercent))",
            size: 9,
            weight: .regular,
            color: .tertiaryLabelColor
        )
        let legend = NSStackView(views: [used, flexibleSpacer(), expected])
        legend.orientation = .horizontal
        legend.alignment = .centerY
        legend.widthAnchor.constraint(equalToConstant: 288).isActive = true

        let row = NSStackView(views: [header, status, paceBar, legend])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 4
        row.setCustomSpacing(8, after: header)
        return row
    }

    private func additionalRow(_ limit: AdditionalLimit) -> NSView {
        let indicator = NSView()
        indicator.wantsLayer = true
        indicator.layer?.backgroundColor = RingPalette.color(forRemaining: limit.bucket.remainingPercent).cgColor
        indicator.layer?.cornerRadius = 3
        indicator.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            indicator.widthAnchor.constraint(equalToConstant: 6),
            indicator.heightAnchor.constraint(equalToConstant: 6),
        ])

        let name = label(limit.name, size: 11, weight: .medium, color: .labelColor)
        name.lineBreakMode = .byTruncatingTail
        let reset = label(UsageFormatting.adaptiveReset(limit.bucket), size: 10, weight: .regular, color: .tertiaryLabelColor)
        reset.setContentHuggingPriority(.required, for: .horizontal)
        let percent = label(
            "\(UsageFormatting.percent(limit.bucket.remainingPercent)) left",
            size: 11,
            weight: .semibold,
            color: RingPalette.color(forRemaining: limit.bucket.remainingPercent)
        )
        percent.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [indicator, name, flexibleSpacer(), percent, reset])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 7
        row.widthAnchor.constraint(equalToConstant: 288).isActive = true
        return row
    }

    private func emptyStateView() -> NSView {
        let titleText: String
        let detailText: String
        if presentation.isRefreshing {
            titleText = "Loading usage…"
            detailText = "Checking Codex usage and local cached data."
        } else {
            switch presentation.issue {
            case .notSignedIn:
                titleText = "Not signed in"
                detailText = "Sign in to Codex to make usage available."
            case .noData:
                titleText = "No usage data"
                detailText = "Codex did not report any recognized limits."
            case .unavailable, .offlineCached:
                titleText = "Usage unavailable"
                detailText = "The live endpoint and local cache could not provide data."
            case nil:
                titleText = "No usage data"
                detailText = "Refresh to check again."
            }
        }
        let title = label(titleText, size: 13, weight: .semibold, color: .labelColor)
        let detail = label(detailText, size: 11, weight: .regular, color: .secondaryLabelColor)
        detail.maximumNumberOfLines = 2
        let stack = NSStackView(views: [title, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        return stack
    }

    private func controlsView() -> NSView {
        let refresh = NSButton(title: presentation.isRefreshing ? "Refreshing…" : "Refresh", target: self, action: #selector(refreshPressed))
        refresh.bezelStyle = .rounded
        refresh.controlSize = .small
        refresh.isEnabled = !presentation.isRefreshing

        let quit = NSButton(title: "Quit", target: self, action: #selector(quitPressed))
        quit.bezelStyle = .rounded
        quit.controlSize = .small

        let row = NSStackView(views: [refresh, flexibleSpacer(), quit])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.widthAnchor.constraint(equalToConstant: 288).isActive = true
        return row
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 288).isActive = true
        return box
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let field = label(text, size: 9, weight: .semibold, color: .tertiaryLabelColor)
        field.font = NSFont.systemFont(ofSize: 9, weight: .semibold)
        return field
    }

    private func messageLabel(_ text: String) -> NSTextField {
        let field = label(text, size: 10, weight: .medium, color: .secondaryLabelColor)
        field.maximumNumberOfLines = 2
        return field
    }

    private func flexibleSpacer() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return spacer
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = NSFont.systemFont(ofSize: size, weight: weight)
        field.textColor = color
        return field
    }

    @objc private func refreshPressed() {
        onRefresh?()
    }

    @objc private func quitPressed() {
        onQuit?()
    }
}

private final class UsagePaceBarView: NSView {
    private let pace: UsagePace
    private let tintColor: NSColor

    init(pace: UsagePace, tintColor: NSColor) {
        self.pace = pace
        self.tintColor = tintColor
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("Usage pace")
        setAccessibilityValue(
            "\(UsageFormatting.percent(pace.usedPercent)) used; "
                + "on pace is \(UsageFormatting.percent(pace.expectedUsedPercent))"
        )
    }

    @available(*, unavailable, message: "Use init(pace:tintColor:)")
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 12)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let track = NSRect(x: 0, y: 3, width: bounds.width, height: 6)
        NSColor.separatorColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()

        let usedWidth = track.width * pace.usedPercent / 100
        if usedWidth > 0 {
            let usedTrack = NSRect(x: track.minX, y: track.minY, width: usedWidth, height: track.height)
            tintColor.setFill()
            NSBezierPath(roundedRect: usedTrack, xRadius: 3, yRadius: 3).fill()
        }

        let markerX = min(max(track.width * pace.expectedUsedPercent / 100, 1), track.width - 1)
        NSColor.labelColor.setFill()
        NSRect(x: markerX - 1, y: 0, width: 2, height: bounds.height).fill()
    }
}
