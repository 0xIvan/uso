import CommonCrypto
import CryptoKit
import Foundation

final class GrokUsageClient {
    private let session = URLSession(configuration: .ephemeral)
    private let secretsFile: URL
    private let transport: ((URLRequest) -> (status: Int?, data: Data?))?
    private let keyLock = NSLock()
    private var cachedKey: Data?

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Grok Bot"),
         transport: ((URLRequest) -> (status: Int?, data: Data?))? = nil) {
        secretsFile = directory.appendingPathComponent("sand-secrets.json")
        self.transport = transport
    }

    func load() -> UsageLoadResult {
        do {
            guard let data = try? Data(contentsOf: secretsFile) else {
                return UsageLoadResult(snapshot: nil, issue: .notSignedIn)
            }
            guard let stored = Self.storedAccessToken(from: data) else {
                return UsageLoadResult(snapshot: nil, issue: .notSignedIn)
            }
            let token = try stored.encrypted ? decrypt(stored.value) : stored.value
            if let expiry = Self.expiry(of: token), expiry <= Date() { throw UsageIssue.signInExpired }
            let response = send(Self.request(token: token))
            guard let status = response.status else { throw UsageIssue.unavailable }
            guard (200..<300).contains(status), let body = response.data, var snapshot = Self.decode(body) else {
                throw ClaudeUsageClient.issue(for: status)
            }
            snapshot.accountIdentifier = SHA256.hash(data: Data((stored.account ?? Self.subject(of: token) ?? token).utf8))
                .map { String(format: "%02x", $0) }.joined()
            return UsageLoadResult(snapshot: snapshot, issue: snapshot.hasAnyData ? nil : .noData)
        } catch {
            return UsageLoadResult(snapshot: nil, issue: error as? UsageIssue ?? .unavailable)
        }
    }

    static func storedAccessToken(from data: Data) -> (value: String, encrypted: Bool, account: String?)? {
        guard let secrets = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let tokenKey = "cursor-access-token"
        var account: String?
        var value = secrets[tokenKey] as? String
        if let text = secrets["cursor-accounts"] as? String,
           let accounts = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
           let active = accounts["active"] as? String,
           let entry = (accounts["accounts"] as? [String: Any])?[active] as? [String: Any],
           let token = entry[tokenKey] as? String {
            account = active
            value = token
        }
        guard var value, !value.isEmpty else { return nil }
        let plaintextPrefix = "plaintext:v1:"
        if value.hasPrefix(plaintextPrefix) {
            guard let decoded = Data(base64Encoded: String(value.dropFirst(plaintextPrefix.count))),
                  let token = String(data: decoded, encoding: .utf8), !token.isEmpty else { return nil }
            return (token, false, account)
        }
        let scopedPrefix = "scoped:v1:"
        if value.hasPrefix(scopedPrefix) {
            let rest = value.dropFirst(scopedPrefix.count)
            guard let separator = rest.firstIndex(of: ":") else { return nil }
            account = account ?? String(rest[..<separator])
            value = String(rest[rest.index(after: separator)...])
        }
        return (value, true, account)
    }

    // Electron safeStorage on macOS: "v10" + AES-128-CBC, key derived from the app's Keychain password.
    private func decrypt(_ base64: String) throws -> String {
        guard let sealed = Data(base64Encoded: base64), sealed.starts(with: Data("v10".utf8)) else {
            throw UsageIssue.unavailable
        }
        let key = try safeStorageKey()
        guard let plain = Self.aes128CBCDecrypt(sealed.dropFirst(3), key: key),
              let token = String(data: plain, encoding: .utf8), !token.isEmpty else {
            keyLock.withLock { cachedKey = nil }
            throw UsageIssue.unavailable
        }
        return token
    }

    private func safeStorageKey() throws -> Data {
        keyLock.lock()
        defer { keyLock.unlock() }
        if let cachedKey { return cachedKey }
        // Leaves time to answer the Keychain access prompt the first read shows.
        let result = SecurityCommand.run(["find-generic-password", "-s", "Grok Bot Safe Storage", "-w"], timeout: 60)
        guard result.status == 0 else { throw result.status == 44 ? UsageIssue.notSignedIn : UsageIssue.unavailable }
        let password = String(decoding: result.data, as: UTF8.self).trimmingCharacters(in: .newlines)
        guard !password.isEmpty, let key = Self.pbkdf2(password: password) else { throw UsageIssue.unavailable }
        cachedKey = key
        return key
    }

    private static func pbkdf2(password: String) -> Data? {
        let salt = Array("saltysalt".utf8)
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let status = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, password.utf8.count,
                                          salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                          &key, key.count)
        return status == kCCSuccess ? Data(key) : nil
    }

    private static func aes128CBCDecrypt(_ ciphertext: Data, key: Data) -> Data? {
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var output = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        var length = 0
        let status = ciphertext.withUnsafeBytes { input in
            key.withUnsafeBytes { keyBytes in
                CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress, key.count, iv, input.baseAddress, ciphertext.count,
                        &output, output.count, &length)
            }
        }
        return status == kCCSuccess ? Data(output.prefix(length)) : nil
    }

    private static func claims(of token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        return Data(base64Encoded: payload).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    static func expiry(of token: String) -> Date? {
        (claims(of: token)?["exp"] as? Double).map(Date.init(timeIntervalSince1970:))
    }

    static func subject(of token: String) -> String? {
        claims(of: token)?["sub"] as? String
    }

    static func request(token: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus")!)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("sand", forHTTPHeaderField: "x-cursor-client-type")
        request.setValue("true", forHTTPHeaderField: "x-ghost-mode")
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
        func date(_ key: String) -> Date? {
            guard let text = object[key] as? String else { return nil }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
        }
        var weekly: LimitBucket?
        if object["usesPooledEnterpriseAllowance"] as? Bool != true,
           let used = object["usagePercent"] as? Double, used.isFinite {
            let reset = date("nextResetTimestampUtc")
            var minutes = 10_080.0
            if let reset, let start = date("currentPeriodStart"), reset > start {
                minutes = reset.timeIntervalSince(start) / 60
            }
            weekly = LimitBucket(usedPercent: min(max(used, 0), 100), windowMinutes: minutes,
                                 resetAt: reset?.timeIntervalSince1970)
        }
        let plan = (object["grokPlanLabel"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return UsageSnapshot(planType: plan, baseLimits: BaseLimits(weekly: weekly),
                             additionalLimits: [], updatedAt: Date(), source: .live)
    }
}
