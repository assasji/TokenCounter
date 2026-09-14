import Foundation
import Combine

@MainActor
final class MonitorStore: ObservableObject {
    @Published private(set) var snapshots: [ProviderID: ProviderSnapshot] = [:] {
        didSet { onUpdate?(self) }
    }
    @Published var intervalMinutes: Int { didSet { defaults.set(intervalMinutes, forKey: "pollInterval"); schedule() } }
    @Published private(set) var enabledProviders: Set<ProviderID> = [] {
        didSet { onUpdate?(self) }
    }
    private let services: [ProviderService]
    private let defaults: UserDefaults
    private var timer: Timer?
    private var snapshotRevisions: [ProviderID: Int] = [:]
    var onUpdate: ((MonitorStore) -> Void)?

    init(services: [ProviderService], defaults: UserDefaults = .standard) {
        self.services = services; self.defaults = defaults
        let saved = defaults.integer(forKey: "pollInterval")
        intervalMinutes = [2, 5, 15, 30, 60].contains(saved) ? saved : 2

        if let savedProviders = defaults.stringArray(forKey: "enabledProviders") {
            let parsed = savedProviders.compactMap { ProviderID(rawValue: $0) }
            enabledProviders = parsed.isEmpty ? Set(ProviderID.allCases) : Set(parsed)
        } else {
            enabledProviders = Set(ProviderID.allCases)
        }

        for provider in ProviderID.allCases { snapshots[provider] = Self.load(provider, defaults: defaults) }
    }

    func isProviderEnabled(_ provider: ProviderID) -> Bool {
        enabledProviders.contains(provider)
    }

    func setProviderEnabled(_ provider: ProviderID, isEnabled: Bool) {
        if isEnabled {
            enabledProviders.insert(provider)
        } else {
            if enabledProviders.count > 1 {
                enabledProviders.remove(provider)
            }
        }
        defaults.set(enabledProviders.map(\.rawValue), forKey: "enabledProviders")
        Task { await refresh() }
    }

    func start() { Task { await refresh() } }
    func stop() { timer?.invalidate(); timer = nil }

    /// Account changes must invalidate both the cache and already-running requests.
    func invalidateSnapshot(for provider: ProviderID) {
        snapshotRevisions[provider, default: 0] += 1
        snapshots[provider] = .empty
        defaults.removeObject(forKey: "snapshot.\(provider.rawValue)")
    }

    func refresh() async {
        await withTaskGroup(of: (ProviderID, Int, Result<[UsageWindow], Error>).self) { group in
            for service in services where enabledProviders.contains(service.provider) {
                let revision = snapshotRevisions[service.provider, default: 0]
                group.addTask {
                    do { return (service.provider, revision, .success(try await service.fetchUsageWindows())) }
                    catch { return (service.provider, revision, .failure(error)) }
                }
            }
            for await (provider, revision, result) in group {
                guard enabledProviders.contains(provider), snapshotRevisions[provider, default: 0] == revision else { continue }
                switch result {
                case .success(let windows):
                    let value = ProviderSnapshot(windows: windows, updatedAt: Date(), error: nil)
                    snapshots[provider] = value; save(value, provider: provider)
                case .failure(let error):
                    var cached = snapshots[provider] ?? .empty
                    // Keep the last verified value visible, but mark it as stale.
                    cached.error = error.localizedDescription
                    snapshots[provider] = cached
                    save(cached, provider: provider)
                }
            }
        }
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        let delay = TimeInterval(intervalMinutes * 60)
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }
    private func save(_ snapshot: ProviderSnapshot, provider: ProviderID) {
        if let data = try? JSONEncoder().encode(snapshot) { defaults.set(data, forKey: "snapshot.\(provider.rawValue)") }
    }
    private static func load(_ provider: ProviderID, defaults: UserDefaults) -> ProviderSnapshot {
        guard let data = defaults.data(forKey: "snapshot.\(provider.rawValue)"),
              let value = try? JSONDecoder().decode(ProviderSnapshot.self, from: data) else { return .empty }
        return value
    }
}
