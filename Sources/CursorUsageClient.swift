import CryptoKit
import Foundation
import SQLite3

final class CursorUsageClient {
    private let session = URLSession(configuration: .ephemeral)
    private let stateDatabase: URL
    private let transport: ((URLRequest) -> (status: Int?, data: Data?))?

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage"),
         transport: ((URLRequest) -> (status: Int?, data: Data?))? = nil) {
        stateDatabase = directory.appendingPathComponent("state.vscdb")
        self.transport = transport
    }

    func load() -> UsageLoadResult {
        do {
            guard let token = try storedAccessToken() else {
                return UsageLoadResult(snapshot: nil, issue: .notSignedIn)
            }
            if let expiry = GrokUsageClient.expiry(of: token), expiry <= Date() { throw UsageIssue.signInExpired }
            let response = send(Self.request(token: token))
            guard let status = response.status else { throw UsageIssue.unavailable }
            guard (200..<300).contains(status), let body = response.data, var snapshot = Self.decode(body) else {
                throw ClaudeUsageClient.issue(for: status)
            }
            snapshot.accountIdentifier = SHA256.hash(data: Data((GrokUsageClient.subject(of: token) ?? token).utf8))
                .map { String(format: "%02x", $0) }.joined()
            return UsageLoadResult(snapshot: snapshot, issue: snapshot.hasAnyData ? nil : .noData)
        } catch {
            return UsageLoadResult(snapshot: nil, issue: error as? UsageIssue ?? .unavailable)
        }
    }

    private func storedAccessToken() throws -> String? {
        guard FileManager.default.fileExists(atPath: stateDatabase.path) else { return nil }
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        let uri = "file:\(stateDatabase.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "")?mode=ro"
        guard sqlite3_open_v2(uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { throw UsageIssue.unavailable }
        sqlite3_busy_timeout(database, 2_000)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'", -1, &statement, nil) == SQLITE_OK else {
            throw UsageIssue.unavailable
        }
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            let token = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
            return token.isEmpty ? nil : token
        case SQLITE_DONE: return nil
        default: throw UsageIssue.unavailable
        }
    }

    static func request(token: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
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

    static func decode(_ data: Data) -> UsageSnapshot? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // Connect encodes int64 fields as JSON strings.
        func number(_ value: Any?) -> Double? {
            (value as? String).flatMap(Double.init) ?? value as? Double
        }
        func milliseconds(_ key: String) -> Double? {
            number(object[key]).flatMap { $0 > 0 ? $0 : nil }
        }
        var cycle: LimitBucket?
        if let plan = object["planUsage"] as? [String: Any] {
            let limit = number(plan["limit"]) ?? 0
            let used = number(plan["includedSpend"]).flatMap { limit > 0 ? $0 / limit * 100 : nil }
                ?? number(plan["totalPercentUsed"])
            if let used, used.isFinite {
                let start = milliseconds("billingCycleStart")
                let end = milliseconds("billingCycleEnd")
                let minutes = start.flatMap { start in end.flatMap { $0 > start ? ($0 - start) / 60_000 : nil } }
                cycle = LimitBucket(usedPercent: min(max(used, 0), 100), windowMinutes: minutes,
                                    resetAt: end.map { $0 / 1000 })
            }
        }
        return UsageSnapshot(planType: nil, baseLimits: BaseLimits(weekly: cycle),
                             additionalLimits: [], updatedAt: Date(), source: .live)
    }
}
