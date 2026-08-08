import Foundation
import SQLite3

final class UsageClient: @unchecked Sendable {
    private let authPath: URL
    private let logsPath: URL
    private let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    init(codexHome: URL) {
        authPath = codexHome.appendingPathComponent("auth.json")
        logsPath = codexHome.appendingPathComponent("logs_2.sqlite")
    }

    func load() -> UsageLoadResult {
        let token = readAccessToken()
        if let token, let live = readLiveUsage(accessToken: token) {
            if live.hasAnyData {
                return UsageLoadResult(snapshot: live, issue: nil)
            }
            return UsageLoadResult(snapshot: live, issue: .noData)
        }

        if let cached = readLatestCachedUsage(), cached.hasAnyData {
            return UsageLoadResult(
                snapshot: cached,
                issue: token == nil ? .notSignedIn : .offlineCached
            )
        }

        return UsageLoadResult(
            snapshot: nil,
            issue: token == nil ? .notSignedIn : .unavailable
        )
    }

    private func readAccessToken() -> String? {
        guard let data = try? Data(contentsOf: authPath) else {
            return nil
        }
        return UsageDecoder.accessToken(from: data)
    }

    private func readLiveUsage(accessToken: String) -> UsageSnapshot? {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        final class ResponseBox: @unchecked Sendable {
            var data: Data?
            var response: URLResponse?
        }

        let responseBox = ResponseBox()
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
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
        return UsageDecoder.liveSnapshot(from: data)
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
