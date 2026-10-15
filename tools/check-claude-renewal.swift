import Foundation
import Darwin

// These checks protect shared login credentials from loss or replacement during renewal races.
@main
struct ClaudeRenewalCheck {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("uso-renewal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent(".credentials.json")
        let store = ClaudeCredentialStore(directory: directory, usesKeychain: false)
        func credentials(_ token: String, expired: Bool = true) -> [String: Any] {
            ["otherProvider": ["keep": true], "claudeAiOauth": [
                "accessToken": token, "refreshToken": "refresh-" + token,
                "expiresAt": Date().addingTimeInterval(expired ? -3600 : 3600).timeIntervalSince1970 * 1000,
                "subscriptionType": "max", "clientId": "fixture-client", "unknownField": "preserve",
            ]]
        }
        func write(_ document: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: document).write(to: path, options: .atomic)
        }
        let renewed: [String: Any] = ["access_token": "fresh", "refresh_token": "rotated", "expires_in": 3600, "scope": "user:profile"]
        let usage = Data(#"{"five_hour":{"utilization":10}}"#.utf8)
        var calls = 0
        try write(credentials("expired"))
        let client = ClaudeUsageClient(store: store) { request in
            calls += 1
            if request.httpMethod == "POST" {
                precondition(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".oauth_refresh.lock").path))
                precondition(FileManager.default.fileExists(atPath: directory.path + ".lock"))
                let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                precondition(body["client_id"] as? String == "fixture-client")
                // A second Uso/CLI refresher must defer rather than rotate the same refresh token.
                let contender = ClaudeUsageClient(store: store) { _ in fatalError("Contending refresh sent a request") }
                precondition(contender.load().issue == .unavailable)
                return (200, try! JSONSerialization.data(withJSONObject: renewed))
            }
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh")
            return (200, usage)
        }
        precondition(client.load().snapshot?.hasAnyData == true && calls == 2)
        let saved = try store.read()!
        precondition(saved.accessToken == "fresh" && saved.refreshToken == "rotated" && !saved.needsRefresh)
        precondition(saved.oauth["unknownField"] as? String == "preserve")
        precondition(saved.document["otherProvider"] != nil)
        let mode = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as! NSNumber
        precondition(mode.intValue == 0o600)
        precondition(store.refreshLocks() != nil)
        print("PASS renewal, token rotation, shared locks, metadata preservation, and private file permissions")

        try write(credentials("original"))
        let concurrentLogin = ClaudeUsageClient(store: store) { request in
            if request.httpMethod == "POST" {
                try! write(credentials("new-login", expired: false))
                return (200, try! JSONSerialization.data(withJSONObject: renewed))
            }
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer new-login")
            return (200, usage)
        }
        precondition(concurrentLogin.load().snapshot != nil)
        precondition(try! store.read()!.accessToken == "new-login")
        print("PASS concurrent login wins over stale renewal response")

        try write(credentials("before-logout"))
        let logout = ClaudeUsageClient(store: store) { _ in
            try! FileManager.default.removeItem(at: path)
            return (200, try! JSONSerialization.data(withJSONObject: renewed))
        }
        precondition(logout.load().issue == .notSignedIn)
        precondition(!FileManager.default.fileExists(atPath: path.path))
        print("PASS logout is never undone by renewal")

        try write(credentials("keep-on-failure"))
        for status in [400, 401, 429, 500] {
            let failing = ClaudeUsageClient(store: store) { _ in (status, Data("{}".utf8)) }
            precondition(failing.load().issue != nil)
            precondition(try! store.read()!.accessToken == "keep-on-failure")
        }
        let offline = ClaudeUsageClient(store: store) { _ in (nil, nil) }
        precondition(offline.load().issue == .unavailable)
        precondition(try! store.read()!.refreshToken == "refresh-keep-on-failure")
        print("PASS network and server failures leave credentials intact")

        try write(credentials("valid", expired: false))
        var requests = 0
        let rejected = ClaudeUsageClient(store: store) { request in
            requests += 1
            if request.httpMethod == "POST" { return (200, try! JSONSerialization.data(withJSONObject: renewed)) }
            return requests == 1 ? (401, Data()) : (200, usage)
        }
        precondition(rejected.load().snapshot != nil && requests == 3)
        print("PASS rejected access token renews and retries once")

        let lockPath = directory.appendingPathComponent("test.lock").path
        var lock: ClaudeCredentialLock? = ClaudeCredentialLock(path: lockPath, lifetime: 60)
        precondition(lock != nil)
        let moved = lockPath + ".old"
        precondition(rename(lockPath, moved) == 0 && mkdir(lockPath, 0o700) == 0)
        precondition(lock?.isOwned == false)
        lock = nil
        precondition(FileManager.default.fileExists(atPath: lockPath))
        try FileManager.default.removeItem(atPath: moved)
        try FileManager.default.removeItem(atPath: lockPath)
        print("PASS lost lock cannot authorize writes or delete another process's lock")
    }
}
