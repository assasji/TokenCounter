import XCTest
@testable import TokenCounter

final class ProviderServiceTests: XCTestCase {
    func testSnapshotPrimaryIsFirstWindow() {
        let s = ProviderSnapshot(windows: [
            UsageWindow(label: "5시간 세션", remainingPercent: 37, resetsAt: nil),
            UsageWindow(label: "이번 주", remainingPercent: 73, resetsAt: nil),
        ])
        XCTAssertEqual(s.primaryPercent, 37)
    }

    func testEmptySnapshotHasNoPrimary() {
        XCTAssertNil(ProviderSnapshot.empty.primaryPercent)
    }

    @MainActor
    func testMonitorKeepsAndPersistsLastGoodValueOnFailure() async throws {
        let suiteName = "TokenCounterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let prior = ProviderSnapshot(
            windows: [UsageWindow(label: "5시간 세션", remainingPercent: 64, resetsAt: nil)],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            error: nil
        )
        defaults.set(try JSONEncoder().encode(prior), forKey: "snapshot.claude")

        let store = MonitorStore(
            services: [FailingProviderService(provider: .claude)],
            defaults: defaults
        )
        await store.refresh()
        store.stop()

        XCTAssertEqual(store.snapshots[.claude]?.primaryPercent, 64)
        XCTAssertNotNil(store.snapshots[.claude]?.error)
        let persistedData = try XCTUnwrap(defaults.data(forKey: "snapshot.claude"))
        let persisted = try JSONDecoder().decode(ProviderSnapshot.self, from: persistedData)
        XCTAssertEqual(persisted.primaryPercent, 64)
        XCTAssertNotNil(persisted.error)
    }

    @MainActor
    func testOpenAIMissingCredentialsThrow() async {
        let manager = OpenAIOAuthManager(defaults: OpenAITestDefaults())
        do {
            _ = try await OpenAIService(oauthManager: manager).fetchUsageWindows()
            XCTFail("Should throw missingCredential")
        } catch {
            XCTAssertEqual(error as? ProviderError, .missingCredential)
        }
    }

    @MainActor
    func testOpenAIUsageParsingAndRequestHeaders() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let mockSession = URLSession(configuration: config)
        let manager = try makeOpenAIManager()

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://chatgpt.com/backend-api/wham/usage")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer mock_access_token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "mock_account_id")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "codex-cli")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = """
            {
                "rate_limit": {
                    "primary_window": {
                        "used_percent": 100,
                        "reset_at": 1789361126,
                        "limit_window_seconds": 18000
                    },
                    "secondary_window": {
                        "used_percent": -5,
                        "reset_at": 1789848407,
                        "limit_window_seconds": 604800
                    }
                }
            }
            """.data(using: .utf8)!
            return (response, data)
        }

        let service = OpenAIService(session: mockSession, oauthManager: manager)
        let windows = try await service.fetchUsageWindows()
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].label, "5시간 세션")
        XCTAssertEqual(windows[0].remainingPercent, 0)
        XCTAssertEqual(windows[0].resetsAt, Date(timeIntervalSince1970: 1789361126))
        XCTAssertEqual(windows[1].label, "이번 주")
        XCTAssertEqual(windows[1].remainingPercent, 100)
        XCTAssertEqual(windows[1].resetsAt, Date(timeIntervalSince1970: 1789848407))
    }

    @MainActor
    func testOpenAIRefreshesOn401AndRetries() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let mockSession = URLSession(configuration: config)
        let manager = try makeOpenAIManager(refreshToken: "mock_refresh_token")

        MockURLProtocol.requestHandler = { request in
            if request.url?.host == "auth.openai.com" {
                XCTAssertEqual(request.url?.path, "/oauth/token")
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
                let body = try XCTUnwrap(requestBodyData(request))
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
                XCTAssertEqual(json["client_id"], "app_EMoamEEZ73f0CkXaXp7hrann")
                XCTAssertEqual(json["grant_type"], "refresh_token")
                XCTAssertEqual(json["refresh_token"], "mock_refresh_token")
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, #"{"access_token":"refreshed_access_token"}"#.data(using: .utf8)!)
            }

            let auth = request.value(forHTTPHeaderField: "Authorization")
            if auth == "Bearer mock_access_token" {
                let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }
            XCTAssertEqual(auth, "Bearer refreshed_access_token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "mock_account_id")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = #"{"rate_limit":{"primary_window":{"used_percent":25,"resets_in_seconds":60,"limit_window_seconds":18000},"secondary_window":{"used_percent":40,"limit_window_seconds":604800}}}"#.data(using: .utf8)!
            return (response, data)
        }

        let startedAt = Date()
        let service = OpenAIService(session: mockSession, oauthManager: manager)
        let windows = try await service.fetchUsageWindows()
        XCTAssertEqual(windows.map(\.remainingPercent), [75, 60])
        let reset = try XCTUnwrap(windows[0].resetsAt)
        XCTAssertGreaterThanOrEqual(reset.timeIntervalSince(startedAt), 59)
        XCTAssertLessThanOrEqual(reset.timeIntervalSince(startedAt), 61)
    }

    @MainActor
    func testOpenAIUnauthorizedWithoutRefreshTokenThrowsAuthentication() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let mockSession = URLSession(configuration: config)
        let manager = try makeOpenAIManager()

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil
            )!
            return (response, Data())
        }

        let service = OpenAIService(session: mockSession, oauthManager: manager)
        do {
            _ = try await service.fetchUsageWindows()
            XCTFail("Should throw authentication")
        } catch {
            XCTAssertEqual(error as? ProviderError, .authentication)
        }
    }

    @MainActor
    private func makeOpenAIManager(refreshToken: String? = nil) throws -> OpenAIOAuthManager {
        let defaults = OpenAITestDefaults()
        let credentials = OpenAIOAuthCredentials(accessToken: "mock_access_token", refreshToken: refreshToken,
            accountID: "mock_account_id", expiresAt: Date().addingTimeInterval(3600), email: nil)
        defaults.set(try JSONEncoder().encode(credentials), forKey: OpenAIOAuthManager.credentialsKey)
        return OpenAIOAuthManager(defaults: defaults)
    }

    func testGeminiMissingCredentialsThrow() async {
        let fakePath = URL(fileURLWithPath: "/tmp/non_existent_gemini_creds_\(UUID().uuidString).json")
        let service = GeminiService(credsPath: fakePath)
        do {
            _ = try await service.fetchUsageWindows()
            XCTFail("Should throw missingCredential")
        } catch {
            XCTAssertEqual(error as? ProviderError, .missingCredential)
        }
    }

    func testGeminiExpiredCredentialDoesNotMakeNetworkRequest() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let mockSession = URLSession(configuration: config)
        let tempCredsURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_creds_\(UUID().uuidString).json")
        let credsJSON = """
        {
            "access_token": "expired_token",
            "expiry_date": \(Int((Date().timeIntervalSince1970 - 60) * 1000))
        }
        """
        try credsJSON.write(to: tempCredsURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempCredsURL) }

        MockURLProtocol.requestHandler = { _ in
            XCTFail("An expired token must not be sent")
            throw URLError(.userAuthenticationRequired)
        }

        do {
            _ = try await GeminiService(session: mockSession, credsPath: tempCredsURL).fetchUsageWindows()
            XCTFail("Should throw authentication")
        } catch {
            XCTAssertEqual(error as? ProviderError, .authentication)
        }
    }

    func testGeminiDoesNotInventQuotaFromTierMetadata() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let mockSession = URLSession(configuration: config)

        let tempCredsURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_creds_\(UUID().uuidString).json")
        let credsJSON = """
        {
            "access_token": "mock_access_token",
            "expiry_date": \(Int((Date().timeIntervalSince1970 + 3600) * 1000))
        }
        """
        try credsJSON.write(to: tempCredsURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempCredsURL) }

        MockURLProtocol.requestHandler = { request in
            XCTAssertTrue(request.url?.absoluteString.contains("retrieveUserQuotaSummary") == true)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            let data = #"{"allowedTiers":[{"id":"standard-tier","name":"Gemini Code Assist"}]}"#.data(using: .utf8)!
            return (response, data)
        }

        let service = GeminiService(session: mockSession, credsPath: tempCredsURL)
        do {
            _ = try await service.fetchUsageWindows()
            XCTFail("Tier metadata must not be reported as 100% remaining")
        } catch {
            XCTAssertEqual(error as? ProviderError, .invalidResponse)
        }
    }

    func testGeminiBucketsParsing() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let mockSession = URLSession(configuration: config)

        let tempCredsURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_creds_\(UUID().uuidString).json")
        let credsJSON = """
        {
            "access_token": "mock_access_token",
            "expiry_date": \(Int((Date().timeIntervalSince1970 + 3600) * 1000))
        }
        """
        try credsJSON.write(to: tempCredsURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempCredsURL) }

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            let data = """
            {
                "buckets": [
                    {
                        "displayName": "오늘",
                        "remainingFraction": 0.42,
                        "resetTime": "2026-09-14T00:00:00Z"
                    }
                ]
            }
            """.data(using: .utf8)!
            return (response, data)
        }

        let service = GeminiService(session: mockSession, credsPath: tempCredsURL)
        let windows = try await service.fetchUsageWindows()
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].label, "오늘")
        XCTAssertEqual(windows[0].remainingPercent, 42.0)
        XCTAssertNotNil(windows[0].resetsAt)
    }

    func testGeminiAuthFailureWithoutRefreshToken() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let mockSession = URLSession(configuration: config)

        let tempCredsURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_creds_\(UUID().uuidString).json")
        let credsJSON = """
        {
            "access_token": "expired_token",
            "expiry_date": \(Int((Date().timeIntervalSince1970 + 3600) * 1000))
        }
        """
        try credsJSON.write(to: tempCredsURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempCredsURL) }

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let service = GeminiService(session: mockSession, credsPath: tempCredsURL)
        do {
            _ = try await service.fetchUsageWindows()
            XCTFail("Should throw authentication error")
        } catch {
            XCTAssertEqual(error as? ProviderError, .authentication)
        }
    }

    func testGeminiRetrieveUserQuotaSummaryParsing() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let mockSession = URLSession(configuration: config)

        let tempCredsURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_creds_\(UUID().uuidString).json")
        let credsJSON = """
        {
            "access_token": "mock_access_token",
            "expiry_date": \(Int((Date().timeIntervalSince1970 + 3600) * 1000))
        }
        """
        try credsJSON.write(to: tempCredsURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempCredsURL) }

        MockURLProtocol.requestHandler = { request in
            guard let url = request.url?.absoluteString else { throw URLError(.badURL) }
            if url.contains("retrieveUserQuotaSummary") {
                XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("antigravity/cli/") == true)
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                let data = """
                {
                    "groups": [
                        {
                            "displayName": "Gemini Models",
                            "buckets": [
                                {
                                    "bucketId": "gemini-weekly",
                                    "displayName": "Weekly Limit Remaining",
                                    "window": "weekly",
                                    "resetTime": "2026-09-20T21:57:48Z",
                                    "remainingFraction": 0.9313
                                },
                                {
                                    "bucketId": "gemini-5h",
                                    "displayName": "Five Hour Limit Remaining",
                                    "window": "5h",
                                    "resetTime": "2026-09-14T02:57:48Z",
                                    "remainingFraction": 0.6380
                                }
                            ]
                        }
                    ]
                }
                """.data(using: .utf8)!
                return (response, data)
            }
            throw URLError(.badServerResponse)
        }

        let service = GeminiService(session: mockSession, credsPath: tempCredsURL)
        let windows = try await service.fetchUsageWindows()
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].label, "5시간 세션")
        XCTAssertEqual(windows[0].remainingPercent, 63.8, accuracy: 0.01)
        XCTAssertEqual(windows[1].label, "이번 주")
        XCTAssertEqual(windows[1].remainingPercent, 93.13, accuracy: 0.01)
    }

    func testGeminiCLIUsesProjectFromLoadCodeAssistForQuota() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let mockSession = URLSession(configuration: config)
        let tempCredsURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_creds_\(UUID().uuidString).json")
        let credsJSON = """
        {
            "access_token": "mock_access_token",
            "expiry_date": \(Int((Date().timeIntervalSince1970 + 3600) * 1000))
        }
        """
        try credsJSON.write(to: tempCredsURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempCredsURL) }

        MockURLProtocol.requestHandler = { request in
            XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("GeminiCLI/") == true)
            let body = try XCTUnwrap(requestBodyData(request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            if request.url?.absoluteString.contains("loadCodeAssist") == true {
                XCTAssertNotNil(json["metadata"])
                return (response, #"{"cloudaicompanionProject":"mock-project"}"#.data(using: .utf8)!)
            }
            XCTAssertTrue(request.url?.absoluteString.contains("retrieveUserQuota") == true)
            XCTAssertEqual(json["project"] as? String, "mock-project")
            return (response, #"{"buckets":[{"modelId":"gemini-model","displayName":"Gemini model","remainingFraction":0.25,"resetTime":"2026-09-14T00:00:00Z"}]}"#.data(using: .utf8)!)
        }

        let service = GeminiService(
            session: mockSession,
            credsPath: tempCredsURL,
            injectedSource: .geminiCLI
        )
        let windows = try await service.fetchUsageWindows()
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].label, "Gemini model")
        XCTAssertEqual(windows[0].remainingPercent, 25)
    }

    func testGeminiWebSessionNormalUsage() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let mockSession = URLSession(configuration: config)

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://gemini.google.com/app")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "__Secure-1PSID=mock_cookie")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!
            let html = "<html><body><script>WIZ_global_data = {};</script><div>Welcome to Gemini Advanced</div></body></html>".data(using: .utf8)!
            return (response, html)
        }

        let suiteName = "TokenCounterTests.GeminiWeb.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("__Secure-1PSID=mock_cookie", forKey: "gemini_session_cookie")

        let service = GeminiService(session: mockSession, injectedSource: .webSession, defaults: defaults)
        let windows = try await service.fetchUsageWindows()
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].label, "3시간 세션")
        XCTAssertEqual(windows[0].remainingPercent, 100.0)
        XCTAssertNil(windows[0].resetsAt)
    }

    func testGeminiWebSessionRateLimited() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let mockSession = URLSession(configuration: config)

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!
            let html = "<html><body><script>WIZ_global_data = {};</script><div>Gemini Advanced 사용 한도에 도달했습니다 18:30 이후에 다시 시도하세요.</div></body></html>".data(using: .utf8)!
            return (response, html)
        }

        let suiteName = "TokenCounterTests.GeminiWeb.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("__Secure-1PSID=mock_cookie", forKey: "gemini_session_cookie")

        let service = GeminiService(session: mockSession, injectedSource: .webSession, defaults: defaults)
        let windows = try await service.fetchUsageWindows()
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].label, "3시간 세션")
        XCTAssertEqual(windows[0].remainingPercent, 0.0)
        XCTAssertNotNil(windows[0].resetsAt)
    }

    func testGeminiWebSessionUnauthenticatedThrowsAuth() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let mockSession = URLSession(configuration: config)

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: URL(string: "https://accounts.google.com/ServiceLogin")!,
                statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!
            let html = "<html><body>Sign in - Google Accounts</body></html>".data(using: .utf8)!
            return (response, html)
        }

        let suiteName = "TokenCounterTests.GeminiWeb.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("__Secure-1PSID=mock_cookie", forKey: "gemini_session_cookie")

        let service = GeminiService(session: mockSession, injectedSource: .webSession, defaults: defaults)
        do {
            _ = try await service.fetchUsageWindows()
            XCTFail("Should throw authentication")
        } catch {
            XCTAssertEqual(error as? ProviderError, .authentication)
        }
    }

    @MainActor
    func testGeminiOAuthValidAccessTokenReturnsCachedWhenValid() async throws {
        let suiteName = "TokenCounterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("valid_token_123", forKey: "gemini_access_token")
        defaults.set(Date().timeIntervalSince1970 + 3600, forKey: "gemini_token_expiry")

        let manager = GeminiOAuthManager(defaults: defaults)
        let token = try await manager.validAccessToken()
        XCTAssertEqual(token, "valid_token_123")
        XCTAssertTrue(manager.isLoggedIn)
    }

    @MainActor
    func testGeminiOAuthRefreshesWhenExpired() async throws {
        let suiteName = "TokenCounterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let mockSession = URLSession(configuration: config)

        defaults.set("expired_token", forKey: "gemini_access_token")
        defaults.set(Date().timeIntervalSince1970 - 100, forKey: "gemini_token_expiry")
        defaults.set("mock_refresh_token", forKey: "gemini_refresh_token")

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.host, "oauth2.googleapis.com")
            XCTAssertEqual(request.url?.path, "/token")
            XCTAssertEqual(request.httpMethod, "POST")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            let data = #"{"access_token":"new_refreshed_token","expires_in":3600}"#.data(using: .utf8)!
            return (response, data)
        }

        let manager = GeminiOAuthManager(defaults: defaults)
        let token = try await manager.validAccessToken(session: mockSession)
        XCTAssertEqual(token, "new_refreshed_token")
        XCTAssertEqual(defaults.string(forKey: "gemini_access_token"), "new_refreshed_token")
        XCTAssertTrue(manager.isLoggedIn)
    }

    @MainActor
    func testGeminiOAuthLogoutClearsUserDefaults() throws {
        let suiteName = "TokenCounterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("token", forKey: "gemini_access_token")
        defaults.set("refresh", forKey: "gemini_refresh_token")
        defaults.set("user@example.invalid", forKey: "gemini_user_email")
        defaults.set(true, forKey: "gemini_is_logged_in")

        let manager = GeminiOAuthManager(defaults: defaults)
        manager.logout()

        XCTAssertFalse(manager.isLoggedIn)
        XCTAssertNil(manager.userEmail)
        XCTAssertNil(defaults.string(forKey: "gemini_access_token"))
        XCTAssertNil(defaults.string(forKey: "gemini_refresh_token"))
        XCTAssertFalse(defaults.bool(forKey: "gemini_is_logged_in"))
    }

    func testOAuthLoopbackServerHandlesCallback() async throws {
        let server = OAuthLoopbackServer()
        let port = try server.start()
        XCTAssertGreaterThan(port, 0)

        Task {
            try await Task.sleep(nanoseconds: 50_000_000)
            guard let url = URL(string: "http://127.0.0.1:\(port)/oauth/callback?code=test_code_abc&state=test_state_xyz") else { return }
            _ = try? await URLSession.shared.data(from: url)
        }

        let (code, state) = try await server.waitForCode()
        XCTAssertEqual(code, "test_code_abc")
        XCTAssertEqual(state, "test_state_xyz")
    }
}

private struct FailingProviderService: ProviderService {
    let provider: ProviderID

    func fetchUsageWindows() async throws -> [UsageWindow] {
        throw ProviderError.authentication
    }
}

private func requestBodyData(_ request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }

    stream.open()
    defer { stream.close() }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 1_024)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 { return nil }
        if count == 0 { break }
        result.append(buffer, count: count)
    }
    return result
}

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
