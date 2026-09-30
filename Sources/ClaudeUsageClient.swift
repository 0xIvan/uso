import Foundation
import Darwin

final class ClaudeUsageClient {
    private let session = URLSession(configuration: .ephemeral)

    private struct Credentials {
        var document: [String: Any]
        var path: URL?

        var oauth: [String: Any] { document["claudeAiOauth"] as? [String: Any] ?? [:] }
        var accessToken: String { oauth["accessToken"] as? String ?? "" }
        var refreshToken: String? { oauth["refreshToken"] as? String }
        var expiresAt: Double { oauth["expiresAt"] as? Double ?? 0 }
        var needsRefresh: Bool { expiresAt > 0 && expiresAt <= Date().timeIntervalSince1970 * 1000 + 60_000 }
    }

    func load() -> UsageLoadResult {
        guard var credentials = readCredentials() else {
            return UsageLoadResult(snapshot: nil, issue: .notSignedIn)
        }
        if credentials.needsRefresh {
            switch refresh(credentials) {
            case .success(let updated): credentials = updated
            case .failure(let issue): return UsageLoadResult(snapshot: nil, issue: issue)
            }
        }
        var response = fetchUsage(token: credentials.accessToken)
        if response.status == 401, credentials.refreshToken != nil {
            switch refresh(credentials) {
            case .success(let updated): response = fetchUsage(token: updated.accessToken)
            case .failure(let issue): return UsageLoadResult(snapshot: nil, issue: issue)
            }
        }
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
        request.setValue("Uso/0.2.1", forHTTPHeaderField: "User-Agent")
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
        let candidates = [(readKeychain(), Optional<URL>.none), (try? Data(contentsOf: path), Optional(path))]
        return candidates.compactMap { data, path -> Credentials? in
            guard let data, Self.token(from: data) != nil,
                  let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return Credentials(document: document, path: path)
        }.max { $0.expiresAt < $1.expiresAt }
    }

    private func readKeychain() -> Data? {
        runSecurity(["find-generic-password", "-s", "Claude Code-credentials", "-w"])
    }

    private func runSecurity(_ arguments: [String], input: Data? = nil) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let output = Pipe()
        let stdin = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completion.signal() }
        guard (try? process.run()) != nil else { return nil }
        if let input {
            stdin.fileHandleForWriting.write(input)
            try? stdin.fileHandleForWriting.close()
        }
        guard completion.wait(timeout: .now() + 5) == .success else {
            process.terminate()
            return nil
        }
        return process.terminationStatus == 0 ? output.fileHandleForReading.readDataToEndOfFile() : nil
    }

    private func refresh(_ original: Credentials) -> Result<Credentials, UsageIssue> {
        let lockPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.uso-refresh.lock").path
        let lock = open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { return .failure(.unavailable) }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { return .failure(.unavailable) }
        defer { flock(lock, LOCK_UN) }
        guard let refreshToken = original.refreshToken, !refreshToken.isEmpty else { return .failure(.signInExpired) }
        // A CLI refresh may have completed since the first read; never rotate its old token.
        if let current = readCredentials(), current.accessToken != original.accessToken, !current.needsRefresh {
            return .success(current)
        }
        var request = URLRequest(url: URL(string: "https://platform.claude.com/v1/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token", "refresh_token": refreshToken,
            "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
        ])
        let response = send(request)
        guard let status = response.status else { return .failure(.unavailable) }
        guard (200..<300).contains(status), let data = response.data,
              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = result["access_token"] as? String, !token.isEmpty,
              let expiresIn = result["expires_in"] as? Double, expiresIn > 0 else {
            if status == 400 || status == 401 { return .failure(.signInExpired) }
            return .failure(Self.issue(for: status))
        }
        var updated = original
        updated.document = Self.renewedDocument(original.document, response: result, token: token, expiresIn: expiresIn)
        // Refresh tokens can rotate. Persist the complete document back to its source.
        // Check for another writer before replacing any credential fields.
        guard let current = readCredentials(), current.accessToken == original.accessToken else {
            return readCredentials().map(Result.success) ?? .failure(.unavailable)
        }
        guard save(updated) else { return .failure(.credentialUpdateFailed) }
        return .success(updated)
    }

    private func save(_ credentials: Credentials) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: credentials.document) else { return false }
        if let path = credentials.path {
            do {
                try data.write(to: path, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
                return true
            } catch { return false }
        }
        guard let metadata = runSecurity(["find-generic-password", "-s", "Claude Code-credentials"]),
              let text = String(data: metadata, encoding: .utf8),
              let line = text.components(separatedBy: "\n").first(where: { $0.contains("\"acct\"<blob>=\"") }),
              let start = line.range(of: "<blob>=\"") else { return false }
        let account = String(line[start.upperBound...].dropLast())
        func quote(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        guard let document = String(data: data, encoding: .utf8) else { return false }
        // Send credentials over stdin; never expose tokens in process arguments.
        let command = "add-generic-password -U -s \"Claude Code-credentials\" -a " + quote(account) + " -w " + quote(document) + "\n"
        guard runSecurity(["-i"], input: Data(command.utf8)) != nil,
              let saved = readKeychain() else { return false }
        return Self.token(from: saved) == credentials.accessToken
    }

    static func renewedDocument(_ original: [String: Any], response: [String: Any], token: String, expiresIn: Double) -> [String: Any] {
        var document = original
        var oauth = original["claudeAiOauth"] as? [String: Any] ?? [:]
        oauth["accessToken"] = token
        if let refreshToken = response["refresh_token"] as? String { oauth["refreshToken"] = refreshToken }
        oauth["expiresAt"] = (Date().timeIntervalSince1970 + expiresIn) * 1000
        if let scope = response["scope"] as? String { oauth["scopes"] = scope.split(separator: " ").map(String.init) }
        document["claudeAiOauth"] = oauth
        return document
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
