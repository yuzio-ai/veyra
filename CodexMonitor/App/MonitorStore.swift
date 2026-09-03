import Foundation
import Observation

@MainActor @Observable
final class MonitorStore {
    static let shared = MonitorStore()
    var quota = QuotaDisplayState()
    var tasks: [TaskSnapshot] = []
    var tasksUpdatedAt: Date?
    var taskError: String?
    var taskWarning: String?
    var quotaBusy = false
    var tasksBusy = false
    var homePath: String
    var executablePath: String
    var isPreview = false

    @ObservationIgnored private var quotaClient = AppServerClient()
    @ObservationIgnored private var taskReader = LocalTaskReader()
    @ObservationIgnored private var quotaLoop: Task<Void, Never>?
    @ObservationIgnored private var taskLoop: Task<Void, Never>?
    @ObservationIgnored private var revision = 0

    init() {
        homePath = UserDefaults.standard.string(forKey: "codexHome") ?? ""
        executablePath = UserDefaults.standard.string(forKey: "codexExecutable") ?? ""
    }
    var location: CodexLocation { .resolve(homePath: homePath, executablePath: executablePath) }
    var runningTasks: [TaskSnapshot] { tasks.filter { $0.activity == .running } }
    var unknownTasks: [TaskSnapshot] { tasks.filter { $0.activity == .unknown } }
    var menuLabel: String {
        let quotaLabel: String
        if let window = quota.snapshot?.menuWindow {
            quotaLabel = "\(window.durationLabel) \(DisplayFormat.percent(window.remainingPercent))\(quota.error == nil ? "" : "*")"
        } else { quotaLabel = "额度 —" }
        let count = tasksUpdatedAt == nil || taskError != nil || taskWarning?.hasPrefix("无法核对") == true ? "—" : String(runningTasks.count)
        return "\(quotaLabel) · 运行 \(count)"
    }

    func start() {
        guard quotaLoop == nil, !isPreview else { return }
        quotaLoop = Task { [weak self] in
            let clock = ContinuousClock()
            while !Task.isCancelled {
                let next = clock.now.advanced(by: .seconds(60))
                await self?.refreshQuota()
                do { try await clock.sleep(until: next, tolerance: .seconds(1)) } catch { return }
            }
        }
        taskLoop = Task { [weak self] in
            let clock = ContinuousClock()
            while !Task.isCancelled {
                let next = clock.now.advanced(by: .seconds(5))
                await self?.refreshTasks()
                do { try await clock.sleep(until: next, tolerance: .milliseconds(200)) } catch { return }
            }
        }
    }
    func stop() {
        quotaLoop?.cancel(); taskLoop?.cancel()
        quotaLoop = nil; taskLoop = nil
        let client = quotaClient
        Task { await client.shutdown() }
    }
    func refreshAll() async {
        guard !isPreview else { return }
        async let quotaUpdate: Void = refreshQuota()
        async let taskUpdate: Void = refreshTasks()
        _ = await (quotaUpdate, taskUpdate)
    }
    private func refreshQuota() async {
        guard !quotaBusy else { return }
        quotaBusy = true
        let version = revision
        let result = await quotaClient.fetch(location: location)
        guard version == revision else { return }
        quota.apply(result)
        quotaBusy = false
    }
    private func refreshTasks() async {
        guard !tasksBusy else { return }
        tasksBusy = true
        let version = revision
        do {
            let result = try await taskReader.fetch(home: location.home)
            guard version == revision else { return }
            tasks = result.tasks; tasksUpdatedAt = result.fetchedAt
            taskWarning = result.warning; taskError = nil
        } catch {
            guard version == revision else { return }
            taskError = error.localizedDescription
            // Old snapshots must not continue to claim that a stopped process is running.
            tasks = tasks.map { TaskSnapshot(id: $0.id, title: $0.title, model: $0.model, sourceLabel: $0.sourceLabel,
                                            parentID: $0.parentID, startedAt: $0.startedAt, updatedAt: $0.updatedAt,
                                            tokens: $0.tokens, activity: .unknown) }
        }
        tasksBusy = false
    }
    func saveSettings(home: String, executable: String) {
        stop()
        revision += 1
        homePath = home.trimmingCharacters(in: .whitespacesAndNewlines)
        executablePath = executable.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(homePath, forKey: "codexHome")
        UserDefaults.standard.set(executablePath, forKey: "codexExecutable")
        quotaClient = AppServerClient(); taskReader = LocalTaskReader()
        quota = QuotaDisplayState(); tasks = []; tasksUpdatedAt = nil
        taskError = nil; taskWarning = nil; quotaBusy = false; tasksBusy = false
        start()
    }
}
