import AppKit

final class MenuContentViewController: NSViewController {
    var onRefresh: (() -> Void)?
    var onSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    private var presentations = Dictionary(uniqueKeysWithValues: UsageRing.allCases.map { ($0, UsagePresentation.loading) })
    private var enabled = UsageRing.allCases
    private let contentWidth: CGFloat = 288
    private let cardInset: CGFloat = 12

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 210))
        rebuild()
    }

    func update(_ presentations: [UsageRing: UsagePresentation], enabled: [UsageRing]) {
        self.presentations = presentations
        self.enabled = enabled
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

        for provider in UsageRing.allCases {
            guard let presentation = presentations[provider], presentation.hasSignIn else { continue }
            if let previousSection = content.arrangedSubviews.last {
                content.setCustomSpacing(provider == .codex ? 18 : 20, after: previousSection)
            }
            let heading = sectionLabel(provider.title)
            content.addArrangedSubview(heading)
            content.setCustomSpacing(8, after: heading)
            if let snapshot = presentation.snapshot, snapshot.hasAnyData {
                addSnapshot(snapshot, provider: provider, to: content)
            } else {
                content.addArrangedSubview(emptyStateView(for: provider, presentation: presentation))
            }
        }

        if signedInPresentations.isEmpty {
            if enabled.isEmpty {
                content.addArrangedSubview(messageLabel("All providers are off. Turn one on in Settings."))
            } else if isRefreshing {
                content.addArrangedSubview(messageLabel("Checking signed-in providers…"))
            } else {
                content.addArrangedSubview(card(containing: enabled.map(signInRow)))
            }
        }

        content.addArrangedSubview(separator())
        content.addArrangedSubview(controlsView())

        view.layoutSubtreeIfNeeded()
        let height = ceil(content.fittingSize.height) + 26
        preferredContentSize = NSSize(width: 320, height: height)
        view.frame.size = preferredContentSize
    }

    private var signedInPresentations: [UsagePresentation] {
        UsageRing.allCases.compactMap { presentations[$0] }.filter(\.hasSignIn)
    }

    private var headerSnapshot: UsageSnapshot? {
        signedInPresentations
            .compactMap(\.snapshot).filter(\.hasAnyData)
            .max { $0.updatedAt < $1.updatedAt }
    }

    private var isRefreshing: Bool {
        presentations.values.contains(where: \.isRefreshing)
    }

    private var hasLiveSnapshot: Bool {
        signedInPresentations.contains {
            $0.snapshot?.source == .live && $0.snapshot?.hasAnyData == true
        }
    }

    private func providerIssueText(_ presentation: UsagePresentation, provider: UsageRing) -> String? {
        guard let issue = presentation.issue else { return nil }
        return issue == .offlineCached && !hasLiveSnapshot ? nil : issue.title(for: provider)
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

        let title = label("Uso", size: 13, weight: .semibold, color: .labelColor)
        let freshness: NSTextField?
        if let snapshot = headerSnapshot {
            freshness = label(
                "Updated \(UsageFormatting.updated(snapshot.updatedAt))",
                size: 11,
                weight: .regular,
                color: .secondaryLabelColor
            )
        } else if isRefreshing {
            freshness = label("Refreshing…", size: 11, weight: .regular, color: .secondaryLabelColor)
        } else {
            freshness = nil
        }

        let text = NSStackView(views: [title] + (freshness.map { [$0] } ?? []))
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        let status = statusBadge()
        let row = NSStackView(views: [icon, text, flexibleSpacer()] + (status.map { [$0] } ?? []))
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 9
        row.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        return row
    }

    private func addSnapshot(_ snapshot: UsageSnapshot, provider: UsageRing, to content: NSStackView) {
        if let issue = presentations[provider].flatMap({ providerIssueText($0, provider: provider) }) {
            content.addArrangedSubview(messageLabel(issue))
        }

        var baseRows: [NSView] = []
        if let fiveHour = snapshot.baseLimits.fiveHour {
            baseRows.append(limitRow(
                role: .fiveHour,
                bucket: fiveHour,
                provider: provider,
                width: contentWidth - (cardInset * 2)
            ))
        }
        if let weekly = snapshot.baseLimits.weekly {
            baseRows.append(limitRow(
                role: .weekly,
                bucket: weekly,
                provider: provider,
                width: contentWidth - (cardInset * 2)
            ))
        }
        if provider == .codex, let count = snapshot.availableResetCount {
            baseRows.append(resetCountRow(count, resets: snapshot.availableResets))
        }
        if !baseRows.isEmpty {
            content.addArrangedSubview(card(containing: baseRows))
        }

        let additionalLimits = MenuLimitFilter.visibleAdditionalLimits(snapshot.additionalLimits)
        guard provider == .codex, !additionalLimits.isEmpty else {
            return
        }
        content.addArrangedSubview(sectionLabel("Additional limits"))
        let rows = additionalLimits.map {
            additionalRow($0, width: contentWidth - (cardInset * 2))
        }
        content.addArrangedSubview(card(containing: rows, spacing: 9))
    }

    private func limitRow(role: BaseLimitRole, bucket: LimitBucket, provider: UsageRing, width: CGFloat) -> NSView {
        let resetText: String
        switch role {
        case .fiveHour:
            resetText = provider.hasUnstartedWindow(bucket) ? "Window not started" : UsageFormatting.resetTime(bucket.resetAt)
        case .weekly:
            resetText = UsageFormatting.resetDateText(bucket.resetAt)
        }

        let exhausted = bucket.remainingPercent <= 0
        let nameLabel = label(role.title(for: bucket), size: 13, weight: .semibold, color: .labelColor)
        let resetLabel = label(resetText, size: 11, weight: .regular, color: cardSecondaryColor)
        let textStack = NSStackView(views: [nameLabel] + (exhausted ? [] : [resetLabel]))
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2

        let pace = UsagePaceCalculator.calculate(bucket: bucket)
        let tintColor = PacePalette.color(for: bucket)
        let percentLabel = label(
            exhausted ? UsageFormatting.limitReached(bucket) : "\(UsageFormatting.percent(bucket.remainingPercent)) remaining",
            size: 12,
            weight: .semibold,
            color: tintColor
        )
        percentLabel.alignment = .right
        percentLabel.setContentHuggingPriority(.required, for: .horizontal)
        if exhausted {
            percentLabel.lineBreakMode = .byWordWrapping
            percentLabel.maximumNumberOfLines = 0
            percentLabel.preferredMaxLayoutWidth = width - nameLabel.intrinsicContentSize.width - 8
            percentLabel.widthAnchor.constraint(equalToConstant: percentLabel.preferredMaxLayoutWidth).isActive = true
            percentLabel.setContentCompressionResistancePriority(.required, for: .vertical)
            nameLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        let header = NSStackView(views: [textStack] + (exhausted ? [] : [flexibleSpacer()]) + [percentLabel])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.widthAnchor.constraint(equalToConstant: width).isActive = true

        guard !exhausted, let pace else {
            return header
        }

        let status = UsageFormatting.paceStatus(pace).map {
            label($0, size: 11, weight: .semibold, color: tintColor)
        }
        let paceBar = UsagePaceBarView(pace: pace, tintColor: tintColor)
        paceBar.widthAnchor.constraint(equalToConstant: width).isActive = true

        let behind = UsageFormatting.behindPace(pace).map {
            label($0, size: 9, weight: .regular, color: cardTertiaryColor)
        }
        let expected = label(
            "On pace \(UsageFormatting.percent(pace.expectedUsedPercent))",
            size: 9,
            weight: .regular,
            color: cardTertiaryColor
        )
        let legend = NSStackView(views: (behind.map { [$0] } ?? []) + [flexibleSpacer(), expected])
        legend.orientation = .horizontal
        legend.alignment = .centerY
        legend.widthAnchor.constraint(equalToConstant: width).isActive = true

        let row = NSStackView(views: [header] + (status.map { [$0] } ?? []) + [paceBar, legend])
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
        let percent = label(
            "\(UsageFormatting.percent(limit.bucket.remainingPercent)) left",
            size: 11,
            weight: .semibold,
            color: PacePalette.color(for: limit.bucket)
        )
        percent.setContentHuggingPriority(.required, for: .horizontal)

        let text = NSStackView(views: [name, reset])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        let row = NSStackView(views: [indicator, text, flexibleSpacer(), percent])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 7
        row.widthAnchor.constraint(equalToConstant: width).isActive = true
        return row
    }

    private func emptyStateView(for provider: UsageRing, presentation: UsagePresentation) -> NSView {
        let titleText: String
        let detailText: String
        if presentation.isRefreshing {
            titleText = "Loading usage…"
            detailText = "Checking \(provider.title) usage."
        } else {
            switch presentation.issue {
            case .notSignedIn:
                titleText = "Not signed in"
                detailText = "Sign in to \(provider.title) to make usage available."
            case .noData:
                titleText = "No usage data"
                detailText = "\(provider.title) did not report any recognized limits."
            case .unavailable where provider != .codex,
                 .offlineCached where provider != .codex,
                 .rateLimited where provider != .codex:
                titleText = "Usage temporarily unavailable"
                detailText = presentation.issue == .rateLimited
                    ? "\(provider.title) rate limited the request. Uso will retry in five minutes."
                    : "Uso will retry automatically. You can also click Refresh."
            case .unavailable, .offlineCached, .signInExpired, .rateLimited:
                titleText = "Log in again"
                detailText = provider == .codex
                    ? "Could not fetch Codex usage. Sign in to Codex, then refresh."
                    : "Could not fetch \(provider.title) usage. Open \(provider.appName) to renew its sign-in, then refresh."
            case nil:
                titleText = "No usage data"
                detailText = "Refresh to check again."
            }
        }
        let title = label(titleText, size: 13, weight: .semibold, color: .labelColor)
        let detail = NSTextField(wrappingLabelWithString: detailText)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.widthAnchor.constraint(equalToConstant: contentWidth - cardInset * 2).isActive = true
        detail.setContentCompressionResistancePriority(.required, for: .vertical)
        let stack = NSStackView(views: [title, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        return card(containing: [stack])
    }

    private func controlsView() -> NSView {
        let refresh = actionButton(title: isRefreshing ? "Refreshing…" : "Refresh",
                                   symbol: "arrow.clockwise", action: #selector(refreshPressed))
        refresh.isEnabled = !isRefreshing
        let settings = actionButton(title: "Settings", symbol: "gearshape", action: #selector(settingsPressed))
        let quit = actionButton(title: "Quit", symbol: "power", bordered: false, action: #selector(quitPressed))
        let row = NSStackView(views: [refresh, settings, flexibleSpacer(), quit])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        return row
    }

    private func signInRow(_ provider: UsageRing) -> NSView {
        let copy = provider.loginCommand.map { _ in actionButton(title: "Copy command", symbol: nil, action: #selector(copyLoginCommand(_:))) }
        copy?.tag = UsageRing.allCases.firstIndex(of: provider) ?? 0
        copy?.setAccessibilityLabel("Copy \(provider.title) login command")
        copy?.setContentHuggingPriority(.required, for: .horizontal)
        copy?.setContentCompressionResistancePriority(.required, for: .horizontal)
        let instruction = provider.loginCommand.map { "run \($0)" } ?? "open \(provider.appName) and sign in"
        let text = NSTextField(wrappingLabelWithString: "\(provider.title): \(instruction)")
        text.font = .systemFont(ofSize: 11)
        text.textColor = cardSecondaryColor
        text.preferredMaxLayoutWidth = contentWidth - cardInset * 2 - (copy.map { $0.fittingSize.width + 8 } ?? 0)
        text.widthAnchor.constraint(equalToConstant: text.preferredMaxLayoutWidth).isActive = true
        text.setContentCompressionResistancePriority(.required, for: .vertical)
        let row = NSStackView(views: [text] + (copy.map { [$0] } ?? []))
        row.alignment = .centerY
        row.spacing = 8
        row.widthAnchor.constraint(equalToConstant: contentWidth - cardInset * 2).isActive = true
        return row
    }

    private func actionButton(title: String, symbol: String?, bordered: Bool = true, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.isBordered = bordered
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.imageHugsTitle = true
        button.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }?
            .withSymbolConfiguration(.init(pointSize: NSFont.smallSystemFontSize, weight: .regular))
        button.imagePosition = .imageLeading
        button.contentTintColor = bordered ? nil : .secondaryLabelColor
        return button
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

    private func statusBadge() -> NSView? {
        let providers = Array(presentations.values)
        if hasLiveSnapshot { return nil }
        let text: String
        let color: NSColor
        if headerSnapshot != nil {
            text = "Cached"
            color = .systemOrange
        } else if isRefreshing || enabled.isEmpty {
            return nil
        } else if !providers.contains(where: \.hasSignIn) {
            text = "No sign-in"
            color = .secondaryLabelColor
        } else if providers.contains(where: { $0.issue != nil && $0.issue != .noData && $0.issue != .notSignedIn }) {
            text = "Offline"
            color = .secondaryLabelColor
        } else {
            return nil
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

    private func sectionLabel(_ text: String) -> NSTextField {
        let field = label(text.uppercased(), size: 10, weight: .semibold, color: .secondaryLabelColor)
        field.setAccessibilityLabel(text)
        return field
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

    @objc private func copyLoginCommand(_ sender: NSButton) {
        let provider = UsageRing.allCases[sender.tag]
        guard let command = provider.loginCommand else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        sender.title = "Copied"
        sender.setAccessibilityLabel("\(provider.title) login command copied")
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
