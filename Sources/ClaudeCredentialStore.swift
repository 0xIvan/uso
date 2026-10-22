import Foundation
import Darwin
import CryptoKit

struct ClaudeCredentials {
    enum Source { case keychain, file }
    let document: [String: Any]
    let source: Source
    var oauth: [String: Any] { document["claudeAiOauth"] as? [String: Any] ?? [:] }
    var accessToken: String { oauth["accessToken"] as? String ?? "" }
    var refreshToken: String { oauth["refreshToken"] as? String ?? "" }
    var expiresAt: Double { oauth["expiresAt"] as? Double ?? 0 }
    var needsRefresh: Bool { expiresAt > 0 && expiresAt <= Date().timeIntervalSince1970 * 1000 + 60_000 }
}

// Directory locks match Claude Code 2.1.296's proper-lockfile protocol. flock is not compatible.
final class ClaudeCredentialLock {
    private let path: String
    private let descriptor: Int32
    private let identity: stat
    private let lifetime: TimeInterval
    private let queue = DispatchQueue(label: "uso.claude-lock-heartbeat")
    private let heartbeat: DispatchSourceTimer

    init?(path: String, lifetime: TimeInterval) {
        guard mkdir(path, 0o700) == 0 else { return nil }
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        var identity = stat()
        guard descriptor >= 0, fstat(descriptor, &identity) == 0 else {
            if descriptor >= 0 { close(descriptor) }
            rmdir(path)
            return nil
        }
        self.path = path
        self.descriptor = descriptor
        self.identity = identity
        self.lifetime = lifetime
        heartbeat = DispatchSource.makeTimerSource(queue: queue)
        heartbeat.schedule(deadline: .now() + 2, repeating: 2)
        heartbeat.setEventHandler { _ = futimens(descriptor, nil) }
        heartbeat.resume()
    }

    private var matchesIdentity: Bool {
        var current = stat()
        return lstat(path, &current) == 0 && current.st_ino == identity.st_ino && current.st_dev == identity.st_dev
    }

    var isOwned: Bool {
        var current = stat()
        return matchesIdentity && lstat(path, &current) == 0
            && Date().timeIntervalSince1970 - Double(current.st_mtimespec.tv_sec) < lifetime
    }

    deinit {
        heartbeat.cancel()
        queue.sync {}
        // A sleeping process can lose a stale lock. Never remove its replacement.
        if matchesIdentity { rmdir(path) }
        close(descriptor)
    }
}

final class ClaudeCredentialStore {
    private let directory: URL
    private let usesKeychain: Bool

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude"), usesKeychain: Bool = true) {
        self.directory = directory.resolvingSymlinksInPath()
        self.usesKeychain = usesKeychain
    }

    func read() throws -> ClaudeCredentials? {
        if usesKeychain {
            let result = security(["find-generic-password", "-s", "Claude Code-credentials", "-a", NSUserName(), "-w"])
            if result.status == 0 { return try decode(result.data, source: .keychain) }
            // Locked/denied Keychain access must not resurrect an obsolete file login.
            guard result.status == 44 else { throw UsageIssue.unavailable }
        }
        let file = directory.appendingPathComponent(".credentials.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try decode(Data(contentsOf: file), source: .file)
    }

    func accountIdentifier(for credentials: ClaudeCredentials) -> String {
        let config = URL(fileURLWithPath: directory.path + ".json")
        var identity = credentials.accessToken
        if let data = try? Data(contentsOf: config),
           let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let account = document["oauthAccount"] as? [String: Any],
           let accountID = account["accountUuid"] as? String, !accountID.isEmpty {
            identity = accountID + ":" + (account["organizationUuid"] as? String ?? "")
        }
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func decode(_ data: Data, source: ClaudeCredentials.Source) throws -> ClaudeCredentials? {
        guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw UsageIssue.unavailable }
        guard ClaudeUsageClient.token(from: data) != nil else { return nil }
        return ClaudeCredentials(document: document, source: source)
    }

    func refreshLocks() -> [ClaudeCredentialLock]? {
        guard let current = ClaudeCredentialLock(path: directory.appendingPathComponent(".oauth_refresh.lock").path, lifetime: 60),
              let legacy = ClaudeCredentialLock(path: directory.path + ".lock", lifetime: 60) else { return nil }
        return [current, legacy]
    }

    func save(response: [String: Any], replacing original: ClaudeCredentials, refreshLocks: [ClaudeCredentialLock]) throws -> ClaudeCredentials {
        // Claude Code login/logout and other credential mutations use this additional lock.
        var acquired: ClaudeCredentialLock?
        for _ in 0..<25 {
            acquired = ClaudeCredentialLock(path: directory.appendingPathComponent(".storage-write.lock").path, lifetime: 15)
            if acquired != nil { break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        guard let lock = acquired else { throw UsageIssue.unavailable }
        defer { withExtendedLifetime(lock) {} }
        guard let current = try read() else { throw UsageIssue.notSignedIn }
        guard current.source == original.source, current.accessToken == original.accessToken,
              current.refreshToken == original.refreshToken else { return current }
        guard let token = response["access_token"] as? String, !token.isEmpty,
              let expires = response["expires_in"] as? Double, expires.isFinite, expires > 0 else { throw UsageIssue.unavailable }
        var document = current.document
        var oauth = current.oauth
        oauth["accessToken"] = token
        if let refresh = response["refresh_token"] as? String, !refresh.isEmpty { oauth["refreshToken"] = refresh }
        oauth["expiresAt"] = (Date().timeIntervalSince1970 + expires) * 1000
        if let scope = response["scope"] as? String { oauth["scopes"] = scope.split(separator: " ").map(String.init) }
        document["claudeAiOauth"] = oauth
        let data = try JSONSerialization.data(withJSONObject: document)
        guard lock.isOwned, refreshLocks.allSatisfy({ $0.isOwned }) else { throw UsageIssue.unavailable }
        switch current.source {
        case .file:
            // Secure the temporary file before atomically replacing the existing document.
            let temporary = directory.appendingPathComponent(".uso-credentials-" + UUID().uuidString)
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw UsageIssue.unavailable }
            defer { try? FileManager.default.removeItem(at: temporary) }
            try data.write(to: temporary)
            guard lock.isOwned, refreshLocks.allSatisfy({ $0.isOwned }), rename(temporary.path, directory.appendingPathComponent(".credentials.json").path) == 0 else { throw UsageIssue.unavailable }
        case .keychain:
            // Pass secrets via stdin, never argv. Updating preserves the existing Keychain ACL.
            let hex = data.map { String(format: "%02x", $0) }.joined()
            let account = NSUserName().replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let command = "add-generic-password -U -s \"Claude Code-credentials\" -a \"\(account)\" -X \"\(hex)\"\n"
            guard command.utf8.count < 4000, security(["-i"], input: Data(command.utf8)).status == 0 else { throw UsageIssue.unavailable }
        }
        guard let saved = try read() else { throw UsageIssue.unavailable }
        return saved
    }

    private func security(_ arguments: [String], input: Data? = nil) -> (status: Int32, data: Data) {
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
        guard (try? process.run()) != nil else { return (-1, Data()) }
        if let input {
            stdin.fileHandleForWriting.write(input)
            try? stdin.fileHandleForWriting.close()
        }
        // Drain while the process runs so a larger credential document cannot fill the pipe.
        final class Output: @unchecked Sendable { var data = Data() }
        let result = Output()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            result.data = output.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }
        guard completion.wait(timeout: .now() + 5) == .success else {
            process.terminate()
            return (-1, Data())
        }
        guard drained.wait(timeout: .now() + 1) == .success else { return (-1, Data()) }
        return (process.terminationStatus, result.data)
    }
}
