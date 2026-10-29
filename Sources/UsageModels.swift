import AppKit
import Foundation

struct LimitBucket: Equatable {
    var usedPercent: Double
    var windowMinutes: Double?
    var resetAt: TimeInterval?

    var remainingPercent: Double {
        min(max(100.0 - usedPercent, 0.0), 100.0)
    }
}

struct BaseLimits: Equatable {
    var fiveHour: LimitBucket?
    var weekly: LimitBucket?

    var hasExhaustedLimit: Bool {
        [fiveHour, weekly]
            .compactMap { $0 }
            .contains { $0.remainingPercent <= 0 }
    }
}

struct AdditionalLimit: Equatable {
    var name: String
    var bucket: LimitBucket
}

struct UsagePace: Equatable {
    var usedPercent: Double
    var expectedUsedPercent: Double

    var differencePercent: Double {
        usedPercent - expectedUsedPercent
    }

    var isOverPace: Bool {
        differencePercent > 0.5
    }

    var isUnderPace: Bool {
        differencePercent < -0.5
    }
}

enum UsagePaceCalculator {
    static func calculate(bucket: LimitBucket, at date: Date = Date()) -> UsagePace? {
        guard let windowMinutes = bucket.windowMinutes,
              windowMinutes.isFinite,
              windowMinutes > 0,
              let resetDate = UsageFormatting.resetDate(bucket.resetAt),
              resetDate > date else {
            return nil
        }

        let windowDuration = windowMinutes * 60
        let windowStart = resetDate.addingTimeInterval(-windowDuration)
        guard date >= windowStart else {
            return nil
        }

        let elapsed = date.timeIntervalSince(windowStart)
        let expectedUsedPercent = min(max(elapsed / windowDuration * 100, 0), 100)
        let usedPercent = min(max(bucket.usedPercent, 0), 100)
        return UsagePace(
            usedPercent: usedPercent,
            expectedUsedPercent: expectedUsedPercent
        )
    }
}

enum MenuLimitFilter {
    static func visibleAdditionalLimits(_ limits: [AdditionalLimit]) -> [AdditionalLimit] {
        limits.filter { !isCodexSpark53($0.name) }
    }

    private static func isCodexSpark53(_ name: String) -> Bool {
        let normalized = name.lowercased().filter { $0.isLetter || $0.isNumber }
        return normalized.contains("53")
            && normalized.contains("codex")
            && normalized.contains("spark")
    }
}

enum UsageSource: String, Equatable {
    case live = "Live"
    case cached = "Cached"
}

struct AvailableReset: Equatable {
    var expiresAt: Date?
    var id: String? = nil
}

struct UsageSnapshot: Equatable {
    var planType: String?
    var baseLimits: BaseLimits
    var additionalLimits: [AdditionalLimit]
    var updatedAt: Date
    var source: UsageSource
    var availableResetCount: Int?
    var availableResets: [AvailableReset]?
    var accountIdentifier: String? = nil

    var hasAnyData: Bool {
        baseLimits.fiveHour != nil || baseLimits.weekly != nil || !additionalLimits.isEmpty
            || availableResetCount != nil
    }
}

enum UsageIssue: Error, Equatable {
    case notSignedIn
    case signInExpired
    case rateLimited
    case noData
    case unavailable
    case offlineCached

    var title: String {
        switch self {
        case .signInExpired:
            return "Claude sign-in expired — open Claude Code to renew"
        case .rateLimited:
            return "Claude rate limited — retrying in 5 minutes"
        case .notSignedIn:
            return "Not signed in"
        case .noData:
            return "No usage data available"
        case .unavailable:
            return "Usage is temporarily unavailable"
        case .offlineCached:
            return "Offline — showing cached data"
        }
    }
}

struct UsageLoadResult {
    var snapshot: UsageSnapshot?
    var issue: UsageIssue?
}

struct UsagePresentation {
    var snapshot: UsageSnapshot?
    var issue: UsageIssue?
    var isRefreshing: Bool

    static let loading = UsagePresentation(snapshot: nil, issue: nil, isRefreshing: true)

    var hasSignIn: Bool {
        // A retained cache must not keep a signed-out provider visible.
        issue != .notSignedIn && (snapshot != nil || issue != nil)
    }
}

enum UsageSnapshotPolicy {
    static func resolve(result: UsageLoadResult) -> UsagePresentation {
        guard let snapshot = result.snapshot, snapshot.source == .live,
              snapshot.hasAnyData, result.issue == nil else {
            return UsagePresentation(snapshot: nil, issue: result.issue ?? .unavailable, isRefreshing: false)
        }
        return UsagePresentation(snapshot: snapshot, issue: nil, isRefreshing: false)
    }
}

enum LimitDurationMapper {
    private static let fiveHourMinutes = 300.0
    private static let weeklyMinutes = 10_080.0

    static func map(primary: LimitBucket?, secondary: LimitBucket?) -> BaseLimits {
        var limits = BaseLimits()
        for bucket in [primary, secondary].compactMap({ $0 }) {
            guard let windowMinutes = bucket.windowMinutes else {
                continue
            }
            if limits.fiveHour == nil, approximately(windowMinutes, fiveHourMinutes) {
                limits.fiveHour = bucket
            } else if limits.weekly == nil, approximately(windowMinutes, weeklyMinutes) {
                limits.weekly = bucket
            }
        }
        return limits
    }

    private static func approximately(_ value: Double, _ expected: Double) -> Bool {
        abs(value - expected) <= max(0.01, expected * 0.000_001)
    }
}

enum UsageFormatting {
    static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value.rounded())
    }

    static func resetTime(_ resetAt: TimeInterval?) -> String {
        guard let text = formattedReset(resetAt, includeDate: false) else {
            return "Reset time unavailable"
        }
        return "Resets \(text)"
    }

    static func resetDateText(_ resetAt: TimeInterval?) -> String {
        guard let text = formattedReset(resetAt, includeDate: true) else {
            return "Reset date unavailable"
        }
        return "Resets \(text)"
    }

    static func adaptiveReset(_ bucket: LimitBucket) -> String {
        if let minutes = bucket.windowMinutes, minutes >= 1_440 {
            return resetDateText(bucket.resetAt)
        }
        return resetTime(bucket.resetAt)
    }

    static func limitReached(_ bucket: LimitBucket) -> String {
        guard let text = formattedReset(bucket.resetAt, includeDate: (bucket.windowMinutes ?? 0) >= 1_440) else {
            return "Limit reached · reset time unavailable"
        }
        return "Limit reached · resets \(text)"
    }

    static func paceStatus(_ pace: UsagePace) -> String? {
        guard pace.isOverPace else { return nil }
        return "\(percent(pace.differencePercent)) ahead of pace"
    }

    static func behindPace(_ pace: UsagePace) -> String? {
        guard !pace.isOverPace else { return nil }
        return "\(percent(max(-pace.differencePercent, 0))) behind pace"
    }

    private static func formattedReset(_ resetAt: TimeInterval?, includeDate: Bool) -> String? {
        guard let date = resetDate(resetAt) else { return nil }
        let formatter = DateFormatter()
        if includeDate {
            formatter.setLocalizedDateFormatFromTemplate("dMMMjm")
        } else {
            formatter.timeStyle = .short
            formatter.dateStyle = .none
        }
        return formatter.string(from: date)
    }

    static func updated(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = Calendar.current.isDateInToday(date) ? .none : .short
        return formatter.string(from: date)
    }

    static func resetDate(_ timestamp: TimeInterval?) -> Date? {
        guard var timestamp, timestamp.isFinite, timestamp > 0 else {
            return nil
        }
        if timestamp > 10_000_000_000 {
            timestamp /= 1_000.0
        }
        return Date(timeIntervalSince1970: timestamp)
    }
}

enum RingPalette {
    static func color(forRemaining remaining: Double) -> NSColor {
        if remaining <= 20 {
            return NSColor(calibratedRed: 0.88, green: 0.22, blue: 0.20, alpha: 0.96)
        }
        if remaining <= 50 {
            return NSColor(calibratedRed: 0.92, green: 0.61, blue: 0.16, alpha: 0.96)
        }
        return NSColor(calibratedRed: 0.17, green: 0.62, blue: 0.28, alpha: 0.96)
    }
}

enum UsagePaceBand: Equatable {
    case healthy
    case warning
    case critical
}

enum PacePalette {
    static func color(for bucket: LimitBucket) -> NSColor {
        if bucket.remainingPercent <= 0 { return RingPalette.color(forRemaining: 0) }
        guard let pace = UsagePaceCalculator.calculate(bucket: bucket) else { return .secondaryLabelColor }
        return color(for: pace)
    }

    static func band(for pace: UsagePace) -> UsagePaceBand {
        if pace.differencePercent > 5 {
            return .critical
        }
        if pace.differencePercent > 0.5 {
            return .warning
        }
        return .healthy
    }

    static func color(for pace: UsagePace) -> NSColor {
        switch band(for: pace) {
        case .healthy:
            return NSColor(name: nil) { appearance in
                if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                    return RingPalette.color(forRemaining: 100)
                }
                return NSColor(calibratedRed: 0.08, green: 0.49, blue: 0.20, alpha: 0.98)
            }
        case .warning:
            return RingPalette.color(forRemaining: 50)
        case .critical:
            return RingPalette.color(forRemaining: 20)
        }
    }
}
