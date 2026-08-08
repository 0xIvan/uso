import Foundation

enum SelfCheck {
    static func run() -> Bool {
        let checks: [(String, () -> Bool)] = [
            ("weekly in primary only", checkWeeklyPrimaryOnly),
            ("five-hour in secondary only", checkFiveHourSecondaryOnly),
            ("swapped dual buckets", checkSwappedBuckets),
            ("floating duration tolerance", checkFloatingTolerance),
            ("unknown duration stays unknown", checkUnknownDuration),
            ("remaining percentage clamping", checkRemainingClamping),
            ("exhausted limit detection", checkExhaustedLimitDetection),
            ("live decoding variants and additional list", checkLiveDecoding),
            ("cached event and additional dictionary decoding", checkCachedDecoding),
            ("reset timestamp seconds and milliseconds", checkResetTimestamps),
            ("generic usage pace calculation", checkUsagePaceCalculation),
            ("invalid usage pace window is unavailable", checkInvalidUsagePaceWindow),
            ("popover hides only Codex 5.3 Spark", checkPopoverLimitFilter),
            ("popover semantic ring roles", checkSemanticRingRoles),
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
            print("Codex Usage Rings self-check passed (\(checks.count) checks)")
            return true
        }
        fputs("Codex Usage Rings self-check failed (\(failures.count)/\(checks.count))\n", stderr)
        return false
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
            && snapshot.baseLimits.fiveHour?.usedPercent == 18
            && snapshot.baseLimits.weekly?.usedPercent == 28
            && snapshot.additionalLimits.first?.name == "Review model"
            && snapshot.additionalLimits.first?.bucket.usedPercent == 38
    }

    private static func checkResetTimestamps() -> Bool {
        let seconds = 2_000_000_000.0
        let milliseconds = seconds * 1_000
        return UsageFormatting.resetDate(seconds) == UsageFormatting.resetDate(milliseconds)
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

    private static func checkPopoverLimitFilter() -> Bool {
        let bucket = LimitBucket(usedPercent: 20, windowMinutes: 300, resetAt: nil)
        let limits = [
            AdditionalLimit(name: "GPT-5.3-Codex-Spark", bucket: bucket),
            AdditionalLimit(name: "Review model", bucket: bucket),
        ]
        return PopoverLimitFilter.visibleAdditionalLimits(limits) == [limits[1]]
    }

    private static func checkSemanticRingRoles() -> Bool {
        let bucket = LimitBucket(usedPercent: 25, windowMinutes: 300, resetAt: nil)
        let fiveHour = BaseLimitRole.fiveHour.limits(containing: bucket)
        let weekly = BaseLimitRole.weekly.limits(containing: bucket)
        return fiveHour.fiveHour == bucket
            && fiveHour.weekly == nil
            && weekly.fiveHour == nil
            && weekly.weekly == bucket
    }

    private static func checkCachedRefreshRetainsLive() -> Bool {
        let live = snapshot(source: .live, usedPercent: 20)
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
        let previous = snapshot(source: .live, usedPercent: 45)
        let current = snapshot(source: .live, usedPercent: 15)
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
