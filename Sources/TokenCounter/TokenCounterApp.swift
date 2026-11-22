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
                    let resetText = w.resetsAt.map { "리셋 " + Self.absoluteFmt.string(from: $0) } ?? ""
                    let mi = NSMenuItem()
                    mi.title = "\(w.label): \(Int(w.remainingPercent.rounded()))% 남음"  // accessibility fallback
                    mi.view = UsageRowView(label: w.label, percent: w.remainingPercent, reset: resetText)
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
            // Shortcut to the provider's official page for buying more usage / upgrading.
            // The app never purchases anything itself; it only opens the page in the browser.
            let isLow = snapshot.windows.contains { $0.remainingPercent < 20 }
            let topUpTitle = Self.topUpTitle(provider)
            let topUp = NSMenuItem(title: topUpTitle, action: #selector(openTopUpPage(_:)), keyEquivalent: "")
            topUp.target = self
            topUp.representedObject = provider.rawValue
            topUp.toolTip = "브라우저에서 \(provider.name) 공식 페이지를 엽니다"
            if isLow {
                topUp.attributedTitle = NSAttributedString(
                    string: "⚡ " + topUpTitle,
                    attributes: [.foregroundColor: NSColor.systemRed, .font: NSFont.menuFont(ofSize: 0)]
                )
            }
            menu.addItem(topUp)
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
    // e.g. "9/18 18:32 (EST)" — date + time in the current system time zone, with the
    // zone abbreviation spelled out. Including the date matters for windows that reset
    // days away (e.g. the weekly limit), so the reset moment is never ambiguous.
    private static let absoluteFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "M/d HH:mm (z)"; return f }()

    /// Official pages where the user can add usage themselves.
    /// Claude: Settings > Usage (usage credits / bundles). ChatGPT: Codex Settings > Usage (credits).
    /// Gemini has no pay-as-you-go top-up for these quotas, so link to the Google AI plans page.
    static func topUpURL(_ provider: ProviderID) -> URL? {
        switch provider {
        case .claude: return URL(string: "https://claude.ai/settings/usage")
        case .openAI: return URL(string: "https://chatgpt.com/codex/settings/usage")
        case .gemini: return URL(string: "https://one.google.com/about/google-ai-plans/")
        }
    }

    static func topUpTitle(_ provider: ProviderID) -> String {
        provider == .gemini ? "요금제 업그레이드 보기…" : "사용량 추가하기…"
    }

    @objc @MainActor private func openTopUpPage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let provider = ProviderID(rawValue: raw),
              let url = Self.topUpURL(provider) else { return }
        NSWorkspace.shared.open(url)
    }

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

/// One usage window rendered as a menu row: label (top-left), reset time (below it),
/// remaining % (top-right), and a rounded graphic progress bar spanning the width.
final class UsageRowView: NSView {
    private let label: String
    private let reset: String
    private let percent: Double   // 0...100, remaining

    init(label: String, percent: Double, reset: String) {
        self.label = label
        self.reset = reset
        self.percent = max(0, min(100, percent))
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 52))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var tint: NSColor {
        if percent < 20 { return .systemRed }
        if percent <= 50 { return .systemYellow }
        return .systemGreen
    }

    override func draw(_ dirtyRect: NSRect) {
        let pad: CGFloat = 14
        let w = bounds.width

        // Top row: label (left) + "N% 남음" (right)
        let title = NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ])
        title.draw(at: NSPoint(x: pad, y: bounds.height - 22))

        let pct = NSAttributedString(string: "\(Int(percent.rounded()))% 남음", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: tint,
        ])
        pct.draw(at: NSPoint(x: w - pad - pct.size().width, y: bounds.height - 22))

        // Second line: reset time (left)
        if !reset.isEmpty {
            NSAttributedString(string: reset, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]).draw(at: NSPoint(x: pad, y: bounds.height - 38))
        }

        // Rounded progress bar
        let barH: CGFloat = 6
        let barY: CGFloat = 7
        let barW = w - pad * 2
        let track = NSBezierPath(roundedRect: NSRect(x: pad, y: barY, width: barW, height: barH),
                                 xRadius: barH / 2, yRadius: barH / 2)
        NSColor.quaternaryLabelColor.setFill()
        track.fill()

        let ratio = CGFloat(percent / 100)
        if ratio > 0 {
            let fillW = max(barH, barW * ratio)   // keep the rounded cap visible at tiny values
            let fill = NSBezierPath(roundedRect: NSRect(x: pad, y: barY, width: fillW, height: barH),
                                    xRadius: barH / 2, yRadius: barH / 2)
            tint.setFill()
            fill.fill()
        }
    }
}
