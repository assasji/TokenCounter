import SwiftUI

struct PreferencesView: View {
    // Externally-owned singletons → @ObservedObject (not @StateObject). @StateObject with a
    // shared instance drove KVO invalidations into a hosting view mid-presentation, which
    // aborted in _postWindowNeedsUpdateConstraints. A fixed-size ScrollView/GroupBox layout
    // (instead of Form) also avoids the NSScrollView constraint recompute that crashed.
    @ObservedObject var store: MonitorStore
    @ObservedObject private var geminiOAuth = GeminiOAuthManager.shared
    @ObservedObject private var claudeOAuth = ClaudeOAuthManager.shared
    @ObservedObject private var openAIOAuth = OpenAIOAuthManager.shared

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    agentsBox
                    claudeBox
                    openAIBox
                    geminiBox
                    generalBox
                }
                .padding(16)
            }

            Divider()

            HStack {
                Text("TokenBar는 로컬 세션만 사용하며 별도 서버·분석이 없습니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("닫기") { PreferencesWindowController.shared.close() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 460, height: 600)
    }

    private var agentsBox: some View {
        GroupBox("사용할 AI 에이전트") {
            VStack(spacing: 8) {
                ForEach(ProviderID.allCases) { provider in
                    Toggle(isOn: Binding(
                        get: { store.isProviderEnabled(provider) },
                        set: { store.setProviderEnabled(provider, isEnabled: $0) }
                    )) {
                        HStack {
                            Text(provider.name)
                            Spacer()
                            if provider == .gemini {
                                loginBadge(geminiOAuth.isLoggedIn)
                            } else if provider == .claude {
                                loginBadge(claudeOAuth.isLoggedIn)
                            } else if provider == .openAI {
                                loginBadge(openAIOAuth.isLoggedIn)
                            }
                        }
                    }
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity)
        }
    }

    private var claudeBox: some View {
        GroupBox("Claude (claude.ai 계정)") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Claude 5시간/주간 한도")
                        Text(claudeOAuth.isLoggedIn
                             ? "claude.ai 계정 로그인됨 · 터미널 불필요"
                             : "로그인 안 됨 (브라우저로 간편 로그인)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if claudeOAuth.isLoggedIn {
                        Button("로그아웃") {
                            claudeOAuth.logout()
                            Task { await store.refresh() }
                        }
                    } else {
                        Button(claudeOAuth.isAuthenticating ? "로그인 중…" : "claude.ai 로그인…") {
                            claudeOAuth.signIn { Task { await store.refresh() } }
                        }
                        .disabled(claudeOAuth.isAuthenticating)
                    }
                }
                if let err = claudeOAuth.authError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity)
        }
    }

    private var openAIBox: some View {
        GroupBox("Codex (ChatGPT 계정)") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Codex 5시간/주간 한도")
                Text(openAIOAuth.isLoggedIn
                     ? "ChatGPT 계정 로그인됨 · CLI 설치 불필요"
                     : "Chrome의 기존 로그인 상태로 계정을 연결합니다. CLI 설치 불필요.")
                    .font(.caption).foregroundStyle(.secondary)
                if openAIOAuth.isAuthenticating {
                    Text("Chrome(없으면 기본 브라우저)에서 계정 연결을 완료해 주세요.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(openAIOAuth.isAuthenticating ? "로그인 중…" : (openAIOAuth.isLoggedIn ? "다시 로그인…" : "ChatGPT 로그인…")) {
                        openAIOAuth.signIn {
                            store.invalidateSnapshot(for: .openAI)
                            Task { await store.refresh() }
                        }
                    }
                    .disabled(openAIOAuth.isAuthenticating)
                    if openAIOAuth.isAuthenticating {
                        Button("취소") { openAIOAuth.cancelSignIn() }
                    }
                    if openAIOAuth.isLoggedIn {
                        Button("로그아웃") {
                            openAIOAuth.logout()
                            store.invalidateSnapshot(for: .openAI)
                            Task { await store.refresh() }
                        }
                    }
                }
                Text("로그인 정보는 이 Mac의 앱 환경설정에 저장됩니다(암호화되지 않음).")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = openAIOAuth.authError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var geminiBox: some View {
        GroupBox("Gemini (Google 계정)") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Gemini 5시간/주간 한도")
                        if geminiOAuth.isLoggedIn {
                            let emailDesc = geminiOAuth.userEmail.map { " (\($0))" } ?? ""
                            Text("Google 계정 로그인됨\(emailDesc) · 터미널 불필요")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("로그인 안 됨 (브라우저로 간편 로그인)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if geminiOAuth.isLoggedIn {
                        Button("로그아웃") {
                            geminiOAuth.logout()
                            Task { await store.refresh() }
                        }
                    } else {
                        Button(geminiOAuth.isAuthenticating ? "로그인 중…" : "Google 계정 로그인…") {
                            geminiOAuth.signIn { Task { await store.refresh() } }
                        }
                        .disabled(geminiOAuth.isAuthenticating)
                    }
                }
                if let err = geminiOAuth.authError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity)
        }
    }

    private var generalBox: some View {
        GroupBox("일반 설정") {
            Picker("갱신 주기", selection: $store.intervalMinutes) {
                ForEach([2, 5, 15, 30, 60], id: \.self) { Text("\($0)분").tag($0) }
            }
            .pickerStyle(.menu)
            .padding(6)
            .frame(maxWidth: .infinity)
        }
    }

    private func loginBadge(_ isLoggedIn: Bool) -> some View {
        Text(isLoggedIn ? "로그인됨" : "로그인 필요")
            .font(.caption)
            .foregroundStyle(isLoggedIn ? Color.green : Color.secondary)
    }
}
