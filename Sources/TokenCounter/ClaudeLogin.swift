import Foundation
import AppKit
import CryptoKit
import WebKit

// Self-contained on purpose (own loopback server + window controller) so the existing
// Gemini/OpenAI login code paths are never touched by Claude changes.
enum ClaudeOAuthError: LocalizedError {
    case serverStartFailed(String)
    case serverTimeout
    case cancelled
    case invalidCallback
    case stateMismatch
    case authenticationFailed(String)
    case tokenExchangeFailed(String)

    var errorDescription: String? {
        switch self {
        case .serverStartFailed(let msg): return "로컬 인증 서버 시작 실패: \(msg)"
        case .serverTimeout: return "로그인 시간이 초과되었습니다."
        case .cancelled: return "로그인이 취소되었습니다."
        case .invalidCallback: return "잘못된 인증 응답입니다."
        case .stateMismatch: return "보안 검증(State)에 실패했습니다."
        case .authenticationFailed(let msg): return "인증 실패: \(msg)"
        case .tokenExchangeFailed(let msg): return "토큰 발급 실패: \(msg)"
        }
    }
}

/// Browser-based OAuth login for Claude (claude.ai / Claude Max·Pro account) so users
/// without a terminal / Claude Code CLI install can still authorize TokenCounter.
/// Uses the exact OAuth client_id, authorize/token endpoints, and PKCE flow that the
/// Claude Code CLI itself uses (extracted from the CLI binary's `hRi` config object),
/// so the resulting token works against the same `/api/oauth/usage` endpoint.
@MainActor
final class ClaudeOAuthManager: ObservableObject {
    static let shared = ClaudeOAuthManager()

    // The authorize/token endpoints strictly validate client_id as a UUID (confirmed by
    // a server-side "Input should be a valid UUID" error when a URL-style client_id was
    // tried). This UUID is the one Claude Code CLI uses.
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let authorizeURL = "https://claude.com/cai/oauth/authorize"
    static let tokenURL = "https://platform.claude.com/v1/oauth/token"
    static let scopes = "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"

    private let accessTokenKey = "claude_access_token"
    private let refreshTokenKey = "claude_refresh_token"
    private let tokenExpiryKey = "claude_token_expiry"
    private let loggedInKey = "claude_is_logged_in"

    private let defaults: UserDefaults
    private var activeServer: ClaudeOAuthLoopbackServer?

    @Published private(set) var isLoggedIn: Bool
    @Published private(set) var isAuthenticating: Bool = false
    @Published private(set) var authError: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let hasToken = !(defaults.string(forKey: accessTokenKey) ?? "").isEmpty
            || !(defaults.string(forKey: refreshTokenKey) ?? "").isEmpty
        self.isLoggedIn = hasToken || defaults.bool(forKey: loggedInKey)
    }

    func signIn(onCompletion: (() -> Void)? = nil) {
        if isAuthenticating {
            cancelSignIn()
        }

        authError = nil
        isAuthenticating = true

        let server = ClaudeOAuthLoopbackServer()
        self.activeServer = server

        let port: Int
        do {
            port = try server.start()
        } catch {
            self.authError = error.localizedDescription
            self.isAuthenticating = false
            return
        }

        let (verifier, challenge) = generatePKCE()
        let state = UUID().uuidString
        let redirectURI = "http://localhost:\(port)/callback"

        guard let authURL = makeAuthURL(redirectURI: redirectURI, challenge: challenge, state: state) else {
            server.stop()
            self.authError = "인증 URL을 생성할 수 없습니다."
            self.isAuthenticating = false
            return
        }

        var isHandled = false
        let completeAuth: (String, String?) async -> Void = { [weak self] code, returnedState in
            guard let self = self, !isHandled else { return }
            isHandled = true
            defer {
                server.stop()
                ClaudeLoginWindowController.shared.close()
            }

            guard returnedState == state else {
                self.authError = ClaudeOAuthError.stateMismatch.localizedDescription
                self.isAuthenticating = false
                return
            }

            do {
                try await self.exchangeCodeForTokens(code: code, verifier: verifier, redirectURI: redirectURI, state: state)
                self.isAuthenticating = false
                self.authError = nil
                onCompletion?()
            } catch {
                self.authError = error.localizedDescription
                self.isAuthenticating = false
            }
        }

        // 1. Small dedicated window (auto-closes upon login completion). Its navigation
        //    delegate intercepts the localhost/callback redirect.
        ClaudeLoginWindowController.shared.show(url: authURL) { callbackURL in
            let comps = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
            let queryItems = comps?.queryItems ?? []
            let code = queryItems.first(where: { $0.name == "code" })?.value ?? ""
            let returnedState = queryItems.first(where: { $0.name == "state" })?.value
            Task { @MainActor in await completeAuth(code, returnedState) }
        }

        // 2. Backup: also listen on the loopback server, in case the redirect lands as raw HTTP.
        Task {
            do {
                let (code, returnedState) = try await server.waitForCode()
                await completeAuth(code, returnedState)
            } catch {
                if !isHandled && !Task.isCancelled {
                    self.authError = error.localizedDescription
                    self.isAuthenticating = false
                }
            }
        }
    }

    func cancelSignIn() {
        activeServer?.stop()
        activeServer = nil
        ClaudeLoginWindowController.shared.close()
        isAuthenticating = false
    }

    func logout() {
        cancelSignIn()
        defaults.removeObject(forKey: accessTokenKey)
        defaults.removeObject(forKey: refreshTokenKey)
        defaults.removeObject(forKey: tokenExpiryKey)
        defaults.set(false, forKey: loggedInKey)
        self.isLoggedIn = false
        self.authError = nil
    }

    func validAccessToken(session: URLSession = .shared) async throws -> String {
        let expiry = defaults.double(forKey: tokenExpiryKey)
        let token = defaults.string(forKey: accessTokenKey)

        if let token, !token.isEmpty {
            if expiry == 0 || Date().timeIntervalSince1970 + 60 < expiry {
                return token
            }
        }

        if let refreshToken = defaults.string(forKey: refreshTokenKey), !refreshToken.isEmpty {
            return try await refreshAccessToken(session: session)
        }

        if let token, !token.isEmpty {
            return token
        }

        throw ProviderError.missingCredential
    }

    func forceRefreshToken(session: URLSession = .shared) async throws -> String {
        guard let refreshToken = defaults.string(forKey: refreshTokenKey), !refreshToken.isEmpty else {
            throw ProviderError.missingCredential
        }
        return try await refreshAccessToken(session: session)
    }

    private func refreshAccessToken(session: URLSession = .shared) async throws -> String {
        guard let refreshToken = defaults.string(forKey: refreshTokenKey), !refreshToken.isEmpty else {
            throw ProviderError.missingCredential
        }

        guard let tokenEndpoint = URL(string: Self.tokenURL) else {
            throw ProviderError.invalidResponse
        }

        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID,
        ])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse
        }

        guard (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newAccessToken = json["access_token"] as? String, !newAccessToken.isEmpty else {
            throw ProviderError.authentication
        }

        defaults.set(newAccessToken, forKey: accessTokenKey)
        if let expiresIn = json["expires_in"] as? Double ?? (json["expires_in"] as? Int).map(Double.init) {
            defaults.set(Date().timeIntervalSince1970 + expiresIn, forKey: tokenExpiryKey)
        }
        if let newRefreshToken = json["refresh_token"] as? String, !newRefreshToken.isEmpty {
            defaults.set(newRefreshToken, forKey: refreshTokenKey)
        }

        self.isLoggedIn = true
        return newAccessToken
    }

    private func exchangeCodeForTokens(code: String, verifier: String, redirectURI: String, state: String) async throws {
        guard let tokenEndpoint = URL(string: Self.tokenURL) else {
            throw ClaudeOAuthError.tokenExchangeFailed("잘못된 엔드포인트 URL")
        }

        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // `state` is required in the body — omitting it makes the token endpoint reject the
        // request as "Invalid request format" (matches Claude Code CLI's own exchange body).
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": Self.clientID,
            "code_verifier": verifier,
            "state": state,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClaudeOAuthError.tokenExchangeFailed("응답 없음")
        }

        guard (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String, !accessToken.isEmpty else {
            let parsed = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
            let errorMsg = (parsed?["error_description"] as? String)
                ?? (parsed?["error"] as? String)
                ?? "HTTP \(http.statusCode)"
            throw ClaudeOAuthError.tokenExchangeFailed(errorMsg)
        }

        defaults.set(accessToken, forKey: accessTokenKey)
        if let refreshToken = json["refresh_token"] as? String, !refreshToken.isEmpty {
            defaults.set(refreshToken, forKey: refreshTokenKey)
        }
        if let expiresIn = json["expires_in"] as? Double ?? (json["expires_in"] as? Int).map(Double.init) {
            defaults.set(Date().timeIntervalSince1970 + expiresIn, forKey: tokenExpiryKey)
        }
        defaults.set(true, forKey: loggedInKey)
        self.isLoggedIn = true
    }

    private func makeAuthURL(redirectURI: String, challenge: String, state: String) -> URL? {
        var comps = URLComponents(string: Self.authorizeURL)
        comps?.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return comps?.url
    }

    private func generatePKCE() -> (verifier: String, challenge: String) {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))

        let hash = SHA256.hash(data: Data(verifier.utf8))
        let challenge = Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))

        return (verifier, challenge)
    }
}

// MARK: - Dedicated Small OAuth Window Controller (auto-closes on callback)
@MainActor
final class ClaudeLoginWindowController: NSObject, NSWindowDelegate {
    static let shared = ClaudeLoginWindowController()

    private var window: NSWindow?
    private var webView: WKWebView?
    private var coordinator: ClaudeOAuthWebViewCoordinator?
    private var onCallbackReceived: ((URL) -> Void)?

    func show(url: URL, onCallback: @escaping (URL) -> Void) {
        self.onCallbackReceived = onCallback

        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            webView?.load(URLRequest(url: url))
            return
        }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Claude 로그인"
        win.delegate = self
        win.center()
        win.isReleasedWhenClosed = false

        let coord = ClaudeOAuthWebViewCoordinator { [weak self] callbackURL in
            self?.close()
            self?.onCallbackReceived?(callbackURL)
        }
        self.coordinator = coord
        webView.navigationDelegate = coord
        // "Continue with Google" opens Google Identity Services in a real popup window
        // (window.open, ux_mode=popup) — without a uiDelegate that request is silently
        // dropped and the sign-in never appears.
        webView.uiDelegate = coord

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
        if ClaudeOAuthManager.shared.isAuthenticating {
            ClaudeOAuthManager.shared.cancelSignIn()
        }
    }
}

private final class ClaudeOAuthWebViewCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    private let onCallback: (URL) -> Void
    private var hasIntercepted = false
    private var popupWindow: NSWindow?
    private var popupWebView: WKWebView?

    init(onCallback: @escaping (URL) -> Void) {
        self.onCallback = onCallback
    }

    // MARK: WKUIDelegate — host window.open()-created popups (Google's "Continue with
    // Google" sign-in uses ux_mode=popup), otherwise the request is silently dropped.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.customUserAgent = webView.customUserAgent
        popup.navigationDelegate = self
        popup.uiDelegate = self

        let width = (windowFeatures.width?.doubleValue).map { max($0, 380) } ?? 460
        let height = (windowFeatures.height?.doubleValue).map { max($0, 560) } ?? 620
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Google 로그인"
        win.center()
        win.isReleasedWhenClosed = false
        win.contentView = popup

        popupWindow = win
        popupWebView = popup

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return popup
    }

    // Google Identity Services calls window.close() on its popup once sign-in completes.
    func webViewDidClose(_ webView: WKWebView) {
        popupWindow?.close()
        popupWindow = nil
        popupWebView = nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard !hasIntercepted, let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        // Claude Code's own CLI uses the bare "/callback" path (not "/oauth/callback").
        if (url.host == "localhost" || url.host == "127.0.0.1"), url.path == "/callback" {
            hasIntercepted = true
            decisionHandler(.cancel)
            DispatchQueue.main.async {
                self.onCallback(url)
            }
            return
        }

        decisionHandler(.allow)
    }
}

// MARK: - Loopback OAuth Server (Claude-specific: separate instance from Gemini's)
final class ClaudeOAuthLoopbackServer: @unchecked Sendable {
    private var serverFd: Int32 = -1
    private var isCancelled = false
    private(set) var port: Int = 0

    func start() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ClaudeOAuthError.serverStartFailed("소켓 생성 실패: \(errno)")
        }
        self.serverFd = fd

        var opt: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))

        var tv = timeval(tv_sec: 180, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindRes = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRes == 0 else {
            close(fd)
            self.serverFd = -1
            throw ClaudeOAuthError.serverStartFailed("포트 바인딩 실패: \(errno)")
        }

        guard listen(fd, 5) == 0 else {
            close(fd)
            self.serverFd = -1
            throw ClaudeOAuthError.serverStartFailed("수신 대기 실패: \(errno)")
        }

        var actualAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let sockNameRes = withUnsafeMutablePointer(to: &actualAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard sockNameRes == 0 else {
            close(fd)
            self.serverFd = -1
            throw ClaudeOAuthError.serverStartFailed("포트 확인 실패: \(errno)")
        }

        let assignedPort = Int(actualAddr.sin_port.bigEndian)
        self.port = assignedPort
        return assignedPort
    }

    func waitForCode() async throws -> (code: String, state: String?) {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self, self.serverFd >= 0 else {
                    continuation.resume(throwing: ClaudeOAuthError.cancelled)
                    return
                }

                while !self.isCancelled && self.serverFd >= 0 {
                    var clientAddr = sockaddr_in()
                    var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                    let clientFd = withUnsafeMutablePointer(to: &clientAddr) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            accept(self.serverFd, $0, &clientLen)
                        }
                    }

                    guard clientFd >= 0 else {
                        if self.isCancelled {
                            continuation.resume(throwing: ClaudeOAuthError.cancelled)
                        } else {
                            continuation.resume(throwing: ClaudeOAuthError.serverTimeout)
                        }
                        return
                    }

                    var buffer = [UInt8](repeating: 0, count: 4096)
                    let bytesRead = read(clientFd, &buffer, buffer.count - 1)
                    guard bytesRead > 0 else {
                        close(clientFd)
                        continue
                    }

                    let requestStr = String(decoding: buffer[0..<bytesRead], as: UTF8.self)
                    guard let firstLine = requestStr.components(separatedBy: "\r\n").first,
                          let target = firstLine.components(separatedBy: " ").dropFirst().first else {
                        close(clientFd)
                        continue
                    }

                    if target.starts(with: "/favicon.ico") {
                        let resp = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                        _ = resp.withCString { write(clientFd, $0, strlen($0)) }
                        close(clientFd)
                        continue
                    }

                    guard target.starts(with: "/callback") else {
                        let resp = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                        _ = resp.withCString { write(clientFd, $0, strlen($0)) }
                        close(clientFd)
                        continue
                    }

                    let urlComponents = URLComponents(string: "http://localhost" + target)
                    let queryItems = urlComponents?.queryItems ?? []
                    let code = queryItems.first(where: { $0.name == "code" })?.value
                    let state = queryItems.first(where: { $0.name == "state" })?.value
                    let error = queryItems.first(where: { $0.name == "error" })?.value

                    let html: String
                    if let code, !code.isEmpty {
                        html = """
                        <!DOCTYPE html>
                        <html><head><meta charset="utf-8"><title>TokenCounter - 로그인 완료</title>
                        <style>body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0;background:#f5f5f7;color:#1d1d1f}.card{background:#fff;padding:40px 32px;border-radius:18px;box-shadow:0 4px 24px rgba(0,0,0,.08);text-align:center;max-width:380px}h1{font-size:24px;margin-bottom:12px;color:#34c759}p{font-size:15px;color:#6e6e73;line-height:1.5;margin:0}</style>
                        <script>window.onload=function(){window.open('','_self','');window.close()};setTimeout(function(){window.close()},800)</script></head>
                        <body><div class="card"><h1>✓ 로그인 성공</h1><p>TokenCounter에 Claude 로그인이 완료되었습니다.<br>이 창은 자동으로 닫힙니다.</p></div></body></html>
                        """
                    } else {
                        html = """
                        <!DOCTYPE html>
                        <html><head><meta charset="utf-8"><title>TokenCounter - 로그인 실패</title>
                        <style>body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0;background:#f5f5f7;color:#1d1d1f}.card{background:#fff;padding:40px 32px;border-radius:18px;box-shadow:0 4px 24px rgba(0,0,0,.08);text-align:center;max-width:380px}h1{font-size:24px;margin-bottom:12px;color:#ff3b30}p{font-size:15px;color:#6e6e73;line-height:1.5;margin:0}</style></head>
                        <body><div class="card"><h1>로그인 실패</h1><p>\(error ?? "인증 코드를 수신하지 못했습니다.")<br>TokenCounter에서 다시 시도해 주세요.</p></div></body></html>
                        """
                    }

                    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
                    _ = response.withCString { write(clientFd, $0, strlen($0)) }
                    close(clientFd)

                    if let code, !code.isEmpty {
                        continuation.resume(returning: (code, state))
                        return
                    } else {
                        continuation.resume(throwing: ClaudeOAuthError.authenticationFailed(error ?? "인증 코드가 없습니다."))
                        return
                    }
                }
            }
        }
    }

    func stop() {
        isCancelled = true
        if serverFd >= 0 {
            close(serverFd)
            serverFd = -1
        }
    }
}
