import Foundation

enum UsageDecoder {
    private struct AuthPayload: Decodable {
        var tokens: AuthTokens?
    }

    private struct AuthTokens: Decodable {
        var access_token: String?
    }

    private struct LivePayload: Decodable {
        var plan_type: String?
        var rate_limit: RatePayload?
        var additional_rate_limits: [AdditionalUsagePayload]?
    }

    private struct EventPayload: Decodable {
        var type: String
        var plan_type: String?
        var rate_limits: RatePayload?
        var additional_rate_limits: [String: RatePayload]?
    }

    private struct AdditionalUsagePayload: Decodable {
        var limit_name: String?
        var metered_feature: String?
        var rate_limit: RatePayload?
    }

    private struct RatePayload: Decodable {
        var primary: BucketPayload?
        var secondary: BucketPayload?
        var primary_window: BucketPayload?
        var secondary_window: BucketPayload?

        var primaryBucket: LimitBucket? {
            (primary ?? primary_window)?.bucket
        }

        var secondaryBucket: LimitBucket? {
            (secondary ?? secondary_window)?.bucket
        }

        var firstBucket: LimitBucket? {
            primaryBucket ?? secondaryBucket
        }
    }

    private struct BucketPayload: Decodable {
        var used_percent: Double?
        var window_minutes: Double?
        var limit_window_seconds: Double?
        var reset_at: Double?

        var bucket: LimitBucket? {
            guard let usedPercent = used_percent else {
                return nil
            }
            let minutes = window_minutes ?? limit_window_seconds.map { $0 / 60.0 }
            return LimitBucket(usedPercent: usedPercent, windowMinutes: minutes, resetAt: reset_at)
        }
    }

    static func accessToken(from data: Data) -> String? {
        guard let payload = try? JSONDecoder().decode(AuthPayload.self, from: data),
              let token = payload.tokens?.access_token,
              !token.isEmpty else {
            return nil
        }
        return token
    }

    static func liveSnapshot(from data: Data, observedAt: Date = Date()) -> UsageSnapshot? {
        guard let payload = try? JSONDecoder().decode(LivePayload.self, from: data) else {
            return nil
        }
        let primary = payload.rate_limit?.primaryBucket
        let secondary = payload.rate_limit?.secondaryBucket
        let additional = (payload.additional_rate_limits ?? []).compactMap { item -> AdditionalLimit? in
            guard let bucket = item.rate_limit?.firstBucket else {
                return nil
            }
            let name = item.limit_name ?? item.metered_feature ?? "Additional"
            return AdditionalLimit(name: name, bucket: bucket)
        }.sorted { left, right in
            left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }

        return UsageSnapshot(
            planType: payload.plan_type,
            baseLimits: LimitDurationMapper.map(primary: primary, secondary: secondary),
            additionalLimits: additional,
            updatedAt: observedAt,
            source: .live
        )
    }

    static func cachedSnapshot(fromLogBody body: String, observedAt: Date = Date()) -> UsageSnapshot? {
        guard let data = extractRateLimitEvent(from: body),
              let payload = try? JSONDecoder().decode(EventPayload.self, from: data),
              payload.type == "codex.rate_limits" else {
            return nil
        }
        let primary = payload.rate_limits?.primaryBucket
        let secondary = payload.rate_limits?.secondaryBucket
        let additional = (payload.additional_rate_limits ?? [:]).compactMap { name, payload -> AdditionalLimit? in
            guard let bucket = payload.firstBucket else {
                return nil
            }
            return AdditionalLimit(name: name, bucket: bucket)
        }.sorted { left, right in
            left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }

        return UsageSnapshot(
            planType: payload.plan_type,
            baseLimits: LimitDurationMapper.map(primary: primary, secondary: secondary),
            additionalLimits: additional,
            updatedAt: observedAt,
            source: .cached
        )
    }

    private static func extractRateLimitEvent(from body: String) -> Data? {
        guard let marker = body.range(of: "codex.rate_limits") else {
            return nil
        }

        var candidate = marker.lowerBound
        while candidate > body.startIndex {
            candidate = body.index(before: candidate)
            guard body[candidate] == "{" else {
                continue
            }
            if let object = balancedObject(in: body, startingAt: candidate),
               let data = object.data(using: .utf8),
               let payload = try? JSONDecoder().decode(EventPayload.self, from: data),
               payload.type == "codex.rate_limits" {
                return data
            }
        }
        return nil
    }

    private static func balancedObject(in text: String, startingAt start: String.Index) -> String? {
        var depth = 0
        var isInsideString = false
        var isEscaping = false
        var index = start

        while index < text.endIndex {
            let character = text[index]
            if isInsideString {
                if isEscaping {
                    isEscaping = false
                } else if character == "\\" {
                    isEscaping = true
                } else if character == "\"" {
                    isInsideString = false
                }
            } else if character == "\"" {
                isInsideString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    let end = text.index(after: index)
                    return String(text[start..<end])
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
