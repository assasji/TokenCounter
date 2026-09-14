import XCTest
@testable import TokenCounter

/// No real credentials or preference files are read/written by these tests.
final class OpenAITestDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    override func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values.removeValue(forKey: key) }
}

final class OpenAILoginTests: XCTestCase {
    func testAuthorizationURLUsesVerifiedCodexParametersAndPKCE() throws {
        let flow = OpenAIOAuthFlow(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", state: "test-state")
        let url = try XCTUnwrap(URLComponents(url: flow.authorizationURL, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (url.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(url.host, "auth.openai.com")
        XCTAssertEqual(url.path, "/oauth/authorize")
        XCTAssertEqual(items["client_id"], "app_EMoamEEZ73f0CkXaXp7hrann")
        XCTAssertEqual(items["redirect_uri"], "http://localhost:1455/auth/callback")
        XCTAssertEqual(items["code_challenge"], "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["state"], "test-state")
        XCTAssertEqual(items["scope"], OpenAIOAuthFlow.scopes)
        XCTAssertEqual(items["id_token_add_organizations"], "true")
        XCTAssertEqual(items["codex_cli_simplified_flow"], "true")
        XCTAssertNil(items["code_verifier"])
    }

    func testExchangeRequestIsFormEncodedAndEscapesReservedCharacters() throws {
        let request = OpenAIOAuthFlow(verifier: "test-verifier", state: "test-state").exchangeRequest(code: "a+b&c=d /?")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("code=a%2Bb%26c%3Dd%20%2F%3F"))
        let fields = Dictionary(uniqueKeysWithValues: (URLComponents(string: "http://test/?" + body)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(fields["grant_type"], "authorization_code")
        XCTAssertEqual(fields["code_verifier"], "test-verifier")
        XCTAssertEqual(fields["redirect_uri"], OpenAIOAuthFlow.redirectURI)
        XCTAssertNil(fields["state"])
    }

    func testCallbackRejectsWrongOriginPortPathStateAndDuplicates() throws {
        let flow = OpenAIOAuthFlow(state: "correct")
        for url in [
            "https://localhost:1455/auth/callback?code=x&state=correct",
            "http://localhost:1456/auth/callback?code=x&state=correct",
            "http://localhost:1455/auth/callback/evil?code=x&state=correct",
            "http://evil.example:1455/auth/callback?code=x&state=correct",
            "http://localhost:1455/auth/callback?code=x&state=wrong",
            "http://localhost:1455/auth/callback?code=x&state=correct&state=correct",
            "http://localhost:1455/auth/callback?code=x&code=y&state=correct",
            "http://localhost:1455/auth/callback?state=correct",
        ] { XCTAssertThrowsError(try flow.authorizationCode(from: XCTUnwrap(URL(string: url)))) }
        let url = try XCTUnwrap(URL(string: "http://localhost:1455/auth/callback?code=expected&state=correct"))
        XCTAssertEqual(try flow.authorizationCode(from: url), "expected")
    }

    func testOAuthDenialDoesNotExposeServerDescription() throws {
        let flow = OpenAIOAuthFlow(state: "correct")
        let url = try XCTUnwrap(URL(string: "http://localhost:1455/auth/callback?state=correct&error=access_denied&error_description=sensitive-test-value"))
        XCTAssertThrowsError(try flow.authorizationCode(from: url)) { error in
            XCTAssertEqual(error as? ProviderError, .authentication)
            XCTAssertFalse(error.localizedDescription.contains("sensitive-test-value"))
        }
    }

    func testParsesAccountIDAndAccessTokenExpiryFromClaims() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let data = try JSONSerialization.data(withJSONObject: [
            "access_token": try jwt(["exp": now.timeIntervalSince1970 + 120]),
            "id_token": try jwt(["email": "test@example.invalid", "https://api.openai.com/auth": ["chatgpt_account_id": "test-account"]]),
            "refresh_token": "fake-refresh",
        ])
        let result = try OpenAIOAuthCredentials.parse(data, now: now)
        XCTAssertEqual(result.accountID, "test-account")
        XCTAssertEqual(result.email, "test@example.invalid")
        XCTAssertEqual(result.expiresAt, now.addingTimeInterval(120))
    }

    func testRejectsMalformedTokensAndMissingAccountID() throws {
        for body in [#"{"access_token":"invalid"}"#, #"{"access_token":"","id_token":"invalid"}"#, "{}"] {
            XCTAssertThrowsError(try OpenAIOAuthCredentials.parse(Data(body.utf8)))
        }
    }

    @MainActor func testValidTokenUsesOnlyAppCredentialsAndLogoutClearsThem() async throws {
        let defaults = OpenAITestDefaults()
        defaults.set(try JSONEncoder().encode(credentials()), forKey: OpenAIOAuthManager.credentialsKey)
        let manager = OpenAIOAuthManager(defaults: defaults)
        let token = try await manager.validAccessToken()
        XCTAssertEqual(token, "fake-access")
        XCTAssertTrue(manager.isLoggedIn)
        manager.logout()
        XCTAssertNil(defaults.data(forKey: OpenAIOAuthManager.credentialsKey))
        XCTAssertFalse(manager.isLoggedIn)
        do { _ = try await manager.validAccessToken(); XCTFail("Must not fall back to CLI credentials") }
        catch { XCTAssertEqual(error as? ProviderError, .missingCredential) }
    }

    @MainActor func testConcurrentRefreshIsCoalescedAndRotationPersistsAcrossRestart() async throws {
        let defaults = OpenAITestDefaults()
        defaults.set(try JSONEncoder().encode(credentials(expired: true)), forKey: OpenAIOAuthManager.credentialsKey)
        let manager = OpenAIOAuthManager(defaults: defaults)
        var requests = 0
        let session = mockSession { request in
            requests += 1
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            return (200, Data(#"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600}"#.utf8))
        }
        defer { session.invalidateAndCancel() }
        async let a = manager.validAccessToken(session: session)
        async let b = manager.validAccessToken(session: session)
        let tokens = try await [a, b]
        XCTAssertEqual(tokens, ["new-access", "new-access"])
        XCTAssertEqual(requests, 1)
        let restarted = OpenAIOAuthManager(defaults: defaults)
        let saved = try await restarted.validCredentials(session: session)
        XCTAssertEqual(saved.refreshToken, "new-refresh")
        XCTAssertEqual(saved.accountID, "test-account")
        XCTAssertEqual(requests, 1)
    }

    @MainActor func testRejectedRefreshClearsCredentialsButNetworkFailureDoesNot() async throws {
        for status in [400, 500] {
            let defaults = OpenAITestDefaults()
            defaults.set(try JSONEncoder().encode(credentials(expired: true)), forKey: OpenAIOAuthManager.credentialsKey)
            let manager = OpenAIOAuthManager(defaults: defaults)
            let session = mockSession { _ in (status, Data("private-server-body".utf8)) }
            defer { session.invalidateAndCancel() }
            do { _ = try await manager.validAccessToken(session: session); XCTFail("Must fail") }
            catch { XCTAssertFalse(error.localizedDescription.contains("private-server-body")) }
            XCTAssertEqual(manager.isLoggedIn, status == 500)
            XCTAssertEqual(defaults.data(forKey: OpenAIOAuthManager.credentialsKey) != nil, status == 500)
        }
    }

    func testLoopbackIgnoresInvalidStateThenAcceptsValidCallback() async throws {
        let server = OpenAIOAuthLoopbackServer()
        let received = expectation(description: "valid callback")
        let port = try server.start(port: 0, expectedState: "expected") { result in
            if case .success(let url) = result { XCTAssertTrue(url.query?.contains("code=test") == true) }
            else { XCTFail("Expected a valid callback") }
            received.fulfill()
        }
        defer { server.stop() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        for (path, status) in [("/favicon.ico", 404), ("/auth/callback?code=test&state=wrong", 400), ("/auth/callback?code=test&state=expected", 200)] {
            let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)" + path))
            let (data, response) = try await session.data(from: url)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, status)
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("code=test"))
        }
        await fulfillment(of: [received], timeout: 3)
    }

    func testLoopbackTimeoutFinishesWithoutIncomingConnection() async throws {
        let server = OpenAIOAuthLoopbackServer()
        let timedOut = expectation(description: "timeout")
        try server.start(port: 0, expectedState: "expected", timeoutSeconds: 0.05) { result in
            if case .failure(let error) = result { XCTAssertTrue(error is OpenAIOAuthError) }
            else { XCTFail("Expected timeout") }
            timedOut.fulfill()
        }
        defer { server.stop() }
        await fulfillment(of: [timedOut], timeout: 3)
    }

    func testLoopbackCancellationReleasesPortForNextLogin() throws {
        let first = OpenAIOAuthLoopbackServer()
        let port = try first.start(port: 0, expectedState: "first") { _ in XCTFail("Cancelled login must not complete") }
        first.stop()
        let second = OpenAIOAuthLoopbackServer()
        defer { second.stop() }
        XCTAssertEqual(try second.start(port: port, expectedState: "second") { _ in }, port)
    }

    @MainActor func testLogoutDuringRefreshCannotRestoreCredentials() async throws {
        let defaults = OpenAITestDefaults()
        defaults.set(try JSONEncoder().encode(credentials(expired: true)), forKey: OpenAIOAuthManager.credentialsKey)
        let manager = OpenAIOAuthManager(defaults: defaults)
        let started = expectation(description: "refresh started")
        OpenAITestURLProtocol.responseDelay = 0.1
        defer { OpenAITestURLProtocol.responseDelay = 0 }
        let session = mockSession { _ in
            started.fulfill()
            return (200, Data(#"{"access_token":"late-access","expires_in":3600}"#.utf8))
        }
        defer { session.invalidateAndCancel() }
        let task = Task { try await manager.validAccessToken(session: session) }
        await fulfillment(of: [started], timeout: 3)
        manager.logout()
        _ = try? await task.value
        XCTAssertFalse(manager.isLoggedIn)
        XCTAssertNil(defaults.data(forKey: OpenAIOAuthManager.credentialsKey))
    }

    @MainActor func testServiceAcceptsSingleWindowWithoutInventingWeeklyQuota() async throws {
        let defaults = OpenAITestDefaults()
        defaults.set(try JSONEncoder().encode(credentials()), forKey: OpenAIOAuthManager.credentialsKey)
        let manager = OpenAIOAuthManager(defaults: defaults)
        let session = mockSession { _ in
            (200, Data(#"{"rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":18000},"secondary_window":null}}"#.utf8))
        }
        defer { session.invalidateAndCancel() }
        let windows = try await OpenAIService(session: session, oauthManager: manager).fetchUsageWindows()
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].remainingPercent, 90)
    }

    @MainActor func testServiceRetries401OnlyOnce() async throws {
        let defaults = OpenAITestDefaults()
        defaults.set(try JSONEncoder().encode(credentials()), forKey: OpenAIOAuthManager.credentialsKey)
        let manager = OpenAIOAuthManager(defaults: defaults)
        var usageRequests = 0
        var refreshRequests = 0
        let session = mockSession { request in
            if request.url?.host == "auth.openai.com" {
                refreshRequests += 1
                return (200, Data(#"{"access_token":"new-access","expires_in":3600}"#.utf8))
            }
            usageRequests += 1
            return (401, Data())
        }
        defer { session.invalidateAndCancel() }
        do { _ = try await OpenAIService(session: session, oauthManager: manager).fetchUsageWindows(); XCTFail("Must fail") }
        catch { XCTAssertEqual(error as? ProviderError, .authentication) }
        XCTAssertEqual(usageRequests, 2)
        XCTAssertEqual(refreshRequests, 1)
    }

    @MainActor func testAccountChangeDiscardsInFlightUsageAndCachedSnapshot() async throws {
        let defaults = OpenAITestDefaults()
        let started = expectation(description: "usage started")
        let service = OpenAIGatedUsageService(started: started)
        let store = MonitorStore(services: [service], defaults: defaults)
        let refresh = Task { await store.refresh() }
        await fulfillment(of: [started], timeout: 3)
        store.invalidateSnapshot(for: .openAI)
        await service.finish()
        await refresh.value
        store.stop()
        XCTAssertTrue(store.snapshots[.openAI]?.windows.isEmpty == true)
        XCTAssertNil(defaults.data(forKey: "snapshot.openAI"))
    }

    private func credentials(expired: Bool = false) -> OpenAIOAuthCredentials {
        OpenAIOAuthCredentials(accessToken: "fake-access", refreshToken: "fake-refresh", accountID: "test-account",
                              expiresAt: Date().addingTimeInterval(expired ? -1 : 3600), email: nil)
    }

    private func jwt(_ claims: [String: Any]) throws -> String {
        "test." + OpenAIOAuthFlow.base64URL(try JSONSerialization.data(withJSONObject: claims)) + ".signature"
    }

    private func mockSession(_ handler: @escaping (URLRequest) throws -> (Int, Data)) -> URLSession {
        OpenAITestURLProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OpenAITestURLProtocol.self]
        return URLSession(configuration: config)
    }
}

private final class OpenAITestURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    static var responseDelay: TimeInterval = 0
    private var pending: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            let delivery = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: data)
                self.client?.urlProtocolDidFinishLoading(self)
            }
            pending = delivery
            if Self.responseDelay > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() + Self.responseDelay, execute: delivery)
            } else { delivery.perform() }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { pending?.cancel() }
}

private actor OpenAIGatedUsageService: ProviderService {
    nonisolated let provider: ProviderID = .openAI
    private let started: XCTestExpectation
    private var continuation: CheckedContinuation<[UsageWindow], Never>?
    init(started: XCTestExpectation) { self.started = started }
    func fetchUsageWindows() async throws -> [UsageWindow] {
        await withCheckedContinuation {
            continuation = $0
            started.fulfill()
        }
    }
    func finish() {
        continuation?.resume(returning: [UsageWindow(label: "old account", remainingPercent: 80, resetsAt: nil)])
        continuation = nil
    }
}
