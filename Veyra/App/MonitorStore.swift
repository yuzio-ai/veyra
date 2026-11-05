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
    var taskWarning: TaskReadWarning? { didSet { updateMenuLabel() } }
    var quotaBusy = false
    var tasksBusy = false
    var panelVisible = false
    var nextCalibrationAt: Date?
    var homePath: String
    var executablePath: String
    private(set) var pathResetRevision = 0
    private(set) var configurationState: CodexConfigurationState = .detecting
    private(set) var configurationLocation: CodexLocation?
    var hasManualPaths: Bool { !homePath.isEmpty || !executablePath.isEmpty }
    private(set) var codexServiceWarning: String? { didSet { updateMenuLabel() } }
    @ObservationIgnored private var previouslyHadCodexServices = false
    var codexReadState: TaskSourceReadState = .detecting { didSet { updateMenuLabel() } }
    private(set) var codexServicesAvailable = false { didSet { updateMenuLabel() } }
    var isPreview = false { didSet { updateMenuLabel() } }
    @ObservationIgnored private var codexReadAt: Date?
    @ObservationIgnored private let resolveLocation: @Sendable (String, String) -> CodexLocation
    @ObservationIgnored private let inspectServices: @Sendable (CodexLocation) -> Bool

    private(set) var menuLabel = L10n.text("Quota — · Running —")

    @ObservationIgnored private var quotaState = QuotaDisplayState()
    @ObservationIgnored private var calibrationPolicy = QuotaCalibrationPolicy()
    @ObservationIgnored private var calibrationTask: Task<Void, Never>?
    @ObservationIgnored private var quotaPollingTask: Task<Void, Never>?
    @ObservationIgnored private var quotaWakeAt: Date?
    @ObservationIgnored private var lastQuotaAttemptAt: Date?
    @ObservationIgnored private var automaticQuotaEnabled = false
    @ObservationIgnored private var serviceRevision = 0
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var lifecycleRevision = 0
    @ObservationIgnored private var detectionRevision = 0
    @ObservationIgnored private var pathRevisions: [CodexPathField: Int] = [:]
    @ObservationIgnored private let inspectConfiguration: @Sendable (String, String) async -> CodexConfigurationReport
    @ObservationIgnored private let validatePath: @Sendable (String, CodexPathField) async -> CodexPathError?
    @ObservationIgnored private var authStamp: String?
    @ObservationIgnored private var suspended = false
    @ObservationIgnored private var attemptedLocalRead = false
    /// Reader outputs remain separate from project-resolved presentation snapshots.
    @ObservationIgnored private var codexTasks: [TaskSnapshot] = []
    @ObservationIgnored private var codexAncestors: [TaskReference] = []
    @ObservationIgnored private let readLocal: @Sendable (URL) async throws -> TaskReadResult
    @ObservationIgnored private let resolveProjects: @Sendable ([TaskSnapshot], [TaskReference], URL) async -> TaskProjectResolution
    @ObservationIgnored private let fetchQuota: @Sendable (CodexLocation) async -> QuotaRefresh
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let clock: PollingClock
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private lazy var scheduler = PollingScheduler(clock: clock) { [weak self] in
        await self?.refreshLocal()
    }

    init(readLocal: (@Sendable (URL) async throws -> TaskReadResult)? = nil,
         resolveProjects: (@Sendable ([TaskSnapshot], [TaskReference], URL) async -> TaskProjectResolution)? = nil,
         fetchQuota: (@Sendable (CodexLocation) async -> QuotaRefresh)? = nil,
         clock: PollingClock = .continuous(), now: @escaping @MainActor () -> Date = Date.init,
         defaults: UserDefaults = .standard,
         inspectConfiguration: @escaping @Sendable (String, String) async -> CodexConfigurationReport = CodexConfiguration.inspect,
         validatePath: @escaping @Sendable (String, CodexPathField) async -> CodexPathError? = CodexConfiguration.validate,
         inspectServices: @escaping @Sendable (CodexLocation) -> Bool = CodexConfiguration.servicesAvailable,
         resolveLocation: @escaping @Sendable (String, String) -> CodexLocation = { .resolve(homePath: $0, executablePath: $1) }) {
        self.resolveLocation = resolveLocation
        self.inspectServices = inspectServices
        self.inspectConfiguration = inspectConfiguration
        self.validatePath = validatePath
        let reader = LocalTaskReader()
        self.readLocal = readLocal ?? { try await reader.fetch(home: $0) }
        let projectResolver = TaskProjectResolver()
        self.resolveProjects = resolveProjects ?? { await projectResolver.resolve(tasks: $0, ancestors: $1, home: $2) }
        self.fetchQuota = fetchQuota ?? { location in
            let client = AppServerClient()
            let result = await client.fetch(location: location)
            await client.shutdown()
            return result
        }
        self.clock = clock; self.now = now; self.defaults = defaults
        homePath = defaults.string(forKey: "codexHome") ?? ""
        executablePath = defaults.string(forKey: "codexExecutable") ?? ""
        codexServicesAvailable = inspectServices(resolveLocation(homePath, executablePath))
        previouslyHadCodexServices = codexServicesAvailable
        updateMenuLabel()
    }
    var location: CodexLocation { resolveLocation(homePath, executablePath) }
    var runningTasks: [TaskSnapshot] { tasks.filter { $0.activity == .running } }
    var canUseCodexServices: Bool { isPreview ? previewCodexServicesAvailable : codexServicesAvailable }
    var previewCodexServicesAvailable = true { didSet { updateMenuLabel() } }
    var showsQuota: Bool { canUseCodexServices }
    /// Task health is independent of the executable paths used for online quota.
    var hasSourceWarning: Bool { taskError != nil || taskWarning != nil }
    var taskSourceWarningSummary: String? {
        hasSourceWarning ? L10n.text("Some task data is unavailable. Running count may be incomplete.") : nil
    }
    var sourceDetectionFinished: Bool { codexReadState != .detecting }
    var noSourcesFound: Bool { codexReadState == .notFound && !canUseCodexServices }
    var codexHasNoTaskData: Bool { codexReadState == .notFound && canUseCodexServices }
    var menuQuotaPercent: Double? { showsQuota ? quota.snapshot?.menuWindow?.remainingPercent : nil }
    var menuQuotaWindows: [QuotaWindow] { showsQuota ? (quota.snapshot?.menuWindows ?? []) : [] }
    var menuTaskCount: String {
        hasTaskSnapshot || codexReadState == .notFound ? String(runningTasks.count) : "—"
    }
    var pollingSeconds: Int {
        Int(TaskPollingPolicy.interval(panelVisible: panelVisible, hasRunningTasks: !runningTasks.isEmpty).components.seconds)
    }

    var menuAccessibilityLabel: String {
        L10n.text("Veyra, \(menuLabel)")
    }

    private func updateMenuLabel() {
        let quotaLabel: String
        if showsQuota, !menuQuotaWindows.isEmpty {
            let marker = quota.error == nil ? "" : "*"
            quotaLabel = menuQuotaWindows.map {
                "\($0.durationLabel) \(DisplayFormat.percent($0.remainingPercent))\(marker)"
            }.joined(separator: " · ")
        } else { quotaLabel = L10n.text("Quota —") }
        let label = showsQuota ? L10n.text("\(quotaLabel) · Running \(menuTaskCount)") : L10n.text("Running \(menuTaskCount)")
        let notices = [taskSourceWarningSummary, codexServiceWarning].compactMap { $0 }
        let status = ([label] + notices).joined(separator: " · ")
        if menuLabel != status { menuLabel = status }
    }
    func start() {
        guard !isPreview else { return }
        lifecycleRevision += 1
        suspended = false
        automaticQuotaEnabled = true
        scheduler.start()
    }
    func stop() {
        lifecycleRevision += 1
        automaticQuotaEnabled = false
        quotaPollingTask?.cancel(); quotaPollingTask = nil; quotaWakeAt = nil
        scheduler.stop()
    }
    func setPanelVisible(_ visible: Bool) {
        guard panelVisible != visible else { return }
        panelVisible = visible
        guard !isPreview else { return }
        scheduler.update(panelVisible: visible, hasRunningTasks: !runningTasks.isEmpty)
    }
    func sleep() { suspended = true; stop() }
    func wake() { start() }

    /// Refresh local activity; the independent quota schedule never blocks task reads.
    func refreshAll() async {
        guard !isPreview, !suspended else { return }
        tasksBusy = true
        await scheduler.refreshNow()
        tasksBusy = false
    }
    func calibrateQuota() async {
        guard !isPreview, !suspended else { return }
        let location = location
        refreshServiceAvailability()
        guard showsQuota else { return }
        let initialAuth = checkAuthentication(at: location.home)
        if let calibrationTask { await calibrationTask.value; return }
        guard calibrationPolicy.allowsRequest(at: now()) else { return }
        let version = revision, serviceVersion = serviceRevision, started = now()
        lastQuotaAttemptAt = started
        calibrationPolicy.began(at: started)
        nextCalibrationAt = calibrationPolicy.nextAllowedAt
        quotaBusy = true
        let task = Task { [weak self, fetchQuota] in
            let result = await fetchQuota(location)
            guard let self, version == self.revision else { return }
            self.refreshServiceAvailability()
            // Keep account-level cooldowns even when service availability changes
            // while the request is pending.
            self.calibrationPolicy.finished(result, startedAt: started, now: self.now())
            self.nextCalibrationAt = self.calibrationPolicy.nextAllowedAt
            let currentAuth = AppServerClient.authenticationStamp(at: location.home)
            if serviceVersion == self.serviceRevision, self.showsQuota {
                if currentAuth != initialAuth {
                    self.quotaState.invalidateAccount()
                    self.quotaState.error = L10n.text("Your sign-in has changed. Sync quota again.")
                } else { self.quotaState.apply(result) }
                self.publishQuota()
            }
            self.authStamp = currentAuth
            self.quotaBusy = false
            self.calibrationTask = nil
            self.scheduleQuotaRefresh()
        }
        calibrationTask = task
        await task.value
    }
    private func refreshLocal() async {
        let version = revision, location = location
        var ancestors = codexAncestors
        guard !suspended else { return }
        refreshServiceAvailability()
        if !attemptedLocalRead { tasksBusy = true; attemptedLocalRead = true }
        checkAuthentication(at: location.home)
        do {
            let result = try await readLocal(location.home)
            guard version == revision else { return }
            codexTasks = result.tasks
            codexAncestors = result.ancestors
            ancestors = result.ancestors
            codexReadAt = result.fetchedAt
            codexReadState = .available
            if taskWarning != result.warning { taskWarning = result.warning }
            if taskError != nil { taskError = nil }
        } catch {
            guard version == revision else { return }
            let missing = error is LocalTaskReadFailure
            let homeMissing: Bool
            if case LocalTaskReadFailure.homeMissing = error { homeMissing = true } else { homeMissing = false }
            let expected = codexReadAt != nil || (homeMissing && hasManualPaths)
            let message: String? = missing && !expected ? nil
                : L10n.text("Unable to read Codex task records. Check its data directory.")
            codexReadState = missing && !expected ? .notFound : .failed
            if taskError != message { taskError = message }
            taskWarning = nil
            codexTasks = codexTasks.map { task in
                var copy = task; copy.activity = .unknown
                return copy
            }
        }
        tasksUpdatedAt = codexReadAt
        let resolved = await resolveProjects(codexTasks, ancestors, location.home)
        guard version == revision else { return }
        if taskAncestors != resolved.ancestors { taskAncestors = resolved.ancestors }
        if tasks != resolved.tasks { tasks = resolved.tasks }
        if tasksBusy { tasksBusy = false }
        scheduler.update(panelVisible: panelVisible, hasRunningTasks: !runningTasks.isEmpty)
        scheduleQuotaRefresh()
    }

    /// Check service paths independently of local task database availability.
    func refreshServiceAvailability() {
        let available = inspectServices(location)
        let expectsServices = !executablePath.isEmpty || previouslyHadCodexServices
            || (!homePath.isEmpty && location.executable != nil)
        codexServiceWarning = !available && expectsServices
            ? L10n.text("Codex quota is unavailable. Check its paths in Settings.") : nil
        if available { previouslyHadCodexServices = true }
        let availabilityChanged = available != codexServicesAvailable
        if availabilityChanged {
            codexServicesAvailable = available
            serviceRevision += 1
            quotaState = QuotaDisplayState(); publishQuota()
            quotaPollingTask?.cancel(); quotaPollingTask = nil; quotaWakeAt = nil
        }
        guard availabilityChanged else { return }
        scheduleQuotaRefresh()
    }

    private func scheduleQuotaRefresh() {
        guard automaticQuotaEnabled, !suspended, !isPreview, showsQuota, !quotaBusy else {
            quotaPollingTask?.cancel(); quotaPollingTask = nil; quotaWakeAt = nil
            return
        }
        let interval: TimeInterval = runningTasks.isEmpty ? 3600 : 60
        let due = max(lastQuotaAttemptAt?.addingTimeInterval(interval) ?? now(),
                      calibrationPolicy.nextAllowedAt ?? .distantPast)
        guard quotaWakeAt != due || quotaPollingTask == nil else { return }
        quotaPollingTask?.cancel()
        quotaWakeAt = due
        quotaPollingTask = Task { [weak self, clock] in
            guard let self else { return }
            let delay = due.timeIntervalSince(self.now())
            do { if delay > 0 { try await clock.sleep(.seconds(delay)) } } catch { return }
            guard !Task.isCancelled, self.automaticQuotaEnabled, !self.suspended else { return }
            self.quotaPollingTask = nil; self.quotaWakeAt = nil
            await self.calibrateQuota()
        }
    }

    @discardableResult
    private func checkAuthentication(at home: URL) -> String {
        let stamp = AppServerClient.authenticationStamp(at: home)
        if let authStamp, authStamp != stamp {
            quotaState.invalidateAccount()
            quotaState.error = nil
            publishQuota()
        }
        authStamp = stamp
        return stamp
    }
    private func publishQuota() {
        if quota.snapshot != quotaState.snapshot || quota.account != quotaState.account || quota.error != quotaState.error
            || quota.resetCredits != quotaState.resetCredits {
            quota = quotaState
        }
    }
    func displayedPath(for field: CodexPathField) -> String {
        switch field {
        case .home: homePath.isEmpty ? configurationLocation?.home.path ?? "" : homePath
        case .executable: executablePath.isEmpty ? configurationLocation?.executable?.path ?? "" : executablePath
        }
    }

    func detectConfiguration() async {
        detectionRevision += 1
        let request = detectionRevision, version = revision
        configurationState = .detecting
        let report = await inspectConfiguration(homePath, executablePath)
        guard request == detectionRevision, version == revision, !Task.isCancelled else { return }
        configurationLocation = report.location
        configurationState = report.state
    }

    func commitPath(_ text: String, field: CodexPathField, resetVersion: Int? = nil) async -> CodexPathCommitResult {
        guard resetVersion == nil || resetVersion == pathResetRevision else { return .superseded }
        let path = CodexConfiguration.normalized(text)
        pathRevisions[field, default: 0] += 1
        let request = pathRevisions[field]
        let error = await validatePath(path, field)
        guard request == pathRevisions[field], !Task.isCancelled else { return .superseded }
        if let error { return .rejected(error) }
        let oldPath = field == .home ? homePath : executablePath
        guard path != oldPath else { return .unchanged }
        saveSettings(home: field == .home ? path : homePath,
                     executable: field == .executable ? path : executablePath)
        await detectConfiguration()
        return .applied
    }

    func restoreAutomaticPaths() async {
        // Invalidate pending and queued field validations before clearing both overrides.
        pathResetRevision += 1
        for field in CodexPathField.allCases { pathRevisions[field, default: 0] += 1 }
        if hasManualPaths { saveSettings(home: "", executable: "") }
        await detectConfiguration()
    }

    func saveSettings(home: String, executable: String) {
        stop()
        revision += 1
        detectionRevision += 1
        configurationState = .detecting
        calibrationTask = nil
        homePath = home.trimmingCharacters(in: .whitespacesAndNewlines)
        executablePath = executable.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(homePath, forKey: "codexHome")
        defaults.set(executablePath, forKey: "codexExecutable")
        quotaState = QuotaDisplayState(); quota = quotaState
        calibrationPolicy = QuotaCalibrationPolicy(); nextCalibrationAt = nil; authStamp = nil
        lastQuotaAttemptAt = nil; serviceRevision += 1
        tasks = []
        codexReadAt = nil; tasksUpdatedAt = nil
        taskError = nil; taskWarning = nil; codexReadState = .detecting
        codexTasks = []
        codexAncestors = []
        taskAncestors = []
        quotaBusy = false; tasksBusy = false
        refreshServiceAvailability()
        attemptedLocalRead = false
        // Join any old local read, then immediately read the new location once it has drained.
        let version = revision, lifecycle = lifecycleRevision
        Task { [weak self] in
            guard let self else { return }
            await self.scheduler.drain()
            guard version == self.revision, lifecycle == self.lifecycleRevision, !self.suspended else { return }
            self.start()
        }
    }
}
