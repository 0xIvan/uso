import Foundation
import CryptoKit

struct ClaudeCredentials {
    let document: [String: Any]
    var oauth: [String: Any] { document["claudeAiOauth"] as? [String: Any] ?? [:] }
    var accessToken: String { oauth["accessToken"] as? String ?? "" }
    var expiresAt: Double { oauth["expiresAt"] as? Double ?? 0 }
    var isExpired: Bool { expiresAt > 0 && expiresAt <= Date().timeIntervalSince1970 * 1000 }
}

enum ClaudeCodeSignIn {
    // Claude Code rotates refresh tokens on use, so only Claude Code may renew; a minimal request makes it do so.
    static func renew() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-p", "--safe-mode", "--no-session-persistence", "--tools", "", "--model", "haiku", "--max-turns", "1", "Reply with OK."]
        process.environment = ["HOME": home, "USER": NSUserName(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "DISABLE_AUTOUPDATER": "1"]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completion.signal() }
        guard (try? process.run()) != nil else { return false }
        guard completion.wait(timeout: .now() + 60) == .success else {
            process.terminate()
            return false
        }
        return process.terminationStatus == 0
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
            if result.status == 0 { return try decode(result.data) }
            // Locked/denied Keychain access must not resurrect an obsolete file login.
            guard result.status == 44 else { throw UsageIssue.unavailable }
        }
        let file = directory.appendingPathComponent(".credentials.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try decode(Data(contentsOf: file))
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

    private func decode(_ data: Data) throws -> ClaudeCredentials? {
        guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw UsageIssue.unavailable }
        guard ClaudeUsageClient.token(from: data) != nil else { return nil }
        return ClaudeCredentials(document: document)
    }

    private func security(_ arguments: [String]) -> (status: Int32, data: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completion.signal() }
        guard (try? process.run()) != nil else { return (-1, Data()) }
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
