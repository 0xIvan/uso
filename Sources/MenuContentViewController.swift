import AppKit

final class MenuContentViewController: NSViewController {
    var onRefresh: (() -> Void)?
    var onSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    private var presentation = UsagePresentation.loading
    private var claudePresentation = UsagePresentation.loading
    private let contentWidth: CGFloat = 288
    private let cardInset: CGFloat = 12

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 210))
        rebuild()
    }

    func update(_ presentation: UsagePresentation, claude: UsagePresentation = .loading) {
        self.claudePresentation = claude
        self.presentation = presentation
        guard isViewLoaded else {
            return
        }
        rebuild()
    }

    func appearanceDidChange() {
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
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            content.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -12),
        ])

        content.addArrangedSubview(headerView())

        if let header = content.arrangedSubviews.last { content.setCustomSpacing(18, after: header) }
        let codexHeading = providerHeading("Codex")
        content.addArrangedSubview(codexHeading)
        content.setCustomSpacing(8, after: codexHeading)
        if let snapshot = presentation.snapshot, snapshot.hasAnyData {
            addSnapshot(snapshot, to: content)
        } else {
            content.addArrangedSubview(emptyStateView())
        }

        if let previousSection = content.arrangedSubviews.last { content.setCustomSpacing(20, after: previousSection) }
        let claudeHeading = providerHeading("Claude")
        content.addArrangedSubview(claudeHeading)
        content.setCustomSpacing(8, after: claudeHeading)
        if let snapshot = claudePresentation.snapshot, snapshot.hasAnyData {
            if let issue = claudePresentation.issue { content.addArrangedSubview(messageLabel(issue.title)) }
            var rows: [NSView] = []
            if let bucket = snapshot.baseLimits.fiveHour { rows.append(limitRow(role: .fiveHour, bucket: bucket, width: contentWidth - cardInset * 2)) }
            if let bucket = snapshot.baseLimits.weekly { rows.append(limitRow(role: .weekly, bucket: bucket, width: contentWidth - cardInset * 2)) }
            if !rows.isEmpty { content.addArrangedSubview(card(containing: rows)) }
            content.addArrangedSubview(messageLabel("\(snapshot.source.rawValue) · Updated \(UsageFormatting.updated(snapshot.updatedAt))"))
        } else {
            content.addArrangedSubview(messageLabel(claudePresentation.isRefreshing ? "Checking Claude usage…" : (claudePresentation.issue == .notSignedIn ? "Sign in with Claude Code to see subscription usage." : claudePresentation.issue?.title ?? "No Claude usage data")))
        }

        content.addArrangedSubview(separator())
        content.addArrangedSubview(controlsView())

        view.layoutSubtreeIfNeeded()
        let height = ceil(content.fittingSize.height) + 26
        preferredContentSize = NSSize(width: 320, height: max(height, 190))
        view.frame.size = preferredContentSize
    }

    private func headerView() -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyDown
        icon.setAccessibilityElement(false)
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),
        ])

        let title = label("Uso", size: 15, weight: .semibold, color: .labelColor)
        let freshness: NSTextField
        if let snapshot = presentation.snapshot, snapshot.hasAnyData {
            freshness = label(
                "Updated \(UsageFormatting.updated(snapshot.updatedAt))",
                size: 11,
                weight: .regular,
                color: .secondaryLabelColor
            )
        } else if presentation.isRefreshing {
            freshness = label("Refreshing…", size: 11, weight: .regular, color: .secondaryLabelColor)
        } else {
            freshness = label("No current snapshot", size: 11, weight: .regular, color: .secondaryLabelColor)
        }

        let text = NSStackView(views: [title, freshness])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        let status = statusBadge()
        let row = NSStackView(views: [icon, text, flexibleSpacer(), status])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 9
        row.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        return row
    }

    private func addSnapshot(_ snapshot: UsageSnapshot, to content: NSStackView) {
        if let issue = presentation.issue {
            content.addArrangedSubview(messageLabel(issue.title))
        }

        var baseRows: [NSView] = []
        if let fiveHour = snapshot.baseLimits.fiveHour {
            baseRows.append(limitRow(
                role: .fiveHour,
                bucket: fiveHour,
                width: contentWidth - (cardInset * 2)
            ))
        }
        if let weekly = snapshot.baseLimits.weekly {
            baseRows.append(limitRow(
                role: .weekly,
                bucket: weekly,
                width: contentWidth - (cardInset * 2)
            ))
        }
        if let count = snapshot.availableResetCount {
            baseRows.append(resetCountRow(count, resets: snapshot.availableResets))
        }
        if !baseRows.isEmpty {
            content.addArrangedSubview(card(containing: baseRows))
        }

        let additionalLimits = MenuLimitFilter.visibleAdditionalLimits(snapshot.additionalLimits)
        guard !additionalLimits.isEmpty else {
            return
        }
        content.addArrangedSubview(sectionLabel("Additional limits"))
        let rows = additionalLimits.map {
            additionalRow($0, width: contentWidth - (cardInset * 2))
        }
        content.addArrangedSubview(card(containing: rows, spacing: 9))
    }

    private func limitRow(role: BaseLimitRole, bucket: LimitBucket, width: CGFloat) -> NSView {
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
        let resetLabel = label(resetText, size: 11, weight: .regular, color: cardSecondaryColor)
        let textStack = NSStackView(views: [nameLabel, resetLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2

        let pace = UsagePaceCalculator.calculate(bucket: bucket)
        let tintColor = PacePalette.color(for: bucket)
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
        header.widthAnchor.constraint(equalToConstant: width).isActive = true

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
        paceBar.widthAnchor.constraint(equalToConstant: width).isActive = true

        let used = label(
            "\(UsageFormatting.percent(pace.usedPercent)) used",
            size: 9,
            weight: .regular,
            color: cardTertiaryColor
        )
        let expected = label(
            "On pace \(UsageFormatting.percent(pace.expectedUsedPercent))",
            size: 9,
            weight: .regular,
            color: cardTertiaryColor
        )
        let legend = NSStackView(views: [used, flexibleSpacer(), expected])
        legend.orientation = .horizontal
        legend.alignment = .centerY
        legend.widthAnchor.constraint(equalToConstant: width).isActive = true

        let row = NSStackView(views: [header, status, paceBar, legend])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 4
        row.setCustomSpacing(8, after: header)
        return row
    }

    private func resetCountRow(_ count: Int, resets: [AvailableReset]?) -> NSView {
        let title = label("Available resets", size: 12, weight: .medium, color: .labelColor)
        let value = label(String(count), size: 12, weight: .semibold, color: .labelColor)
        value.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [title, flexibleSpacer(), value])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.widthAnchor.constraint(equalToConstant: contentWidth - (cardInset * 2)).isActive = true
        guard count > 0 else {
            return row
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let expiryTexts = resets?.map { reset in
            reset.expiresAt.map { "Expires \(formatter.string(from: $0))" } ?? "Expiry unavailable"
        } ?? ["Expiry unavailable"]
        let details = expiryTexts.map { label($0, size: 11, weight: .regular, color: cardSecondaryColor) }
        let stack = NSStackView(views: [row] + details)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        return stack
    }

    private func additionalRow(_ limit: AdditionalLimit, width: CGFloat) -> NSView {
        let indicator = NSView()
        indicator.wantsLayer = true
        indicator.layer?.backgroundColor = PacePalette.color(for: limit.bucket).cgColor
        indicator.layer?.cornerRadius = 3
        indicator.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            indicator.widthAnchor.constraint(equalToConstant: 6),
            indicator.heightAnchor.constraint(equalToConstant: 6),
        ])

        let name = label(limit.name, size: 11, weight: .medium, color: .labelColor)
        name.lineBreakMode = .byTruncatingTail
        let reset = label(UsageFormatting.adaptiveReset(limit.bucket), size: 10, weight: .regular, color: cardTertiaryColor)
        reset.setContentHuggingPriority(.required, for: .horizontal)
        let percent = label(
            "\(UsageFormatting.percent(limit.bucket.remainingPercent)) left",
            size: 11,
            weight: .semibold,
            color: PacePalette.color(for: limit.bucket)
        )
        percent.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [indicator, name, flexibleSpacer(), percent, reset])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 7
        row.widthAnchor.constraint(equalToConstant: width).isActive = true
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
            case .unavailable, .offlineCached, .signInExpired, .rateLimited, .credentialUpdateFailed:
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
        return card(containing: [stack])
    }

    private func controlsView() -> NSView {
        let refresh = NSButton(title: presentation.isRefreshing ? "Refreshing…" : "Refresh", target: self, action: #selector(refreshPressed))
        refresh.bezelStyle = .rounded
        refresh.controlSize = .small
        refresh.isEnabled = !presentation.isRefreshing
        refresh.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        refresh.imagePosition = .imageLeading

        let quit = NSButton(title: "Quit", target: self, action: #selector(quitPressed))
        quit.isBordered = false
        quit.controlSize = .small
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        quit.imagePosition = .imageLeading
        quit.contentTintColor = .secondaryLabelColor

        let settings = NSButton(title: "Settings…", target: self, action: #selector(settingsPressed))
        settings.bezelStyle = .rounded
        settings.controlSize = .small
        let row = NSStackView(views: [refresh, settings, flexibleSpacer(), quit])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        return row
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        return box
    }

    private func card(containing views: [NSView], spacing: CGFloat = 12) -> NSView {
        var arrangedViews: [NSView] = []
        for (index, view) in views.enumerated() {
            if index > 0 {
                arrangedViews.append(cardSeparator())
            }
            arrangedViews.append(view)
        }

        let stack = NSStackView(views: arrangedViews)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        let box = NSBox()
        box.boxType = .custom
        box.fillColor = appearanceColor(
            light: NSColor(calibratedWhite: 0, alpha: 0.035),
            dark: NSColor(calibratedWhite: 1, alpha: 0.055)
        )
        box.borderColor = appearanceColor(
            light: NSColor(calibratedWhite: 0, alpha: 0.09),
            dark: NSColor(calibratedWhite: 1, alpha: 0.11)
        )
        box.borderWidth = 1
        box.cornerRadius = 9
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)

        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: contentWidth),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: cardInset),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -cardInset),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 11),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -11),
        ])
        return box
    }

    private func cardSeparator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: contentWidth - (cardInset * 2)).isActive = true
        return box
    }

    private func statusBadge() -> NSView {
        let text: String
        let color: NSColor
        if presentation.isRefreshing {
            text = "Refreshing"
            color = .secondaryLabelColor
        } else if let snapshot = presentation.snapshot, snapshot.hasAnyData {
            text = snapshot.source.rawValue
            color = snapshot.source == .live
                ? RingPalette.color(forRemaining: 100)
                : .systemOrange
        } else {
            text = "Unavailable"
            color = .secondaryLabelColor
        }

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = color.cgColor
        dot.layer?.cornerRadius = 2.5
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 5),
            dot.heightAnchor.constraint(equalToConstant: 5),
        ])

        let textLabel = label(text, size: 9, weight: .semibold, color: color)
        let row = NSStackView(views: [dot, textLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 5
        row.edgeInsets = NSEdgeInsets(top: 3, left: 7, bottom: 3, right: 7)
        row.wantsLayer = true
        row.layer?.backgroundColor = color.withAlphaComponent(0.11).cgColor
        row.layer?.cornerRadius = 9
        return row
    }

    private func providerHeading(_ text: String) -> NSTextField {
        label(text, size: 14, weight: .semibold, color: .labelColor)
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        label(text, size: 10, weight: .medium, color: .secondaryLabelColor)
    }

    private var cardSecondaryColor: NSColor {
        appearanceColor(
            light: NSColor(calibratedWhite: 0, alpha: 0.68),
            dark: NSColor(calibratedWhite: 1, alpha: 0.72)
        )
    }

    private var cardTertiaryColor: NSColor {
        appearanceColor(
            light: NSColor(calibratedWhite: 0, alpha: 0.52),
            dark: NSColor(calibratedWhite: 1, alpha: 0.58)
        )
    }

    private func appearanceColor(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
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

    @objc private func settingsPressed() { onSettings?() }

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
