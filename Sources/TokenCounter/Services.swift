import Foundation

/// Claude Max/Pro session (5h) + weekly usage. Authenticates purely through the in-app
/// browser OAuth login (ClaudeOAuthManager) — no terminal / Claude Code CLI required.
struct ClaudeService: ProviderService, @unchecked Sendable {
    let provider: ProviderID = .claude
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchUsageWindows() async throws -> [UsageWindow] {
        let token: String
        do {
            token = try await ClaudeOAuthManager.shared.validAccessToken(session: session)
        } catch {
            throw ProviderError.missingCredential
        }
        do {
            return try await fetchWindows(token: token)
        } catch ProviderError.authentication {
            if let freshToken = try? await ClaudeOAuthManager.shared.forceRefreshToken(session: session) {
                return try await fetchWindows(token: freshToken)
            }
            throw ProviderError.authentication
        }
    }

    private func fetchWindows(token: String) async throws -> [UsageWindow] {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        let json = try await requestJSON(request, session: session)
        func window(_ key: String, _ label: String) -> UsageWindow? {
            guard let w = json[key] as? [String: Any], let util = number(w["utilization"]) else { return nil }
            return UsageWindow(label: label, remainingPercent: max(0, min(100, 100 - util)), resetsAt: parseDate(w["resets_at"]))
        }
        let windows = [window("five_hour", "5시간 세션"), window("seven_day", "이번 주")].compactMap { $0 }
        guard !windows.isEmpty else { throw ProviderError.invalidResponse }
        return windows
    }
}

/// GPT / Codex usage with TokenCounter-owned browser login; no CLI or auth.json fallback.
struct OpenAIService: ProviderService, @unchecked Sendable {
    let provider: ProviderID = .openAI
    let session: URLSession
    private let oauthManager: OpenAIOAuthManager?

    init(
        session: URLSession = .shared,
        oauthManager: OpenAIOAuthManager? = nil
    ) {
        self.session = session
        self.oauthManager = oauthManager
    }

    @MainActor private func manager() -> OpenAIOAuthManager { oauthManager ?? .shared }

    func fetchUsageWindows() async throws -> [UsageWindow] {
        let manager = await manager()
        let credentials = try await manager.validCredentials(session: session)
        do {
            return try await fetchWindows(accessToken: credentials.accessToken, accountID: credentials.accountID)
        } catch ProviderError.authentication {
            let fresh = try await manager.refreshedCredentials(rejectedToken: credentials.accessToken, session: session)
            // Exactly one retry, also updating the account header from the refreshed claims.
            return try await fetchWindows(accessToken: fresh.accessToken, accountID: fresh.accountID)
        }
    }

    private func fetchWindows(accessToken: String, accountID: String) async throws -> [UsageWindow] {
        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else {
            throw ProviderError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")

        let json = try await requestJSON(request, session: session)
        guard let rateLimit = json["rate_limit"] as? [String: Any] else {
            throw ProviderError.invalidResponse
        }

        let windows = [
            usageWindow(rateLimit["primary_window"], fallbackLabel: "5시간 세션"),
            usageWindow(rateLimit["secondary_window"], fallbackLabel: "이번 주"),
        ].compactMap { $0 }
        // Some plans return only one window. Never fabricate an absent weekly quota.
        guard !windows.isEmpty else { throw ProviderError.invalidResponse }
        return windows
    }

    private func usageWindow(_ value: Any?, fallbackLabel: String) -> UsageWindow? {
        guard let window = value as? [String: Any],
              let usedPercent = number(window["used_percent"]), usedPercent.isFinite else {
            return nil
        }

        let durationMinutes: Double? = {
            if let seconds = number(window["limit_window_seconds"]) { return seconds / 60 }
            return number(window["window_minutes"] ?? window["window_duration_mins"])
        }()
        let label: String
        if let durationMinutes, abs(durationMinutes - 300) <= 60 {
            label = "5시간 세션"
        } else if let durationMinutes, abs(durationMinutes - 10_080) <= 1_440 {
            label = "이번 주"
        } else {
            label = fallbackLabel
        }

        let resetsAt: Date?
        if let seconds = number(window["resets_in_seconds"]) {
            resetsAt = Date().addingTimeInterval(seconds)
        } else {
            resetsAt = parseDate(window["reset_at"] ?? window["resets_at"])
        }

        return UsageWindow(
            label: label,
            remainingPercent: max(0, min(100, 100 - usedPercent)),
            resetsAt: resetsAt
        )
    }
}

/// Gemini credential source (OAuth CLI or Web Session from WKWebView).
enum GeminiCredentialSource: Sendable {
    case antigravity
    case geminiCLI
    case webSession
}

private struct GeminiAccessCredential: Sendable {
    let accessToken: String
    let expiresAt: Date?
    let source: GeminiCredentialSource

    var isUsable: Bool {
        expiresAt.map { Date().addingTimeInterval(30) < $0 } ?? true
    }
}

/// Gemini (Gemini Advanced Web / Antigravity / Gemini CLI) usage windows.
/// Completely avoids macOS Keychain to eliminate password prompts on periodic refresh.
struct GeminiService: ProviderService, @unchecked Sendable {
    let provider: ProviderID = .gemini
    let session: URLSession
    let credsPath: URL?
    let injectedSource: GeminiCredentialSource
    let defaults: UserDefaults

    init(
        session: URLSession = .shared,
        credsPath: URL? = nil,
        injectedSource: GeminiCredentialSource = .antigravity,
        defaults: UserDefaults = .standard
    ) {
        self.session = session
        self.credsPath = credsPath
        self.injectedSource = injectedSource
        self.defaults = defaults
    }

    func fetchUsageWindows() async throws -> [UsageWindow] {
        // 1. If credsPath is explicitly passed (used in unit tests / mocks)
        if let path = credsPath {
            let credential = try await readCredential(from: path)
            switch credential.source {
            case .antigravity:
                return try await fetchAntigravityWindows(token: credential.accessToken)
            case .geminiCLI:
                return try await fetchGeminiCLIWindows(token: credential.accessToken)
            case .webSession:
                return try await fetchGeminiWebWindows(cookieHeader: credential.accessToken)
            }
        }

        // If explicitly configured for web session
        if injectedSource == .webSession {
            if let cookieHeader = defaults.string(forKey: "gemini_session_cookie"), !cookieHeader.isEmpty {
                return try await fetchGeminiWebWindows(cookieHeader: cookieHeader)
            }
            throw ProviderError.missingCredential
        }

        // 2. Primary: Antigravity / Gemini 5-hour and weekly quota
        if let token = await getOrRefreshToken() {
            do {
                return try await fetchAntigravityWindows(token: token)
            } catch ProviderError.authentication {
                defaults.removeObject(forKey: "gemini_access_token")
                if let freshToken = try? await GeminiOAuthManager.shared.forceRefreshToken(session: session) {
                    return try await fetchAntigravityWindows(token: freshToken)
                }
                throw ProviderError.authentication
            }
        }

        // 3. Optional fallback: Web Session
        if let cookieHeader = defaults.string(forKey: "gemini_session_cookie"), !cookieHeader.isEmpty {
            return try await fetchGeminiWebWindows(cookieHeader: cookieHeader)
        }

        throw ProviderError.missingCredential
    }

    // Token comes only from the in-app browser OAuth login (GeminiOAuthManager) — no CLI,
    // no ~/.gemini/oauth_creds.json, no Antigravity Keychain. Matches Claude/OpenAI.
    private func getOrRefreshToken() async -> String? {
        try? await GeminiOAuthManager.shared.validAccessToken(session: session)
    }

    private func readCredential(from path: URL) async throws -> GeminiAccessCredential {
        guard let data = try? Data(contentsOf: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String, !token.isEmpty else {
            throw ProviderError.missingCredential
        }
        let expiry = number(json["expiry_date"]).map {
            Date(timeIntervalSince1970: $0 > 1e11 ? $0 / 1000 : $0)
        }
        let credential = GeminiAccessCredential(
            accessToken: token,
            expiresAt: expiry,
            source: injectedSource
        )
        guard credential.isUsable else {
            throw ProviderError.authentication
        }
        return credential
    }

    func fetchGeminiWebWindows(cookieHeader: String) async throws -> [UsageWindow] {
        guard let url = URL(string: "https://gemini.google.com/app") else {
            throw ProviderError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ProviderError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse
        }

        if http.statusCode == 401 || http.statusCode == 403 || http.url?.host?.contains("accounts.google.com") == true {
            throw ProviderError.authentication
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderError.network("HTTP \(http.statusCode)")
        }

        guard let html = String(data: data, encoding: .utf8) else {
            throw ProviderError.invalidResponse
        }

        let hasAuthIndicator = html.contains("WIZ_global_data")
            || html.contains("BardChatUi")
            || html.contains("SNlM0e")
            || html.contains("cfb2h")

        let isLoginPage = html.contains("Sign in - Google Accounts")
            || http.url?.host?.contains("accounts.google.com") == true

        if isLoginPage || !hasAuthIndicator {
            throw ProviderError.authentication
        }

        return parseGeminiWebQuota(html: html)
    }

    func parseGeminiWebQuota(html: String) -> [UsageWindow] {
        let isRateLimited = html.contains("Gemini Advanced 사용 한도에 도달")
            || html.contains("You've reached your limit for Gemini Advanced")
            || html.contains("reached your current limit for Gemini")
            || html.contains("Advanced 한도에 도달")

        let remaining: Double = isRateLimited ? 0.0 : 100.0
        var resetsAt: Date? = nil

        if isRateLimited {
            if let regex = try? NSRegularExpression(pattern: #"(\d{1,2}:\d{2})"#, options: []) {
                let range = NSRange(html.startIndex..<html.endIndex, in: html)
                if let match = regex.firstMatch(in: html, options: [], range: range),
                   let timeRange = Range(match.range(at: 1), in: html) {
                    let timeStr = String(html[timeRange])
                    let parts = timeStr.split(separator: ":").compactMap { Int($0) }
                    if parts.count == 2 {
                        let now = Date()
                        let cal = Calendar.current
                        if let date = cal.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: now) {
                            resetsAt = date > now ? date : cal.date(byAdding: .day, value: 1, to: date)
                        }
                    }
                }
            }
        }

        return [
            UsageWindow(label: "3시간 세션", remainingPercent: remaining, resetsAt: resetsAt)
        ]
    }

    private func fetchAntigravityWindows(token: String) async throws -> [UsageWindow] {
        let windows = try await fetchRetrieveUserQuotaSummary(token: token)
        guard !windows.isEmpty else { throw ProviderError.invalidResponse }
        return windows
    }

    private func fetchGeminiCLIWindows(token: String) async throws -> [UsageWindow] {
        let userAgent = "GeminiCLI/0.59.0 (darwin; arm64; terminal)"
        var loadRequest = try geminiCLIRequest(method: "loadCodeAssist", token: token, userAgent: userAgent)
        loadRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "metadata": [
                "ideType": "IDE_UNSPECIFIED",
                "platform": "PLATFORM_UNSPECIFIED",
                "pluginType": "GEMINI",
            ],
        ])
        let loadResponse = try await requestJSON(loadRequest, session: session)
        let projectID = (loadResponse["cloudaicompanionProject"] as? String)
            ?? (loadResponse["cloudaicompanionProject"] as? [String: Any])?["id"] as? String
        guard let projectID, !projectID.isEmpty else { throw ProviderError.invalidResponse }

        var quotaRequest = try geminiCLIRequest(method: "retrieveUserQuota", token: token, userAgent: userAgent)
        quotaRequest.httpBody = try JSONSerialization.data(withJSONObject: ["project": projectID])
        let windows = parseQuotaSummary(json: try await requestJSON(quotaRequest, session: session))
        guard !windows.isEmpty else { throw ProviderError.invalidResponse }
        return windows
    }

    private func geminiCLIRequest(method: String, token: String, userAgent: String) throws -> URLRequest {
        guard let url = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:\(method)") else {
            throw ProviderError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    private func fetchRetrieveUserQuotaSummary(token: String) async throws -> [UsageWindow] {
        guard let url = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary") else {
            throw ProviderError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // This internal endpoint authorizes requests using Antigravity's client identity.
        request.setValue(
            "antigravity/cli/1.2.2 (aidev_client; os_type=darwin; arch=arm64; cl=980147163; auth_method=consumer)",
            forHTTPHeaderField: "User-Agent"
        )
        request.httpBody = "{}".data(using: .utf8)

        let json: [String: Any]
        do {
            json = try await requestJSON(request, session: session)
        } catch ProviderError.notFound, ProviderError.network {
            if let fallbackURL = URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary") {
                var fallbackReq = request
                fallbackReq.url = fallbackURL
                json = try await requestJSON(fallbackReq, session: session)
            } else {
                throw ProviderError.invalidResponse
            }
        }

        return parseQuotaSummary(json: json)
    }

    private func parseQuotaSummary(json: [String: Any]) -> [UsageWindow] {
        let rawBuckets: [[String: Any]]
        if let groups = json["groups"] as? [[String: Any]] {
            let geminiGroup = groups.first { group in
                let name = (group["displayName"] as? String ?? "").lowercased()
                if name.contains("gemini") { return true }
                return (group["buckets"] as? [[String: Any]])?.contains {
                    ($0["bucketId"] as? String ?? "").lowercased().contains("gemini")
                } ?? false
            } ?? groups.first
            rawBuckets = geminiGroup?["buckets"] as? [[String: Any]] ?? []
        } else {
            rawBuckets = json["buckets"] as? [[String: Any]] ?? []
        }

        var windows: [UsageWindow] = []
        for b in rawBuckets {
            if let disabled = b["disabled"] as? Bool, disabled { continue }

            let bucketId = (b["bucketId"] as? String ?? "").lowercased()
            let window = (b["window"] as? String ?? "").lowercased()
            let displayName = b["displayName"] as? String ?? ""

            let label: String
            if window == "5h" || bucketId.contains("5h") || displayName.lowercased().contains("five hour") {
                label = "5시간 세션"
            } else if window == "weekly" || bucketId.contains("weekly") || displayName.lowercased().contains("weekly") {
                label = "이번 주"
            } else if !displayName.isEmpty {
                label = displayName
            } else {
                label = "오늘"
            }

            let percent: Double?
            if let fraction = number(b["remainingFraction"]) {
                percent = max(0, min(100, fraction * 100))
            } else if let p = number(b["remainingPercent"]) {
                percent = max(0, min(100, p))
            } else if let rem = number(b["remainingAmount"] ?? b["remaining"]),
                      let total = number(b["totalAmount"] ?? b["limit"]), total > 0 {
                percent = max(0, min(100, (rem / total) * 100))
            } else {
                percent = nil
            }

            guard let finalPercent = percent else { continue }
            let resetDate = parseDate(b["resetTime"] ?? b["resets_at"] ?? b["reset_time"])
            windows.append(UsageWindow(label: label, remainingPercent: finalPercent, resetsAt: resetDate))
        }

        windows.sort { w1, w2 in
            let order = ["5시간 세션": 0, "이번 주": 1]
            let o1 = order[w1.label] ?? 2
            let o2 = order[w2.label] ?? 2
            return o1 < o2
        }

        return windows
    }
}

private func number(_ v: Any?) -> Double? {
    if let d = v as? Double { return d }
    if let i = v as? Int { return Double(i) }
    if let s = v as? String { return Double(s) }
    return nil
}
private func parseDate(_ v: Any?) -> Date? {
    if let d = v as? Double {
        return Date(timeIntervalSince1970: d > 1e11 ? d / 1000.0 : d)
    }
    if let i = v as? Int {
        return Date(timeIntervalSince1970: Double(i) > 1e11 ? Double(i) / 1000.0 : Double(i))
    }
    guard let s = v as? String else { return nil }
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
}

private func requestJSON(_ request: URLRequest, session: URLSession) async throws -> [String: Any] {
    do {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        switch http.statusCode {
        case 200..<300: break
        case 401: throw ProviderError.authentication
        case 403: throw ProviderError.forbidden
        case 404: throw ProviderError.notFound
        case 429: throw ProviderError.rateLimited
        default: throw ProviderError.network("HTTP \(http.statusCode)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ProviderError.invalidResponse }
        return json
    } catch let e as ProviderError { throw e }
    catch { throw ProviderError.network(error.localizedDescription) }
}
