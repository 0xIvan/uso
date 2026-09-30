import Foundation
import AppKit

enum SelfCheck {
    static func run() -> Bool {
        let checks: [(String, () -> Bool)] = [
            ("signed-out providers are hidden while unavailable sign-ins remain visible", checkProviderVisibility),
            ("Claude idle five-hour windows show their normal not-started state", checkClaudeIdleWindow),
            ("Claude token renewal preserves credentials and classifies failures", checkClaudeRenewal),
            ("nested rings put weekly outside and five-hour inside", checkNestedRings),
            ("Claude windows, ISO timestamps, null and malformed data", checkClaudeDecoding),
            ("ring selection persists and allows all rings off", checkRingSelection),
            ("side-by-side ring dimensions and unavailable fallback", checkRingLayout),
            ("usage and reset requests select the signed-in account", checkAccountSelection),
            ("legacy credentials and invalid sign-ins", checkLegacyCredentials),
            ("weekly in primary only", checkWeeklyPrimaryOnly),
            ("five-hour in secondary only", checkFiveHourSecondaryOnly),
            ("swapped dual buckets", checkSwappedBuckets),
            ("floating duration tolerance", checkFloatingTolerance),
            ("unknown duration stays unknown", checkUnknownDuration),
            ("remaining percentage clamping", checkRemainingClamping),
            ("exhausted limit detection", checkExhaustedLimitDetection),
            ("live decoding variants and additional list", checkLiveDecoding),
            ("available resets distinguish banked, zero, and unknown", checkAvailableResets),
            ("reset expiry dates exclude history and sort soonest first", checkResetExpiries),
            ("cached event and additional dictionary decoding", checkCachedDecoding),
            ("reset timestamp seconds and milliseconds", checkResetTimestamps),
            ("generic usage pace calculation", checkUsagePaceCalculation),
            ("pace color thresholds", checkPaceColorThresholds),
            ("invalid usage pace window is unavailable", checkInvalidUsagePaceWindow),
            ("menu hides only Codex 5.3 Spark", checkMenuLimitFilter),
            ("menu semantic ring roles", checkSemanticRingRoles),
            ("cached refresh retains prior live values", checkCachedRefreshRetainsLive),
            ("initial cached snapshot is accepted", checkInitialCachedSnapshot),
            ("successful live snapshot replaces prior values", checkLiveSnapshotReplacement),
        ]

        var failures: [String] = []
        for (name, check) in checks {
            if check() {
                print("PASS  \(name)")
            } else {
                failures.append(name)
                fputs("FAIL  \(name)\n", stderr)
            }
        }
        if failures.isEmpty {
            print("Uso self-check passed (\(checks.count) checks)")
            return true
        }
        fputs("Uso self-check failed (\(failures.count)/\(checks.count))\n", stderr)
        return false
    }

    private static func checkProviderVisibility() -> Bool {
        let name = "uso-visibility-check-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else { return false }
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = RingSettings(defaults: defaults)
        let absent = UsagePresentation(snapshot: nil, issue: .notSignedIn, isRefreshing: false)
        let unavailable = UsagePresentation(snapshot: nil, issue: .unavailable, isRefreshing: false)
        let signedOutCache = UsagePresentation(snapshot: snapshot(source: .cached, usedPercent: 20), issue: .notSignedIn, isRefreshing: false)
        guard settings.visible(codex: absent, claude: absent).isEmpty,
              settings.visible(codex: .loading, claude: .loading).isEmpty,
              settings.visible(codex: signedOutCache, claude: unavailable) == [.claude],
              settings.visible(codex: unavailable, claude: absent) == [.codex] else { return false }
        settings.set(.claude, enabled: false)
        return settings.visible(codex: absent, claude: unavailable).isEmpty
            && !absent.hasSignIn && unavailable.hasSignIn
    }

    private static func checkClaudeIdleWindow() -> Bool {
        _ = NSApplication.shared
        let absent = UsagePresentation(snapshot: nil, issue: .notSignedIn, isRefreshing: false)
        var idle = snapshot(source: .live, usedPercent: 0)
        idle.baseLimits = BaseLimits(fiveHour: LimitBucket(usedPercent: 0, windowMinutes: 300, resetAt: nil))
        let controller = MenuContentViewController()
        _ = controller.view
        func labels(in view: NSView) -> [String] {
            (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap { labels(in: $0) }
        }
        controller.update(absent, claude: UsagePresentation(snapshot: idle, issue: nil, isRefreshing: false))
        let idleLabels = labels(in: controller.view)
        guard idleLabels.contains("Window not started"), !idleLabels.contains("Reset time unavailable"),
              !idleLabels.contains("Codex"), idleLabels.contains("Claude"),
              idleLabels.contains("Live"), !idleLabels.contains("Unavailable") else { return false }
        idle.baseLimits.fiveHour?.usedPercent = 10
        controller.update(absent, claude: UsagePresentation(snapshot: idle, issue: nil, isRefreshing: false))
        guard labels(in: controller.view).contains("Reset time unavailable") else { return false }
        controller.update(absent, claude: absent)
        let absentLabels = labels(in: controller.view)
        return !absentLabels.contains("Codex") && !absentLabels.contains("Claude")
    }

    private static func checkClaudeRenewal() -> Bool {
        let original: [String: Any] = ["otherCredential": "preserved", "claudeAiOauth": ["accessToken": "old", "refreshToken": "original-refresh", "subscriptionType": "max"]]
        let document = ClaudeUsageClient.renewedDocument(original, response: ["refresh_token": "rotated", "scope": "user:profile user:inference"], token: "new", expiresIn: 3600)
        let oauth = document["claudeAiOauth"] as? [String: Any]
        let fallback = ClaudeUsageClient.renewedDocument(original, response: [:], token: "new", expiresIn: 3600)["claudeAiOauth"] as? [String: Any]
        return document["otherCredential"] as? String == "preserved"
            && oauth?["refreshToken"] as? String == "rotated"
            && oauth?["accessToken"] as? String == "new"
            && oauth?["subscriptionType"] as? String == "max"
            && (oauth?["expiresAt"] as? Double ?? 0) > Date().timeIntervalSince1970 * 1000
            && fallback?["refreshToken"] as? String == "original-refresh"
            && ClaudeUsageClient.issue(for: 401) == .signInExpired
            && ClaudeUsageClient.issue(for: 429) == .rateLimited
            && ClaudeUsageClient.issue(for: 500) == .unavailable
    }

    private static func checkNestedRings() -> Bool {
        let now = Date().timeIntervalSince1970
        let weekly = LimitBucket(usedPercent: 30, windowMinutes: 10_080, resetAt: now + 604_800 * 0.9)
        let fiveHour = LimitBucket(usedPercent: 10, windowMinutes: 300, resetAt: now + 18_000 * 0.5)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("uso-ring-check-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: path) }
        guard (try? RingRenderer.writePreview(limits: [BaseLimits(fiveHour: fiveHour, weekly: weekly)], to: path)) != nil,
              let data = try? Data(contentsOf: path), let bitmap = NSBitmapImageRep(data: data),
              let outer = bitmap.colorAt(x: 22, y: 5)?.usingColorSpace(.deviceRGB),
              let inner = bitmap.colorAt(x: 22, y: 13)?.usingColorSpace(.deviceRGB) else { return false }
        return outer.redComponent > outer.greenComponent && inner.greenComponent > inner.redComponent
    }

    private static func checkClaudeDecoding() -> Bool {
        let data = Data(#"{"five_hour":{"utilization":25,"resets_at":"2026-09-30T12:00:00.123Z"},"seven_day":{"utilization":60,"resets_at":"2026-10-05T12:00:00Z"},"seven_day_sonnet":{"utilization":12},"seven_day_opus":null}"#.utf8)
        guard let snapshot = ClaudeUsageClient.decode(data) else { return false }
        let invalid = ClaudeUsageClient.decode(Data(#"{"five_hour":{"utilization":-1},"seven_day":null}"#.utf8))
        return snapshot.baseLimits.fiveHour?.usedPercent == 25
            && snapshot.baseLimits.fiveHour?.windowMinutes == 300
            && snapshot.baseLimits.fiveHour?.resetAt != nil
            && snapshot.baseLimits.weekly?.windowMinutes == 10_080
            && snapshot.baseLimits.weekly?.remainingPercent == 40
            && snapshot.additionalLimits.count == 1
            && invalid?.hasAnyData == false
            && ClaudeUsageClient.decode(Data("[]".utf8)) == nil
            && ClaudeUsageClient.token(from: Data(#"{"claudeAiOauth":{"accessToken":"fixture"}}"#.utf8)) == "fixture"
            && ClaudeUsageClient.token(from: Data(#"{"apiKey":"fixture"}"#.utf8)) == nil
    }

    private static func checkRingSelection() -> Bool {
        let name = "uso-self-check-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else { return false }
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = RingSettings(defaults: defaults)
        guard settings.enabled == UsageRing.allCases else { return false }
        for ring in UsageRing.allCases { settings.set(ring, enabled: false) }
        guard RingSettings(defaults: defaults).enabled.isEmpty else { return false }
        defaults.removeObject(forKey: "enabledUsageProviders")
        defaults.set(["codexWeekly", "claudeFiveHour"], forKey: "enabledUsageRings")
        guard settings.enabled == UsageRing.allCases else { return false }
        for ring in UsageRing.allCases { settings.set(ring, enabled: false) }
        settings.set(.claude, enabled: true)
        settings.set(.codex, enabled: true)
        settings.set(.codex, enabled: true)
        return RingSettings(defaults: defaults).enabled == [.codex, .claude]
    }

    private static func checkRingLayout() -> Bool {
        RingRenderer.statusImage(limits: []).size.width == 22
            && RingRenderer.statusImage(limits: [BaseLimits()]).size.width == 22
            && RingRenderer.statusImage(limits: [BaseLimits(), BaseLimits()]).size.width == 46
            && PacePalette.color(for: LimitBucket(usedPercent: 20, windowMinutes: nil, resetAt: nil)) == NSColor.secondaryLabelColor
    }

    private static func checkAccountSelection() -> Bool {
        let fixture = Data(#"{"tokens":{"access_token":"test-token","account_id":"selected-account"}}"#.utf8)
        guard let credentials = UsageDecoder.credentials(from: fixture),
              credentials.accountID == "selected-account" else {
            return false
        }
        return ["usage", "rate-limit-reset-credits"].allSatisfy { path in
            let url = URL(string: "https://chatgpt.com/backend-api/wham/\(path)")!
            let request = UsageClient.request(to: url, credentials: credentials)
            return request.url == url
                && request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token"
                && request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "selected-account"
        }
    }

    private static func checkLegacyCredentials() -> Bool {
        let fixtures = [
            #"{"tokens":{"access_token":"test-token"}}"#,
            #"{"tokens":{"access_token":"test-token","account_id":""}}"#,
        ]
        let url = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
        return fixtures.allSatisfy { fixture in
            guard let credentials = UsageDecoder.credentials(from: Data(fixture.utf8)) else {
                return false
            }
            let request = UsageClient.request(to: url, credentials: credentials)
            return request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token"
                && request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == nil
        }
            && UsageDecoder.credentials(from: Data(#"{"tokens":{"access_token":""}}"#.utf8)) == nil
            && UsageDecoder.credentials(from: Data(#"{"tokens":{"account_id":"selected-account"}}"#.utf8)) == nil
            && UsageDecoder.credentials(from: Data(#"{}"#.utf8)) == nil
            && UsageDecoder.credentials(from: Data("invalid json".utf8)) == nil
    }

    private static func checkWeeklyPrimaryOnly() -> Bool {
        let weekly = LimitBucket(usedPercent: 12, windowMinutes: 10_080, resetAt: nil)
        let limits = LimitDurationMapper.map(primary: weekly, secondary: nil)
        return limits.weekly == weekly && limits.fiveHour == nil
    }

    private static func checkFiveHourSecondaryOnly() -> Bool {
        let fiveHour = LimitBucket(usedPercent: 23, windowMinutes: 300, resetAt: nil)
        let limits = LimitDurationMapper.map(primary: nil, secondary: fiveHour)
        return limits.fiveHour == fiveHour && limits.weekly == nil
    }

    private static func checkSwappedBuckets() -> Bool {
        let weekly = LimitBucket(usedPercent: 34, windowMinutes: 10_080, resetAt: nil)
        let fiveHour = LimitBucket(usedPercent: 45, windowMinutes: 300, resetAt: nil)
        let limits = LimitDurationMapper.map(primary: weekly, secondary: fiveHour)
        return limits.fiveHour == fiveHour && limits.weekly == weekly
    }

    private static func checkFloatingTolerance() -> Bool {
        let fiveHour = LimitBucket(usedPercent: 56, windowMinutes: 299.999_999, resetAt: nil)
        let weeklyFromSeconds = LimitBucket(usedPercent: 67, windowMinutes: 604_800.000_06 / 60, resetAt: nil)
        let limits = LimitDurationMapper.map(primary: fiveHour, secondary: weeklyFromSeconds)
        return limits.fiveHour == fiveHour && limits.weekly == weeklyFromSeconds
    }

    private static func checkUnknownDuration() -> Bool {
        let unknown = LimitBucket(usedPercent: 78, windowMinutes: 60, resetAt: nil)
        let missing = LimitBucket(usedPercent: 89, windowMinutes: nil, resetAt: nil)
        let limits = LimitDurationMapper.map(primary: unknown, secondary: missing)
        return limits.fiveHour == nil && limits.weekly == nil
    }

    private static func checkRemainingClamping() -> Bool {
        LimitBucket(usedPercent: -25, windowMinutes: nil, resetAt: nil).remainingPercent == 100
            && LimitBucket(usedPercent: 40, windowMinutes: nil, resetAt: nil).remainingPercent == 60
            && LimitBucket(usedPercent: 140, windowMinutes: nil, resetAt: nil).remainingPercent == 0
    }

    private static func checkExhaustedLimitDetection() -> Bool {
        let available = LimitBucket(usedPercent: 99.9, windowMinutes: 300, resetAt: nil)
        let exhausted = LimitBucket(usedPercent: 100, windowMinutes: 10_080, resetAt: nil)
        return !BaseLimits(fiveHour: available, weekly: nil).hasExhaustedLimit
            && BaseLimits(fiveHour: available, weekly: exhausted).hasExhaustedLimit
    }

    private static func checkLiveDecoding() -> Bool {
        let fixture = #"""
        {
          "plan_type": "plus",
          "rate_limit": {
            "primary_window": {"used_percent": 31, "limit_window_seconds": 604800, "reset_at": 2000000000000},
            "secondary": {"used_percent": 41, "window_minutes": 300, "reset_at": 2000000000}
          },
          "additional_rate_limits": [
            {
              "limit_name": "GPT-5 Codex",
              "rate_limit": {"primary": {"used_percent": 51, "window_minutes": 1440, "reset_at": 2000000000}}
            }
          ]
        }
        """#.data(using: .utf8)!
        guard let snapshot = UsageDecoder.liveSnapshot(from: fixture) else {
            return false
        }
        return snapshot.planType == "plus"
            && snapshot.baseLimits.fiveHour?.usedPercent == 41
            && snapshot.baseLimits.weekly?.usedPercent == 31
            && snapshot.additionalLimits == [
                AdditionalLimit(
                    name: "GPT-5 Codex",
                    bucket: LimitBucket(usedPercent: 51, windowMinutes: 1_440, resetAt: 2_000_000_000)
                )
            ]
    }

    private static func checkCachedDecoding() -> Bool {
        let body = #"prefix {"type":"codex.rate_limits","plan_type":"team","rate_limits":{"primary":{"used_percent":18,"window_minutes":300},"secondary_window":{"used_percent":28,"limit_window_seconds":604800}},"additional_rate_limits":{"Review model":{"primary_window":{"used_percent":38,"window_minutes":60}}}} suffix"#
        guard let snapshot = UsageDecoder.cachedSnapshot(fromLogBody: body) else {
            return false
        }
        return snapshot.source == .cached
            && snapshot.availableResetCount == nil
            && snapshot.baseLimits.fiveHour?.usedPercent == 18
            && snapshot.baseLimits.weekly?.usedPercent == 28
            && snapshot.additionalLimits.first?.name == "Review model"
            && snapshot.additionalLimits.first?.bucket.usedPercent == 38
    }

    private static func checkAvailableResets() -> Bool {
        let banked = #"{"rate_limit_reset_credits":{"available_count":2,"applicable_available_count":0}}"#.data(using: .utf8)!
        let zero = #"{"rate_limit_reset_credits":{"available_count":0}}"#.data(using: .utf8)!
        let missing = #"{}"#.data(using: .utf8)!
        let negative = #"{"rate_limit_reset_credits":{"available_count":-1}}"#.data(using: .utf8)!
        return UsageDecoder.liveSnapshot(from: banked)?.availableResetCount == 2
            && UsageDecoder.liveSnapshot(from: banked)?.hasAnyData == true
            && UsageDecoder.liveSnapshot(from: zero)?.availableResetCount == 0
            && UsageDecoder.liveSnapshot(from: missing)?.availableResetCount == nil
            && UsageDecoder.liveSnapshot(from: negative)?.availableResetCount == nil
    }

    private static func checkResetTimestamps() -> Bool {
        let seconds = 2_000_000_000.0
        let milliseconds = seconds * 1_000
        return UsageFormatting.resetDate(seconds) == UsageFormatting.resetDate(milliseconds)
    }

    private static func checkResetExpiries() -> Bool {
        let fixture = #"""
        {"credits": [
          {"reset_type":"codex_rate_limits","status":"available","expires_at":"2026-10-05T04:20:27Z"},
          {"reset_type":"codex_rate_limits","status":"redeemed","expires_at":"2026-10-01T00:00:00Z"},
          {"reset_type":"codex_rate_limits","status":"expired","expires_at":"2026-09-01T00:00:00Z"},
          {"reset_type":"other","status":"available","expires_at":"2026-10-01T00:00:00Z"},
          {"reset_type":"codex_rate_limits","status":"available","expires_at":"2026-10-04T02:35:12.257189Z"},
          {"reset_type":"codex_rate_limits","status":"available","expires_at":null}
        ]}
        """#.data(using: .utf8)!
        guard let resets = UsageDecoder.availableResets(from: fixture), resets.count == 3,
              let first = resets[0].expiresAt,
              let second = resets[1].expiresAt else {
            return false
        }
        return first < second
            && ISO8601DateFormatter().string(from: first) == "2026-10-04T02:35:12Z"
            && ISO8601DateFormatter().string(from: second) == "2026-10-05T04:20:27Z"
            && resets[2].expiresAt == nil
            && UsageDecoder.availableResets(from: Data(#"{"credits":[]}"#.utf8)) == []
            && UsageDecoder.availableResets(from: Data(#"{}"#.utf8)) == nil
    }

    private static func checkUsagePaceCalculation() -> Bool {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let weeklyReset = now.addingTimeInterval(6 * 24 * 60 * 60).timeIntervalSince1970
        let fiveHourReset = now.addingTimeInterval(4 * 60 * 60).timeIntervalSince1970
        let weekly = LimitBucket(usedPercent: 20, windowMinutes: 10_080, resetAt: weeklyReset)
        let fiveHour = LimitBucket(usedPercent: 10, windowMinutes: 300, resetAt: fiveHourReset)

        guard let weeklyPace = UsagePaceCalculator.calculate(bucket: weekly, at: now),
              let fiveHourPace = UsagePaceCalculator.calculate(bucket: fiveHour, at: now) else {
            return false
        }

        return abs(weeklyPace.expectedUsedPercent - (100.0 / 7.0)) < 0.001
            && abs(weeklyPace.differencePercent - (20.0 - 100.0 / 7.0)) < 0.001
            && weeklyPace.isOverPace
            && abs(fiveHourPace.expectedUsedPercent - 20) < 0.001
            && abs(fiveHourPace.differencePercent + 10) < 0.001
            && fiveHourPace.isUnderPace
    }

    private static func checkInvalidUsagePaceWindow() -> Bool {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let expired = LimitBucket(
            usedPercent: 20,
            windowMinutes: 300,
            resetAt: now.addingTimeInterval(-1).timeIntervalSince1970
        )
        let missingReset = LimitBucket(usedPercent: 20, windowMinutes: 300, resetAt: nil)
        return UsagePaceCalculator.calculate(bucket: expired, at: now) == nil
            && UsagePaceCalculator.calculate(bucket: missingReset, at: now) == nil
    }

    private static func checkPaceColorThresholds() -> Bool {
        PacePalette.band(for: UsagePace(usedPercent: 20, expectedUsedPercent: 30)) == .healthy
            && PacePalette.band(for: UsagePace(usedPercent: 30.5, expectedUsedPercent: 30)) == .healthy
            && PacePalette.band(for: UsagePace(usedPercent: 31, expectedUsedPercent: 30)) == .warning
            && PacePalette.band(for: UsagePace(usedPercent: 35, expectedUsedPercent: 30)) == .warning
            && PacePalette.band(for: UsagePace(usedPercent: 35.1, expectedUsedPercent: 30)) == .critical
    }

    private static func checkMenuLimitFilter() -> Bool {
        let bucket = LimitBucket(usedPercent: 20, windowMinutes: 300, resetAt: nil)
        let limits = [
            AdditionalLimit(name: "GPT-5.3-Codex-Spark", bucket: bucket),
            AdditionalLimit(name: "Review model", bucket: bucket),
        ]
        return MenuLimitFilter.visibleAdditionalLimits(limits) == [limits[1]]
    }

    private static func checkSemanticRingRoles() -> Bool {
        var codex = snapshot(source: .live, usedPercent: 25)
        codex.baseLimits.fiveHour = LimitBucket(usedPercent: 10, windowMinutes: 300, resetAt: nil)
        var claude = snapshot(source: .live, usedPercent: 55)
        claude.baseLimits.fiveHour = LimitBucket(usedPercent: 40, windowMinutes: 300, resetAt: nil)
        let first = UsagePresentation(snapshot: codex, issue: nil, isRefreshing: false)
        let second = UsagePresentation(snapshot: claude, issue: nil, isRefreshing: false)
        return UsageRing.codex.limits(codex: first, claude: second) == codex.baseLimits
            && UsageRing.claude.limits(codex: first, claude: second) == claude.baseLimits
    }

    private static func checkCachedRefreshRetainsLive() -> Bool {
        var live = snapshot(source: .live, usedPercent: 20)
        live.availableResetCount = 2
        live.availableResets = [AvailableReset(expiresAt: Date(timeIntervalSince1970: 2_000_000_000))]
        let diskCached = snapshot(source: .cached, usedPercent: 80)
        let resolution = UsageSnapshotPolicy.resolve(
            result: UsageLoadResult(snapshot: diskCached, issue: nil),
            lastValidSnapshot: live
        )
        let explicitIssueResolution = UsageSnapshotPolicy.resolve(
            result: UsageLoadResult(snapshot: diskCached, issue: .notSignedIn),
            lastValidSnapshot: live
        )
        return resolution.presentation.snapshot?.baseLimits.weekly?.usedPercent == 20
            && resolution.presentation.snapshot?.availableResetCount == 2
            && resolution.presentation.snapshot?.availableResets == live.availableResets
            && resolution.presentation.snapshot?.source == .cached
            && resolution.presentation.snapshot?.updatedAt == live.updatedAt
            && resolution.presentation.issue == .offlineCached
            && resolution.lastValidSnapshot == live
            && explicitIssueResolution.presentation.snapshot?.baseLimits.weekly?.usedPercent == 20
            && explicitIssueResolution.presentation.issue == .notSignedIn
    }

    private static func checkInitialCachedSnapshot() -> Bool {
        let diskCached = snapshot(source: .cached, usedPercent: 35)
        let resolution = UsageSnapshotPolicy.resolve(
            result: UsageLoadResult(snapshot: diskCached, issue: .notSignedIn),
            lastValidSnapshot: nil
        )
        return resolution.presentation.snapshot == diskCached
            && resolution.presentation.issue == .notSignedIn
            && resolution.lastValidSnapshot == diskCached
    }

    private static func checkLiveSnapshotReplacement() -> Bool {
        var previous = snapshot(source: .live, usedPercent: 45)
        previous.availableResetCount = 2
        var current = snapshot(source: .live, usedPercent: 15)
        current.availableResetCount = 0
        let resolution = UsageSnapshotPolicy.resolve(
            result: UsageLoadResult(snapshot: current, issue: nil),
            lastValidSnapshot: previous
        )
        return resolution.presentation.snapshot == current
            && resolution.presentation.issue == nil
            && resolution.lastValidSnapshot == current
    }

    private static func snapshot(source: UsageSource, usedPercent: Double) -> UsageSnapshot {
        UsageSnapshot(
            planType: nil,
            baseLimits: BaseLimits(
                fiveHour: nil,
                weekly: LimitBucket(
                    usedPercent: usedPercent,
                    windowMinutes: 10_080,
                    resetAt: nil
                )
            ),
            additionalLimits: [],
            updatedAt: Date(timeIntervalSince1970: usedPercent),
            source: source
        )
    }
}
