import Foundation
import Observation

@MainActor @Observable
final class MonitorStore {
    static let shared = MonitorStore()
    var quota = QuotaDisplayState() { didSet { updateMenuLabel() } }
    var tasks: [TaskSnapshot] = [] { didSet { updateMenuLabel() } }
    var taskAncestors: [TaskReference] = []
    var hasTaskSnapshot = false
    @ObservationIgnored var tasksUpdatedAt: Date? {
        didSet {
            if hasTaskSnapshot != (tasksUpdatedAt != nil) { hasTaskSnapshot = tasksUpdatedAt != nil }
            updateMenuLabel()
        }
    }
    var taskError: String? { didSet { updateMenuLabel() } }
    var taskWarning: String? { didSet { updateMenuLabel() } }
    var localQuotaWarning: String?
    var quotaBusy = false
    var tasksBusy = false
    var panelVisible = false
    var nextCalibrationAt: Date?
    var quotaFailureDetails: QuotaFailureDetails?
    var homePath: String
    var executablePath: String
    var isPreview = false
    private(set) var menuLabel = "额度 — · 运行 —"

    @ObservationIgnored private var quotaState = QuotaDisplayState()
    @ObservationIgnored private var calibrationPolicy = QuotaCalibrationPolicy()
    @ObservationIgnored private var calibrationTask: Task<Void, Never>?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var authStamp: String?
    @ObservationIgnored private var suspended = false
    @ObservationIgnored private var attemptedLocalRead = false
    @ObservationIgnored private let readLocal: @Sendable (URL) async throws -> TaskReadResult
    @ObservationIgnored private let fetchQuota: @Sendable (CodexLocation) async -> QuotaRefresh
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let clock: PollingClock
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private(set) var lastReadMetrics = TaskReadMetrics()
    @ObservationIgnored private lazy var scheduler = PollingScheduler(clock: clock) { [weak self] in
        await self?.refreshLocal()
    }

    init(readLocal: (@Sendable (URL) async throws -> TaskReadResult)? = nil,
         fetchQuota: (@Sendable (CodexLocation) async -> QuotaRefresh)? = nil,
         clock: PollingClock = .continuous(), now: @escaping @MainActor () -> Date = Date.init,
         defaults: UserDefaults = .standard) {
        let reader = LocalTaskReader()
        self.readLocal = readLocal ?? { try await reader.fetch(home: $0) }
        self.fetchQuota = fetchQuota ?? { location in
            let client = AppServerClient()
            let result = await client.fetch(location: location)
            await client.shutdown()
            return result
        }
        self.clock = clock; self.now = now; self.defaults = defaults
        homePath = defaults.string(forKey: "codexHome") ?? ""
        executablePath = defaults.string(forKey: "codexExecutable") ?? ""
    }
    var location: CodexLocation { .resolve(homePath: homePath, executablePath: executablePath) }
    var runningTasks: [TaskSnapshot] { tasks.filter { $0.activity == .running } }
    var unknownTasks: [TaskSnapshot] { tasks.filter { $0.activity == .unknown } }
    var pollingSeconds: Int { panelVisible || !runningTasks.isEmpty ? 5 : 30 }

    private func updateMenuLabel() {
        let quotaLabel: String
        if let window = quota.snapshot?.menuWindow {
            let marker = quota.snapshot?.source == .local ? "~" : (quota.error == nil ? "" : "*")
            quotaLabel = "\(window.durationLabel) \(DisplayFormat.percent(window.remainingPercent))\(marker)"
        } else { quotaLabel = "额度 —" }
        let count = tasksUpdatedAt == nil || taskError != nil || taskWarning?.hasPrefix("无法核对") == true ? "—" : String(runningTasks.count)
        let label = "\(quotaLabel) · 运行 \(count)"
        if menuLabel != label { menuLabel = label }
    }
    func start() {
        guard !isPreview else { return }
        suspended = false
        scheduler.start()
    }
    func stop() { scheduler.stop() }
    func setPanelVisible(_ visible: Bool) {
        guard panelVisible != visible else { return }
        panelVisible = visible
        guard !isPreview else { return }
        scheduler.update(panelVisible: visible, hasRunningTasks: !runningTasks.isEmpty)
    }
    func sleep() { suspended = true; scheduler.stop() }
    func wake() { guard !isPreview else { return }; suspended = false; scheduler.start() }

    /// Ordinary refresh is strictly local; only calibrateQuota may reach the account API.
    func refreshAll() async {
        guard !isPreview, !suspended else { return }
        tasksBusy = true
        await scheduler.refreshNow()
        tasksBusy = false
    }
    func calibrateQuota() async {
        guard !isPreview, !suspended else { return }
        if let calibrationTask { await calibrationTask.value; return }
        guard calibrationPolicy.allowsRequest(at: now()) else { return }
        let version = revision, location = location, started = now()
        let initialAuth = AppServerClient.authenticationStamp(at: location.home)
        calibrationPolicy.began(at: started)
        nextCalibrationAt = calibrationPolicy.nextAllowedAt
        quotaBusy = true
        let task = Task { [weak self, fetchQuota] in
            let result = await fetchQuota(location)
            guard let self, version == self.revision else { return }
            self.calibrationPolicy.finished(result, startedAt: started, now: self.now())
            self.nextCalibrationAt = self.calibrationPolicy.nextAllowedAt
            self.quotaFailureDetails = result.failureDetails
            let currentAuth = AppServerClient.authenticationStamp(at: location.home)
            if currentAuth != initialAuth {
                self.quotaState.invalidateAccount()
                self.quotaState.error = "登录状态发生变化，请重新联网校准。"
            } else { self.quotaState.apply(result) }
            self.authStamp = currentAuth
            self.publishQuota()
            self.quotaBusy = false
            self.calibrationTask = nil
        }
        calibrationTask = task
        await task.value
    }
    private func refreshLocal() async {
        let version = revision, location = location
        if !attemptedLocalRead { tasksBusy = true; attemptedLocalRead = true }
        checkAuthentication(at: location.home)
        do {
            let result = try await readLocal(location.home)
            guard version == revision else { return }
            if tasks != result.tasks { tasks = result.tasks }
            if taskAncestors != result.ancestors { taskAncestors = result.ancestors }
            tasksUpdatedAt = result.fetchedAt
            if taskWarning != result.warning { taskWarning = result.warning }
            if taskError != nil { taskError = nil }
            if localQuotaWarning != result.quotaWarning { localQuotaWarning = result.quotaWarning }
            quotaState.updateLocal(result.localQuota)
            publishQuota()
            lastReadMetrics = result.metrics
        } catch {
            guard version == revision else { return }
            let message = "无法读取本机任务记录，请检查数据目录。"
            if taskError != message { taskError = message }
            let uncertain = tasks.map { task in
                var copy = task; copy.activity = .unknown
                return copy
            }
            if tasks != uncertain { tasks = uncertain }
        }
        if tasksBusy { tasksBusy = false }
        scheduler.update(panelVisible: panelVisible, hasRunningTasks: !runningTasks.isEmpty)
    }
    private func checkAuthentication(at home: URL) {
        let stamp = AppServerClient.authenticationStamp(at: home)
        if let authStamp, authStamp != stamp {
            quotaState.invalidateAccount()
            quotaState.error = nil
            quotaFailureDetails = nil
            publishQuota()
        }
        authStamp = stamp
    }
    private func publishQuota() {
        if quota.snapshot != quotaState.snapshot || quota.account != quotaState.account || quota.error != quotaState.error {
            quota = quotaState
        }
    }
    func saveSettings(home: String, executable: String) {
        stop()
        revision += 1
        calibrationTask = nil
        homePath = home.trimmingCharacters(in: .whitespacesAndNewlines)
        executablePath = executable.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(homePath, forKey: "codexHome")
        defaults.set(executablePath, forKey: "codexExecutable")
        quotaState = QuotaDisplayState(); quota = quotaState
        calibrationPolicy = QuotaCalibrationPolicy(); nextCalibrationAt = nil; authStamp = nil
        tasks = []; tasksUpdatedAt = nil; taskError = nil; taskWarning = nil
        taskAncestors = []
        localQuotaWarning = nil; quotaFailureDetails = nil; quotaBusy = false; tasksBusy = false
        attemptedLocalRead = false
        // Join any old local read, then immediately read the new location once it has drained.
        let version = revision
        Task { [weak self] in
            guard let self else { return }
            await self.scheduler.drain()
            guard version == self.revision else { return }
            self.start()
        }
    }
}
