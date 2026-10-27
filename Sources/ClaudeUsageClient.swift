import Foundation

final class ClaudeUsageClient {
    private let session = URLSession(configuration: .ephemeral)

    private let store: ClaudeCredentialStore

    private let transport: ((URLRequest) -> (status: Int?, data: Data?))?

    private let renewSignIn: () -> Bool

    private let renewalLock = NSLock()

    private var lastRenewal = Date.distantPast

    init(store: ClaudeCredentialStore = ClaudeCredentialStore(),
         transport: ((URLRequest) -> (status: Int?, data: Data?))? = nil,
         renewSignIn: @escaping () -> Bool = ClaudeCodeSignIn.renew) {
        self.store = store
        self.transport = transport
        self.renewSignIn = renewSignIn
    }

    func load() -> UsageLoadResult {
        do {
            guard var credentials = try store.read() else {
                return UsageLoadResult(snapshot: nil, issue: .notSignedIn)
            }
            var response = credentials.isExpired ? nil : fetchUsage(token: credentials.accessToken)
            if response == nil || response?.status == 401, renewThroughClaudeCode(),
               let renewed = try store.read(), !renewed.isExpired {
                credentials = renewed
                response = fetchUsage(token: renewed.accessToken)
            }
            guard let response else { throw UsageIssue.signInExpired }
            guard let status = response.status else { throw UsageIssue.unavailable }
            guard (200..<300).contains(status), let data = response.data, var snapshot = Self.decode(data) else {
                throw Self.issue(for: status)
            }
            snapshot.accountIdentifier = store.accountIdentifier(for: credentials)
            snapshot.planType = credentials.oauth["subscriptionType"] as? String
            return UsageLoadResult(snapshot: snapshot, issue: snapshot.hasAnyData ? nil : .noData)
        } catch {
            return UsageLoadResult(snapshot: nil, issue: error as? UsageIssue ?? .unavailable)
        }
    }

    private func renewThroughClaudeCode() -> Bool {
        renewalLock.lock()
        defer { renewalLock.unlock() }
        guard Date().timeIntervalSince(lastRenewal) > 15 * 60 else { return false }
        lastRenewal = Date()
        return renewSignIn()
    }

    private func fetchUsage(token: String) -> (status: Int?, data: Data?) {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        return send(request)
    }

    private func send(_ original: URLRequest) -> (status: Int?, data: Data?) {
        if let transport { return transport(original) }
        var request = original
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        request.setValue("Uso/\(version)", forHTTPHeaderField: "User-Agent")
        final class ResponseBox: @unchecked Sendable {
            var data: Data?
            var response: URLResponse?
        }
        let box = ResponseBox()
        let semaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, _ in
            box.data = data
            box.response = response
            semaphore.signal()
        }
        task.resume()
        guard semaphore.wait(timeout: .now() + 16) == .success else {
            task.cancel()
            return (nil, nil)
        }
        return ((box.response as? HTTPURLResponse)?.statusCode, box.data)
    }

    static func issue(for status: Int) -> UsageIssue {
        switch status {
        case 401: return .signInExpired
        case 429: return .rateLimited
        default: return .unavailable
        }
    }

    static func token(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        return token
    }

    static func decode(_ data: Data) -> UsageSnapshot? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func bucket(_ key: String, minutes: Double) -> LimitBucket? {
            guard let value = object[key] as? [String: Any],
                  let used = value["utilization"] as? Double, used.isFinite, (0...100).contains(used) else { return nil }
            let reset = (value["resets_at"] as? String).flatMap { text -> Date? in
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
            }
            return LimitBucket(usedPercent: used, windowMinutes: minutes, resetAt: reset?.timeIntervalSince1970)
        }
        let additional = object.keys.sorted().filter { $0.hasPrefix("seven_day_") }.compactMap { key -> AdditionalLimit? in
            guard let value = bucket(key, minutes: 10_080) else { return nil }
            return AdditionalLimit(name: key.replacingOccurrences(of: "seven_day_", with: "").replacingOccurrences(of: "_", with: " ").capitalized, bucket: value)
        }
        return UsageSnapshot(planType: nil,
            baseLimits: BaseLimits(fiveHour: bucket("five_hour", minutes: 300), weekly: bucket("seven_day", minutes: 10_080)),
            additionalLimits: additional, updatedAt: Date(), source: .live)
    }
}
