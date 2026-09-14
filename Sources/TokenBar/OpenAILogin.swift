import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation
import WebKit

enum OpenAIOAuthError: LocalizedError {
    case portUnavailable, cancelled, timeout, invalidCallback, stateMismatch, browserUnavailable

    var errorDescription: String? {
        switch self {
        case .portUnavailable: return "로그인 포트 1455를 열 수 없습니다. 다른 Codex 로그인 창을 닫고 다시 시도하세요."
        case .cancelled: return "로그인이 취소되었습니다."
        case .timeout: return "로그인 시간이 초과되었습니다. 다시 시도하세요."
        case .invalidCallback: return "올바르지 않은 OpenAI 인증 응답입니다."
        case .stateMismatch: return "로그인 보안 검증(state)에 실패했습니다."
        case .browserUnavailable: return "로그인 브라우저를 열 수 없습니다. Chrome을 실행한 뒤 다시 시도하세요."
        }
    }
}

/// Verified against Codex 0.154.0's login strings and ServerOptions::new (0x5af = 1455).
/// This is Codex client compatibility, not an independently registered TokenBar OAuth app.
struct OpenAIOAuthFlow {
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let redirectURI = "http://localhost:1455/auth/callback"
    static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    static let scopes = "openid profile email offline_access api.connectors.read api.connectors.invoke"
    let verifier: String
    let state: String

    init(verifier: String? = nil, state: String? = nil) {
        var random = SystemRandomNumberGenerator()
        self.verifier = verifier ?? Self.base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &random) }))
        self.state = state ?? Self.base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &random) }))
    }

    var authorizationURL: URL {
        var url = URLComponents(string: "https://auth.openai.com/oauth/authorize")!
        url.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: Self.clientID),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "scope", value: Self.scopes),
            .init(name: "code_challenge", value: Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "id_token_add_organizations", value: "true"),
            .init(name: "codex_cli_simplified_flow", value: "true"),
            .init(name: "originator", value: "codex_cli_rs"),
        ]
        return url.url!
    }

    static func isCallback(_ url: URL, port: Int = 1455) -> Bool {
        url.scheme == "http" && ["localhost", "127.0.0.1"].contains(url.host ?? "")
            && url.port == port && url.path == "/auth/callback"
            && url.user == nil && url.password == nil && url.fragment == nil
    }

    func authorizationCode(from url: URL) throws -> String {
        guard Self.isCallback(url) else { throw OpenAIOAuthError.invalidCallback }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let states = items.filter { $0.name == "state" }
        guard states.count == 1, states[0].value == state else { throw OpenAIOAuthError.stateMismatch }
        // Never display a server-supplied error_description: it may contain sensitive input.
        if items.contains(where: { $0.name == "error" }) { throw ProviderError.authentication }
        let codes = items.filter { $0.name == "code" }
        guard codes.count == 1, let code = codes[0].value, !code.isEmpty else {
            throw OpenAIOAuthError.invalidCallback
        }
        return code
    }

    func exchangeRequest(code: String) -> URLRequest {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let fields = [
            ("grant_type", "authorization_code"), ("code", code),
            ("redirect_uri", Self.redirectURI), ("client_id", Self.clientID), ("code_verifier", verifier),
        ]
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        request.httpBody = fields.map { key, value in
            key + "=" + value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").data(using: .utf8)
        return request
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// Stored atomically in one UserDefaults value. UserDefaults is NOT encrypted storage.
/// ID-token claims are routing/display metadata only, not proof of identity or entitlement.
struct OpenAIOAuthCredentials: Codable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let accountID: String
    let expiresAt: Date
    let email: String?

    static func parse(_ data: Data, previous: Self? = nil, now: Date = Date()) throws -> Self {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String, !access.isEmpty else {
            throw ProviderError.invalidResponse
        }
        let idClaims = claims(json["id_token"] as? String)
        let accessClaims = claims(access)
        let idAuth = idClaims["https://api.openai.com/auth"] as? [String: Any]
        let accessAuth = accessClaims["https://api.openai.com/auth"] as? [String: Any]
        guard let account = (idAuth?["chatgpt_account_id"] as? String)
            ?? (accessAuth?["chatgpt_account_id"] as? String) ?? previous?.accountID,
              !account.isEmpty, !account.contains("\r"), !account.contains("\n") else {
            throw ProviderError.invalidResponse
        }
        let expiry: Date
        if let seconds = json["expires_in"] as? Double, seconds.isFinite, seconds > 0 {
            expiry = now.addingTimeInterval(seconds)
        } else if let seconds = accessClaims["exp"] as? Double, seconds.isFinite {
            expiry = Date(timeIntervalSince1970: seconds)
        } else {
            // Unknown expiry must not make a token valid forever.
            expiry = now.addingTimeInterval(300)
        }
        let refresh = (json["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Self(accessToken: access, refreshToken: refresh ?? previous?.refreshToken,
                    accountID: account, expiresAt: expiry,
                    email: idClaims["email"] as? String ?? previous?.email)
    }

    private static func claims(_ jwt: String?) -> [String: Any] {
        guard let jwt else { return [:] }
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return [:] }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return json
    }
}

@MainActor
final class OpenAIOAuthManager: ObservableObject {
    static let shared = OpenAIOAuthManager()
    static let credentialsKey = "openai_oauth_credentials"
    @Published private(set) var isLoggedIn: Bool
    @Published private(set) var isAuthenticating = false
    @Published private(set) var authError: String?
    @Published private(set) var userEmail: String?
    private let defaults: UserDefaults
    private var credentials: OpenAIOAuthCredentials?
    private var generation = UUID()
    private var activeFlow: OpenAIOAuthFlow?
    private var activeServer: OpenAIOAuthLoopbackServer?
    private var loginTask: Task<Void, Never>?
    private var refreshTask: Task<OpenAIOAuthCredentials, Error>?
    private var onCompletion: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.credentialsKey),
           let saved = try? JSONDecoder().decode(OpenAIOAuthCredentials.self, from: data),
           !saved.accessToken.isEmpty, !saved.accountID.isEmpty {
            credentials = saved
        }
        isLoggedIn = credentials != nil
        userEmail = credentials?.email
    }

    func signIn(onCompletion: (() -> Void)? = nil) {
        cancelSignIn()
        refreshTask?.cancel()
        refreshTask = nil
        generation = UUID()
        let attempt = generation
        let flow = OpenAIOAuthFlow()
        let server = OpenAIOAuthLoopbackServer()
        authError = nil
        do {
            try server.start(expectedState: flow.state) { [weak self] result in
                Task { @MainActor in
                    guard let self, self.generation == attempt else { return }
                    switch result {
                    case .success(let url): self.receiveCallback(url, attempt: attempt)
                    case .failure(let error): self.finishLogin(error: error)
                    }
                }
            }
        } catch {
            authError = error.localizedDescription
            return
        }
        activeFlow = flow
        activeServer = server
        self.onCompletion = onCompletion
        isAuthenticating = true
        // Present the OpenAI sign-in inside a small in-app window (not an external browser).
        // The redirect to localhost:1455 is still captured by the loopback server started above.
        OpenAILoginWindowController.shared.show(url: flow.authorizationURL)
    }

    func cancelSignIn() {
        generation = UUID()
        loginTask?.cancel()
        loginTask = nil
        activeFlow = nil
        activeServer?.stop()
        activeServer = nil
        onCompletion = nil
        isAuthenticating = false
        OpenAILoginWindowController.shared.close()
    }

    func logout() {
        cancelSignIn()
        refreshTask?.cancel()
        refreshTask = nil
        clearCredentials()
        authError = nil
    }

    private func clearCredentials() {
        credentials = nil
        defaults.removeObject(forKey: Self.credentialsKey)
        defaults.removeObject(forKey: "snapshot.openAI")
        isLoggedIn = false
        userEmail = nil
    }

    func validAccessToken(session: URLSession = .shared) async throws -> String {
        guard let credentials else { throw ProviderError.missingCredential }
        if credentials.expiresAt > Date().addingTimeInterval(60) { return credentials.accessToken }
        return try await forceRefreshToken(session: session)
    }

    func validCredentials(session: URLSession = .shared) async throws -> OpenAIOAuthCredentials {
        let token = try await validAccessToken(session: session)
        guard let credentials, credentials.accessToken == token else { throw ProviderError.authentication }
        return credentials
    }

    func forceRefreshToken(session: URLSession = .shared) async throws -> String {
        try await refreshedCredentials(session: session).accessToken
    }

    func refreshedCredentials(rejectedToken: String? = nil, session: URLSession = .shared) async throws -> OpenAIOAuthCredentials {
        // A poll must not overwrite a browser login that is selecting a different account.
        guard !isAuthenticating else { throw ProviderError.authentication }
        guard let previous = credentials else { throw ProviderError.authentication }
        if let rejectedToken, previous.accessToken != rejectedToken { return previous }
        if let refreshTask { return try await refreshTask.value }
        guard let refresh = previous.refreshToken, !refresh.isEmpty else {
            clearCredentials()
            throw ProviderError.authentication
        }
        let attempt = generation
        let task = Task { @MainActor in
            defer { if self.generation == attempt { self.refreshTask = nil } }
            var request = URLRequest(url: OpenAIOAuthFlow.tokenURL)
            request.httpMethod = "POST"
            request.timeoutInterval = 30
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "grant_type": "refresh_token", "client_id": OpenAIOAuthFlow.clientID, "refresh_token": refresh,
            ])
            do {
                let data = try await Self.tokenResponse(request, session: session)
                try Task.checkCancellation()
                guard self.generation == attempt else { throw CancellationError() }
                let fresh = try OpenAIOAuthCredentials.parse(data, previous: previous)
                try self.save(fresh)
                return fresh
            } catch {
                if self.generation == attempt, error as? ProviderError == .authentication {
                    self.clearCredentials()
                    self.authError = "인증이 만료되었습니다. ChatGPT 계정으로 다시 로그인하세요."
                }
                throw error
            }
        }
        refreshTask = task
        return try await task.value
    }

    private func receiveCallback(_ url: URL, attempt: UUID) {
        guard generation == attempt, let flow = activeFlow, loginTask == nil else { return }
        let code: String
        do { code = try flow.authorizationCode(from: url) }
        catch { finishLogin(error: error); return }
        // Stop accepting callbacks before awaiting the exchange (a code is single-use).
        activeServer?.stop()
        activeServer = nil
        loginTask = Task { @MainActor in
            do {
                let data = try await Self.tokenResponse(flow.exchangeRequest(code: code), session: .shared)
                try Task.checkCancellation()
                guard self.generation == attempt else { return }
                let fresh = try OpenAIOAuthCredentials.parse(data)
                try self.save(fresh)
                self.defaults.removeObject(forKey: "snapshot.openAI")
                self.finishLogin(error: nil)
            } catch {
                guard self.generation == attempt else { return }
                self.finishLogin(error: error)
            }
        }
    }

    private func finishLogin(error: Error?) {
        let completion = error == nil ? onCompletion : nil
        loginTask = nil
        activeFlow = nil
        activeServer?.stop()
        activeServer = nil
        onCompletion = nil
        isAuthenticating = false
        authError = error?.localizedDescription
        OpenAILoginWindowController.shared.close()
        completion?()
    }

    private func save(_ value: OpenAIOAuthCredentials) throws {
        defaults.set(try JSONEncoder().encode(value), forKey: Self.credentialsKey)
        credentials = value
        isLoggedIn = true
        userEmail = value.email
        authError = nil
    }

    private static func tokenResponse(_ request: URLRequest, session: URLSession) async throws -> Data {
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw ProviderError.network("OpenAI 인증 서버 연결 실패") }
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        if [400, 401, 403].contains(http.statusCode) { throw ProviderError.authentication }
        if http.statusCode == 429 { throw ProviderError.rateLimited }
        guard (200..<300).contains(http.statusCode) else { throw ProviderError.network("OpenAI 인증 서버 오류") }
        return data
    }
}

// MARK: - Small in-app login window (embedded WKWebView), like Claude/Gemini.
// Loads the OpenAI authorize URL in a compact window; the final redirect to
// localhost:1455 is served by OpenAIOAuthLoopbackServer (the webview's own request),
// which delivers the code to the manager. window.open() sign-in popups (Continue with
// Google/Apple/Microsoft) are hosted via the uiDelegate.
@MainActor
final class OpenAILoginWindowController: NSObject, NSWindowDelegate {
    static let shared = OpenAILoginWindowController()

    private var window: NSWindow?
    private var webView: WKWebView?
    private var coordinator: OpenAIWebViewCoordinator?

    func show(url: URL) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            webView?.load(URLRequest(url: url))
            return
        }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"

        let coordinator = OpenAIWebViewCoordinator()
        self.coordinator = coordinator
        webView.uiDelegate = coordinator

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "ChatGPT 로그인"
        win.delegate = self
        win.center()
        win.isReleasedWhenClosed = false
        win.contentView = webView

        self.window = win
        self.webView = webView

        webView.load(URLRequest(url: url))

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
        window = nil
        webView = nil
        coordinator = nil
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        webView = nil
        coordinator = nil
        // User dismissed the window before finishing → cancel the pending login.
        if OpenAIOAuthManager.shared.isAuthenticating {
            OpenAIOAuthManager.shared.cancelSignIn()
        }
    }
}

private final class OpenAIWebViewCoordinator: NSObject, WKUIDelegate {
    private var popupWindow: NSWindow?
    private var popupWebView: WKWebView?

    // Host window.open()-created sign-in popups; without this the popup is silently dropped.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.customUserAgent = webView.customUserAgent
        popup.uiDelegate = self

        let width = (windowFeatures.width?.doubleValue).map { max($0, 380) } ?? 460
        let height = (windowFeatures.height?.doubleValue).map { max($0, 560) } ?? 620
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "로그인"
        win.center()
        win.isReleasedWhenClosed = false
        win.contentView = popup

        popupWindow = win
        popupWebView = popup

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        popupWindow?.close()
        popupWindow = nil
        popupWebView = nil
    }
}

// MARK: - Browser OAuth callback (all socket state owned by one serial queue)

final class OpenAIOAuthLoopbackServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "TokenBar.OpenAI.loopback")
    private let closed = DispatchGroup()
    private var source: DispatchSourceRead?
    private var timeout: DispatchWorkItem?
    private var callback: (@Sendable (Result<URL, Error>) -> Void)?
    private var expectedState = ""
    private var port = 0

    @discardableResult
    func start(port: Int = 1455, expectedState: String, timeoutSeconds: Double = 180,
               onCallback: @escaping @Sendable (Result<URL, Error>) -> Void) throws -> Int {
        try queue.sync {
            guard source == nil, (0...65535).contains(port) else { throw OpenAIOAuthError.portUnavailable }
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw OpenAIOAuthError.portUnavailable }
            var initialized = false
            defer { if !initialized { Darwin.close(fd) } }
            var reuse: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(port).bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard bound == 0, listen(fd, 5) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
                throw OpenAIOAuthError.portUnavailable
            }
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
            }
            guard named == 0 else { throw OpenAIOAuthError.portUnavailable }
            self.port = Int(UInt16(bigEndian: address.sin_port))
            self.expectedState = expectedState
            callback = onCallback
            let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            reader.setEventHandler { [weak self] in self?.acceptRequest(fd) }
            closed.enter()
            let closed = self.closed
            reader.setCancelHandler { Darwin.close(fd); closed.leave() }
            source = reader
            let expiry = DispatchWorkItem { [weak self] in
                self?.callback?(.failure(OpenAIOAuthError.timeout))
                self?.stopOnQueue()
            }
            timeout = expiry
            queue.asyncAfter(deadline: .now() + timeoutSeconds, execute: expiry)
            reader.resume()
            initialized = true
            return self.port
        }
    }

    func stop() {
        queue.sync { stopOnQueue() }
        // Ensure an immediate second login can bind the fixed port after cancellation.
        _ = closed.wait(timeout: .now() + 4)
    }

    private func stopOnQueue() {
        callback = nil
        timeout?.cancel(); timeout = nil
        source?.cancel(); source = nil
    }

    private func acceptRequest(_ fd: Int32) {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { return }
        defer { Darwin.close(client) }
        var seconds = timeval(tv_sec: 2, tv_usec: 0)
        var noSignal: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &seconds, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &seconds, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(client, F_SETFL, 0)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 2048)
        let deadline = Date().addingTimeInterval(3)
        while data.count < 16_384, Date() < deadline {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { return }
            data.append(contentsOf: buffer.prefix(count))
            if data.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n")
        let request = (lines.first ?? "").split(separator: " ")
        guard request.count == 3, request[0] == "GET", request[1].hasPrefix("/"),
              let url = URL(string: "http://localhost:\(port)" + request[1]),
              OpenAIOAuthFlow.isCallback(url, port: port) else {
            respond(client, status: "404 Not Found", message: "인증 콜백 경로가 아닙니다."); return
        }
        let hosts = lines.filter { $0.lowercased().hasPrefix("host:") }
            .map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces).lowercased() }
        let states = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name == "state" } ?? []
        guard hosts.count == 1, ["localhost:\(port)", "127.0.0.1:\(port)"].contains(hosts[0]),
              states.count == 1, states[0].value == expectedState else {
            respond(client, status: "400 Bad Request", message: "인증 보안 검증에 실패했습니다."); return
        }
        // A callback is not a completed token exchange. Do not claim success prematurely.
        respond(client, status: "200 OK", message: "인증 응답을 받았습니다. TokenBar에서 로그인 완료 여부를 확인하세요. 이 창을 닫아도 됩니다.")
        callback?(.success(url))
        stopOnQueue()
    }

    private func respond(_ fd: Int32, status: String, message: String) {
        let html = "<!doctype html><meta charset=utf-8><title>TokenBar 로그인</title><p>\(message)</p><script>setTimeout(function(){window.close()},1500)</script>"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        let bytes = Array(response.utf8)
        bytes.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let count = write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                guard count > 0 else { return }
                sent += count
            }
        }
    }
}
