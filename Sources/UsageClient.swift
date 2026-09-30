import Foundation
import SQLite3

final class UsageClient: @unchecked Sendable {
    private let session = URLSession(configuration: .ephemeral)
    private let authPath: URL
    private let logsPath: URL
    private let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private let resetCreditsEndpoint = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!

    init(codexHome: URL) {
        authPath = codexHome.appendingPathComponent("auth.json")
        logsPath = codexHome.appendingPathComponent("logs_2.sqlite")
    }

    func load() -> UsageLoadResult {
        let credentials = readCredentials()
        if let credentials, let live = readLiveUsage(credentials: credentials) {
            if live.hasAnyData {
                return UsageLoadResult(snapshot: live, issue: nil)
            }
            return UsageLoadResult(snapshot: live, issue: .noData)
        }

        if let cached = readLatestCachedUsage(), cached.hasAnyData {
            return UsageLoadResult(
                snapshot: cached,
                issue: credentials == nil ? .notSignedIn : .offlineCached
            )
        }

        return UsageLoadResult(
            snapshot: nil,
            issue: credentials == nil ? .notSignedIn : .unavailable
        )
    }

    private func readCredentials() -> UsageDecoder.Credentials? {
        guard let data = try? Data(contentsOf: authPath) else {
            return nil
        }
        return UsageDecoder.credentials(from: data)
    }

    private func readLiveUsage(credentials: UsageDecoder.Credentials) -> UsageSnapshot? {
        guard let data = readLiveData(from: endpoint, credentials: credentials),
              var snapshot = UsageDecoder.liveSnapshot(from: data) else {
            return nil
        }
        // Expiry details have a separate endpoint; failure must not discard live usage.
        if snapshot.availableResetCount != 0,
           let data = readLiveData(from: resetCreditsEndpoint, credentials: credentials),
           let resets = UsageDecoder.availableResets(from: data) {
            snapshot.availableResets = resets
            snapshot.availableResetCount = resets.count
        }
        return snapshot
    }

    static func request(to url: URL, credentials: UsageDecoder.Credentials) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // The bearer token can span accounts; select the same account as Codex.
        request.setValue(credentials.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        return request
    }

    private func readLiveData(from url: URL, credentials: UsageDecoder.Credentials) -> Data? {
        let request = Self.request(to: url, credentials: credentials)

        final class ResponseBox: @unchecked Sendable {
            var data: Data?
            var response: URLResponse?
        }

        let responseBox = ResponseBox()
        let semaphore = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { data, response, _ in
            responseBox.data = data
            responseBox.response = response
            semaphore.signal()
        }.resume()

        guard semaphore.wait(timeout: .now() + 9) == .success,
              let response = responseBox.response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              let data = responseBox.data else {
            return nil
        }
        return data
    }

    private func readLatestCachedUsage() -> UsageSnapshot? {
        guard FileManager.default.fileExists(atPath: logsPath.path) else {
            return nil
        }

        var database: OpaquePointer?
        guard sqlite3_open_v2(logsPath.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let database else {
            return nil
        }
        defer { sqlite3_close(database) }

        let query = """
        SELECT feedback_log_body
        FROM logs
        WHERE feedback_log_body LIKE '%"type":"codex.rate_limits"%'
        ORDER BY ts DESC, ts_nanos DESC, id DESC
        LIMIT 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0) else {
            return nil
        }
        return UsageDecoder.cachedSnapshot(fromLogBody: String(cString: text))
    }
}
