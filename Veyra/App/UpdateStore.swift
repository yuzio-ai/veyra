import Foundation
import Observation
import OSLog

@MainActor @Observable
final class UpdateStore {
    enum CheckResult: Equatable {
        case notChecked, upToDate, available
        case failed(UpdateFailure)
    }

    private static let logger = Logger(subsystem: "local.codexmonitor.app", category: "updates")

    var settingsStatus: String {
        if isChecking { return L10n.text("Checking for updates…") }
        switch result {
        case .notChecked, .available: return L10n.text("Current version \(currentVersion)")
        case .upToDate: return L10n.text("Current version \(currentVersion) · You’re up to date")
        case .failed: return L10n.text("Current version \(currentVersion) · Unable to check for updates right now")
        }
    }

    let currentVersion: String
    private(set) var automaticallyChecks: Bool
    private(set) var isChecking = false
    private(set) var result: CheckResult = .notChecked
    private(set) var availableRelease: AppRelease?
    private(set) var nextManualCheckAt: Date?

    @ObservationIgnored private let networkEnabled: Bool
    @ObservationIgnored private let fetch: @Sendable () async throws -> AppRelease
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var lastAttempt: Date?
    @ObservationIgnored private var rateLimitedUntil: Date?

    // Disabled by default: constructing a preview or test view never opts into networking.
    init(currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—",
         defaults: UserDefaults? = nil, networkEnabled: Bool = false,
         now: @escaping () -> Date = Date.init,
         fetch: @escaping @Sendable () async throws -> AppRelease = GitHubReleaseClient.fetch) {
        self.currentVersion = currentVersion
        self.defaults = defaults
        self.networkEnabled = networkEnabled
        self.now = now
        self.fetch = fetch
        automaticallyChecks = defaults?.object(forKey: "updates.automatic") as? Bool ?? true
        lastAttempt = defaults?.object(forKey: "updates.lastAttempt") as? Date
        rateLimitedUntil = defaults?.object(forKey: "updates.rateLimitedUntil") as? Date
        nextManualCheckAt = [lastAttempt?.addingTimeInterval(60), rateLimitedUntil].compactMap { $0 }.max()
        if let data = defaults?.data(forKey: "updates.release"),
           let release = try? JSONDecoder().decode(AppRelease.self, from: data) {
            apply(release)
        }
    }

    func setAutomaticallyChecks(_ enabled: Bool) {
        guard automaticallyChecks != enabled else { return }
        automaticallyChecks = enabled
        defaults?.set(enabled, forKey: "updates.automatic")
        if enabled { Task { await checkAutomatically() } }
    }

    func checkAutomatically() async { await check(manual: false) }
    func checkManually() async { await check(manual: true) }

    private func check(manual: Bool) async {
        guard networkEnabled, !isChecking else { return }
        let date = now()
        guard rateLimitedUntil.map({ date >= $0 }) ?? true else { return }
        if manual {
            guard nextManualCheckAt.map({ date >= $0 }) ?? true else { return }
        } else {
            guard automaticallyChecks,
                  lastAttempt.map({ date.timeIntervalSince($0) >= 86_400 }) ?? true else { return }
        }
        guard AppVersion(currentVersion) != nil else {
            if manual { result = .failed(.invalidData) }
            return
        }
        isChecking = true
        lastAttempt = date
        nextManualCheckAt = date.addingTimeInterval(60)
        defaults?.set(date, forKey: "updates.lastAttempt")
        defer { isChecking = false }
        do {
            let release = try await fetch()
            apply(release)
            defaults?.set(try JSONEncoder().encode(release), forKey: "updates.release")
            rateLimitedUntil = nil
            defaults?.removeObject(forKey: "updates.rateLimitedUntil")
        } catch {
            let failure = error as? UpdateFailure ?? .network
            Self.logger.error("Update check failed: \(failure.diagnosticCategory, privacy: .public)")
            if case .rateLimited(let until) = failure {
                rateLimitedUntil = until
                nextManualCheckAt = max(nextManualCheckAt ?? until, until)
                defaults?.set(until, forKey: "updates.rateLimitedUntil")
            }
            if manual { result = .failed(failure) }
        }
    }

    private func apply(_ release: AppRelease) {
        guard let current = AppVersion(currentVersion), let latest = AppVersion(release.version) else {
            availableRelease = nil
            result = .failed(.invalidData)
            return
        }
        availableRelease = latest > current ? release : nil
        result = availableRelease == nil ? .upToDate : .available
    }

    enum PreviewState: String, CaseIterable { case idle, checking, available, current, failed, limited, availableFailed }

    static func preview(_ state: PreviewState = .idle) -> UpdateStore {
        let store = UpdateStore(currentVersion: "1.1.0")
        switch state {
        case .idle: break
        case .checking: store.isChecking = true
        case .available:
            if let release = try? AppRelease(version: "1.2.0", pageURL: URL(string: "https://github.com/yuzio-ai/veyra/releases/tag/v1.2.0")!) {
                store.apply(release)
            }
        case .current: store.result = .upToDate
        case .failed: store.result = .failed(.network)
        case .availableFailed:
            if let release = try? AppRelease(version: "1.2.0", pageURL: URL(string: "https://github.com/yuzio-ai/veyra/releases/tag/v1.2.0")!) {
                store.apply(release)
            }
            store.result = .failed(.network)
        case .limited:
            let until = Date(timeIntervalSince1970: 1_788_410_400 + 3_600)
            store.result = .failed(.rateLimited(until: until))
            store.nextManualCheckAt = until
        }
        return store
    }
}
