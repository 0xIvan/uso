import Foundation

final class ClaudeUsageClient {
    private let session = URLSession(configuration: .ephemeral)

    private struct Credentials {
        var accessToken: String
        var expiresAt: Double

        var isExpired: Bool { expiresAt > 0 && expiresAt <= Date().timeIntervalSince1970 * 1000 }
    }

    func load() -> UsageLoadResult {
        guard let credentials = readCredentials() else {
            return UsageLoadResult(snapshot: nil, issue: .notSignedIn)
        }
        // Claude Code owns token renewal; writing its store can overwrite a concurrent login.
        guard !credentials.isExpired else {
            return UsageLoadResult(snapshot: nil, issue: .signInExpired)
        }
        let response = fetchUsage(token: credentials.accessToken)
        guard let status = response.status else { return UsageLoadResult(snapshot: nil, issue: .unavailable) }
        guard (200..<300).contains(status), let data = response.data, let snapshot = Self.decode(data) else {
            return UsageLoadResult(snapshot: nil, issue: Self.issue(for: status))
        }
        return UsageLoadResult(snapshot: snapshot, issue: snapshot.hasAnyData ? nil : .noData)
    }

    private func fetchUsage(token: String) -> (status: Int?, data: Data?) {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        return send(request)
    }

    private func send(_ original: URLRequest) -> (status: Int?, data: Data?) {
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

    private func readCredentials() -> Credentials? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = home.appendingPathComponent(".claude/.credentials.json")
        return [readKeychain(), try? Data(contentsOf: path)].compactMap { data -> Credentials? in
            guard let data, let token = Self.token(from: data),
                  let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let oauth = document["claudeAiOauth"] as? [String: Any] else { return nil }
            return Credentials(accessToken: token, expiresAt: oauth["expiresAt"] as? Double ?? 0)
        }.max { $0.expiresAt < $1.expiresAt }
    }

    private func readKeychain() -> Data? {
        runSecurity(["find-generic-password", "-s", "Claude Code-credentials", "-w"])
    }

    private func runSecurity(_ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completion.signal() }
        guard (try? process.run()) != nil else { return nil }
        guard completion.wait(timeout: .now() + 5) == .success else {
            process.terminate()
            return nil
        }
        return process.terminationStatus == 0 ? output.fileHandleForReading.readDataToEndOfFile() : nil
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
