import Foundation
import UserNotifications

struct UsageResetNotice {
    let title: String
    let body: String
}

final class UsageResetChecker {
    private struct Reading: Codable {
        var accountIdentifier: String
        var planType: String?
        var updatedAt: Date
        var remaining: [String: Double]
        var resetCount: Int?
        var resetIDs: [String]?
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func check(_ snapshot: UsageSnapshot, provider: UsageRing, notify: Bool) -> [UsageResetNotice] {
        guard snapshot.source == .live, let accountIdentifier = snapshot.accountIdentifier else { return [] }
        let key = "\(provider.rawValue)ResetNotificationReading"
        let previous = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Reading.self, from: $0) }
        if let previous, previous.accountIdentifier == accountIdentifier, snapshot.updatedAt <= previous.updatedAt { return [] }
        let sameAccount = previous?.accountIdentifier == accountIdentifier
        let comparable = sameAccount && previous?.planType == snapshot.planType
        var limits: [String: (label: String, remaining: Double)] = [:]
        for (name, label, bucket) in [("5-hour", "5h", snapshot.baseLimits.fiveHour), ("weekly", "weekly", snapshot.baseLimits.weekly)] {
            if let bucket, bucket.usedPercent.isFinite { limits[name] = (label, bucket.remainingPercent) }
        }
        for limit in MenuLimitFilter.visibleAdditionalLimits(snapshot.additionalLimits) where limit.bucket.usedPercent.isFinite {
            limits["\(limit.name) limit"] = (limit.name, limit.bucket.remainingPercent)
        }
        let remaining = limits.mapValues(\.remaining)
        var notices: [UsageResetNotice] = []
        if notify, comparable, let previous {
            for name in remaining.keys.sorted() {
                if let before = previous.remaining[name], let limit = limits[name], limit.remaining > before {
                    let change = limit.remaining.rounded() >= 100 ? "reset" : "increased"
                    notices.append(UsageResetNotice(title: "\(provider.title) \(limit.label) limit \(change)!",
                                                    body: "\(UsageFormatting.percent(before)) → \(UsageFormatting.percent(limit.remaining)) remaining."))
                }
            }
        }
        let count = provider == .codex ? snapshot.availableResetCount : nil
        let ids = (provider == .codex ? snapshot.availableResets : nil).map { resets in
            resets.map { $0.id ?? $0.expiresAt.map { "expiry.\($0.timeIntervalSince1970)" } ?? "unknown" }
        }
        if notify, sameAccount, let previous, let count, let before = previous.resetCount {
            var added = max(0, count - before)
            if let ids, let oldIDs = previous.resetIDs {
                var unmatched = oldIDs
                let newIDs = ids.filter { id in
                    if let index = unmatched.firstIndex(of: id) {
                        unmatched.remove(at: index)
                        return false
                    }
                    return true
                }
                added = max(added, newIDs.count)
            }
            if added > 0 {
                notices.append(UsageResetNotice(title: "Codex reset available!",
                                                body: "\(added) new Codex reset\(added == 1 ? "" : "s") available to redeem."))
            }
        }
        var nextRemaining = comparable ? previous?.remaining ?? [:] : [:]
        nextRemaining.merge(remaining) { _, current in current }
        let nextIDs = ids ?? (sameAccount && (count == nil || count == previous?.resetCount) ? previous?.resetIDs : nil)
        let reading = Reading(accountIdentifier: accountIdentifier, planType: snapshot.planType,
                              updatedAt: snapshot.updatedAt, remaining: nextRemaining,
                              resetCount: count ?? (sameAccount ? previous?.resetCount : nil),
                              resetIDs: nextIDs)
        if let data = try? JSONEncoder().encode(reading) { defaults.set(data, forKey: key) }
        return notices
    }
}

final class ResetNotifications: NSObject, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter
    private let checker: UsageResetChecker
    private var generation = 0
    private var requestingAuthorization = false
    private var presentations: [UsageRing: UsagePresentation] = [:]
    private var pendingNotices: [UsageRing: [UsageResetNotice]] = [:]
    var onStatusChange: ((String?) -> Void)?

    init(center: UNUserNotificationCenter = .current(), defaults: UserDefaults = .standard) {
        self.center = center
        checker = UsageResetChecker(defaults: defaults)
        super.init()
        center.delegate = self
        center.getPendingNotificationRequests { pending in
            center.removePendingNotificationRequests(withIdentifiers: pending.filter {
                $0.identifier.hasPrefix("usage-reset.")
            }.map(\.identifier))
        }
    }

    func synchronize(settings: RingSettings, codex: UsagePresentation, claude: UsagePresentation) {
        precondition(Thread.isMainThread)
        presentations = [.codex: codex, .claude: claude]
        generation += 1
        let revision = generation
        for provider in UsageRing.allCases {
            guard let presentation = presentations[provider] else { continue }
            let enabled = settings.resetNotificationsEnabled && settings.enabled.contains(provider)
            if let snapshot = presentation.snapshot {
                pendingNotices[provider, default: []] += checker.check(snapshot, provider: provider, notify: enabled)
            }
            if !enabled || presentation.issue == .notSignedIn { pendingNotices.removeValue(forKey: provider) }
        }
        guard settings.resetNotificationsEnabled, !settings.enabled.isEmpty else {
            pendingNotices.removeAll()
            onStatusChange?(nil)
            return
        }
        center.getNotificationSettings { [weak self] authorization in
            DispatchQueue.main.async {
                guard let self, self.generation == revision else { return }
                switch authorization.authorizationStatus {
                case .notDetermined:
                    self.onStatusChange?("Allow notifications when macOS asks.")
                    guard !self.requestingAuthorization else { return }
                    self.requestingAuthorization = true
                    self.center.requestAuthorization(options: [.alert, .sound]) { [weak self] _, error in
                        DispatchQueue.main.async {
                            guard let self else { return }
                            self.requestingAuthorization = false
                            if let error {
                                self.onStatusChange?("Couldn’t enable notifications: \(error.localizedDescription)")
                                return
                            }
                            self.synchronize(settings: settings, codex: self.presentations[.codex] ?? .loading,
                                             claude: self.presentations[.claude] ?? .loading)
                        }
                    }
                case .denied:
                    self.pendingNotices.removeAll()
                    self.onStatusChange?("Allow Uso in System Settings → Notifications.")
                case .authorized, .provisional, .ephemeral:
                    self.onStatusChange?(nil)
                    for provider in UsageRing.allCases {
                        let notices = self.pendingNotices.removeValue(forKey: provider) ?? []
                        for notice in notices {
                            let content = UNMutableNotificationContent()
                            content.title = notice.title
                            content.body = notice.body
                            content.sound = .default
                            let request = UNNotificationRequest(identifier: "\(provider.rawValue)-reset-change.\(UUID().uuidString)", content: content, trigger: nil)
                            self.center.add(request) { [weak self] error in
                                guard let error else { return }
                                DispatchQueue.main.async {
                                    guard let self, self.generation == revision else { return }
                                    self.onStatusChange?("Couldn’t send notification: \(error.localizedDescription)")
                                }
                            }
                        }
                    }
                @unknown default:
                    return
                }
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
