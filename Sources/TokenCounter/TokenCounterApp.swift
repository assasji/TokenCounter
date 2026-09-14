import SwiftUI
import AppKit
import Combine

@main
struct TokenCounterApp: App {
    @StateObject private var store: MonitorStore
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        let services: [ProviderService] = [
            ClaudeService(), OpenAIService(), GeminiService()
        ]
        let monitor = MonitorStore(services: services)
        _store = StateObject(wrappedValue: monitor)
        AppDelegate.pendingStore = monitor
    }

    var body: some Scene {
        Settings { PreferencesView(store: store) }
            .commands { CommandGroup(replacing: .appTermination) { Button("TokenCounter 종료") { NSApp.terminate(nil) }.keyboardShortcut("q") } }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var pendingStore: MonitorStore?
    private var items: [ProviderID: NSStatusItem] = [:]
    private weak var store: MonitorStore?
    private var openAILoginObserver: AnyCancellable?
    private var openAIUIObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            guard let store = Self.pendingStore else { return }
            install(store: store)
            store.onUpdate = { [weak self] value in self?.update(store: value) }
            openAILoginObserver = OpenAIOAuthManager.shared.$isLoggedIn
                .removeDuplicates()
                .receive(on: RunLoop.main)
                .sink { [weak self] loggedIn in
                    guard let self, let store = self.store else { return }
                    if !loggedIn { store.invalidateSnapshot(for: .openAI) }
                    self.update(store: store)
                }
            openAIUIObserver = OpenAIOAuthManager.shared.objectWillChange
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    guard let self, let store = self.store else { return }
                    self.update(store: store)
                }
            store.start()
        }
    }

    @MainActor func install(store: MonitorStore) {
        guard items.isEmpty else { return }
        self.store = store
        NSApp.setActivationPolicy(.accessory)
        for provider in ProviderID.allCases {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.image = providerIcon(provider)
            item.button?.imagePosition = .imageLeading
            item.button?.imageScaling = .scaleProportionallyDown
            item.button?.toolTip = provider.name
            item.isVisible = store.isProviderEnabled(provider)
            items[provider] = item
        }
        update(store: store)
    }

    @MainActor func update(store: MonitorStore) {
        for provider in ProviderID.allCases {
            let isEnabled = store.isProviderEnabled(provider)
            items[provider]?.isVisible = isEnabled
            guard isEnabled else { continue }

            let menu = NSMenu()
            let isOpenAINotLoggedIn = provider == .openAI && !OpenAIOAuthManager.shared.isLoggedIn
            let snapshot = isOpenAINotLoggedIn ? .empty : (store.snapshots[provider] ?? .empty)
            menu.addItem(.init(title: provider.name, action: nil, keyEquivalent: ""))
            // Click view: every usage window (5h session + weekly) at once.
            if snapshot.windows.isEmpty {
                menu.addItem(.init(title: "잔여: N/A", action: nil, keyEquivalent: ""))
            } else {
                for w in snapshot.windows {
                    let reset = w.resetsAt.map { " · 리셋 " + Self.absoluteFmt.string(from: $0) } ?? ""
                    let mi = NSMenuItem(title: "\(w.label): \(Int(w.remainingPercent.rounded()))% 남음\(reset)", action: nil, keyEquivalent: "")
                    mi.attributedTitle = NSAttributedString(string: mi.title, attributes: [.foregroundColor: color(w.remainingPercent)])
                    menu.addItem(mi)
                }
            }
            if isOpenAINotLoggedIn {
                let noticeItem = NSMenuItem(title: "⚠ ChatGPT 로그인이 필요합니다", action: #selector(openOpenAILogin), keyEquivalent: "")
                noticeItem.target = self
                menu.addItem(noticeItem)
            } else if provider == .gemini && !GeminiOAuthManager.shared.isLoggedIn {
                let noticeItem = NSMenuItem(title: "⚠ 로그인이 필요합니다", action: #selector(openGeminiLogin), keyEquivalent: "")
                noticeItem.target = self
                noticeItem.attributedTitle = NSAttributedString(
                    string: "⚠ 로그인이 필요합니다",
                    attributes: [.foregroundColor: NSColor.systemRed]
                )
                menu.addItem(noticeItem)
            } else if provider == .claude && snapshot.windows.isEmpty && !ClaudeOAuthManager.shared.isLoggedIn {
                let noticeItem = NSMenuItem(title: "⚠ 로그인이 필요합니다", action: #selector(openClaudeLogin), keyEquivalent: "")
                noticeItem.target = self
                noticeItem.attributedTitle = NSAttributedString(
                    string: "⚠ 로그인이 필요합니다",
                    attributes: [.foregroundColor: NSColor.systemRed]
                )
                menu.addItem(noticeItem)
            } else if let error = snapshot.error {
                menu.addItem(.init(title: "⚠︎ \(error)", action: nil, keyEquivalent: ""))
            }
            menu.addItem(.separator())
            let refresh = NSMenuItem(title: "지금 갱신", action: #selector(refreshNow), keyEquivalent: "r")
            refresh.target = self; menu.addItem(refresh)
            if provider == .openAI {
                let title = OpenAIOAuthManager.shared.isLoggedIn ? "ChatGPT 계정 다시 로그인…" : "ChatGPT 로그인…"
                let loginItem = NSMenuItem(title: title, action: #selector(openOpenAILogin), keyEquivalent: "")
                loginItem.target = self
                menu.addItem(loginItem)
                if let error = OpenAIOAuthManager.shared.authError {
                    menu.addItem(.init(title: "⚠ \(error)", action: nil, keyEquivalent: ""))
                }
            }
            if provider == .gemini {
                let loginTitle = GeminiOAuthManager.shared.isLoggedIn ? "Gemini 계정 다시 로그인…" : "Gemini 로그인…"
                let loginItem = NSMenuItem(title: loginTitle, action: #selector(openGeminiLogin), keyEquivalent: "")
                loginItem.target = self
                menu.addItem(loginItem)
            }
            if provider == .claude {
                let loginTitle = ClaudeOAuthManager.shared.isLoggedIn ? "Claude 계정 다시 로그인…" : "Claude 로그인…"
                let loginItem = NSMenuItem(title: loginTitle, action: #selector(openClaudeLogin), keyEquivalent: "")
                loginItem.target = self
                menu.addItem(loginItem)
            }
            let settings = NSMenuItem(title: "설정…", action: #selector(openSettings), keyEquivalent: ",")
            settings.target = self; menu.addItem(settings)
            menu.addItem(.separator())
            let quit = NSMenuItem(title: "TokenCounter 종료", action: #selector(quitApp), keyEquivalent: "q")
            quit.target = self; menu.addItem(quit)
            items[provider]?.menu = menu
            // Menu bar: icon + 5h-session remaining % (compact).
            let p = snapshot.primaryPercent
            let isGeminiNotLoggedIn = (provider == .gemini && !GeminiOAuthManager.shared.isLoggedIn)
            let isClaudeNotLoggedIn = (provider == .claude && snapshot.windows.isEmpty && !ClaudeOAuthManager.shared.isLoggedIn)
            let isNotLoggedIn = isOpenAINotLoggedIn || isGeminiNotLoggedIn || isClaudeNotLoggedIn || (p == nil && snapshot.error != nil)

            let attrTitle = NSMutableAttributedString()
            let baseTitle = " " + (p.map { "\(Int($0.rounded()))%" } ?? "N/A")
            attrTitle.append(NSAttributedString(
                string: baseTitle,
                attributes: [.foregroundColor: color(p), .font: NSFont.menuBarFont(ofSize: 0)]
            ))
            if isNotLoggedIn || snapshot.error != nil {
                attrTitle.append(NSAttributedString(
                    string: " ⚠",
                    attributes: [.foregroundColor: NSColor.systemRed, .font: NSFont.menuBarFont(ofSize: 0)]
                ))
            }
            items[provider]?.button?.attributedTitle = attrTitle
            items[provider]?.button?.toolTip = (isOpenAINotLoggedIn || isGeminiNotLoggedIn || isClaudeNotLoggedIn) ? "\(provider.name) · 로그인이 필요합니다" : (snapshot.error ?? "\(provider.name) · 5시간 세션 잔여")
        }
    }
    // e.g. "18:32 (EST)" — current system time zone, abbreviation spelled out so it's
    // never ambiguous which zone the reset time is in.
    private static let absoluteFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm (z)"; return f }()

    @objc @MainActor private func quitApp() { NSApp.terminate(nil) }
    @objc @MainActor private func refreshNow() { Task { @MainActor in await store?.refresh() } }
    @objc @MainActor private func openOpenAILogin() {
        OpenAIOAuthManager.shared.signIn { [weak self] in
            self?.store?.invalidateSnapshot(for: .openAI)
            Task { @MainActor in await self?.store?.refresh() }
        }
    }
    @objc @MainActor private func openGeminiLogin() {
        GeminiOAuthManager.shared.signIn { [weak self] in
            Task { @MainActor in await self?.store?.refresh() }
        }
    }
    @objc @MainActor private func openClaudeLogin() {
        ClaudeOAuthManager.shared.signIn { [weak self] in
            Task { @MainActor in await self?.store?.refresh() }
        }
    }
    @objc @MainActor private func openSettings() {
        guard let store = self.store else { return }
        PreferencesWindowController.shared.show(store: store)
    }
    private func color(_ value: Double?) -> NSColor {
        guard let value else { return .systemRed }
        if value < 20 { return .systemRed }
        if value <= 50 { return .systemYellow }
        return .labelColor
    }

    private func providerIcon(_ provider: ProviderID) -> NSImage? {
        let url = Bundle.main.url(forResource: provider.iconResource, withExtension: "svg")
            ?? Bundle.module.url(forResource: provider.iconResource, withExtension: "svg")
        guard let url,
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 17, height: 17)
        // The official ChatGPT menu-bar glyph is monochrome and follows the menu-bar appearance.
        image.isTemplate = provider == .openAI
        image.accessibilityDescription = provider.name
        return image
    }
}
