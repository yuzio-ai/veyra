import Foundation

@MainActor
struct PollingClock {
    var now: () -> Duration
    var sleep: (Duration) async throws -> Void

    static func continuous() -> PollingClock {
        let clock = ContinuousClock(), origin = ContinuousClock.now
        return PollingClock(now: { origin.duration(to: clock.now) }, sleep: { delay in
            try await clock.sleep(for: delay, tolerance: .milliseconds(200))
        })
    }
}

enum TaskPollingPolicy {
    static func interval(panelVisible: Bool, hasRunningTasks: Bool) -> Duration {
        panelVisible || hasRunningTasks ? .seconds(5) : .seconds(30)
    }
}

/// One in-flight refresh and one cancellable wait. Opening a panel joins an existing read.
@MainActor
final class PollingScheduler {
    private let clock: PollingClock
    private let refresh: @MainActor () async -> Void
    private var running: Task<Void, Never>?
    private var waiting: Task<Void, Never>?
    private var waitRevision = 0
    private var lastStart: Duration?
    private var enabled = false
    private var panelVisible = false
    private var hasRunningTasks = false

    init(clock: PollingClock = .continuous(), refresh: @escaping @MainActor () async -> Void) {
        self.clock = clock; self.refresh = refresh
    }
    func start() {
        guard !enabled else { return }
        enabled = true
        requestRefresh()
    }
    func stop() { enabled = false; cancelWait() }
    func drain() async { await running?.value }
    func update(panelVisible: Bool, hasRunningTasks: Bool) {
        let opened = !self.panelVisible && panelVisible
        let changed = self.panelVisible != panelVisible || self.hasRunningTasks != hasRunningTasks
        self.panelVisible = panelVisible; self.hasRunningTasks = hasRunningTasks
        guard enabled, changed else { return }
        if opened { requestRefresh() } else if running == nil { schedule() }
    }
    func refreshNow() async { await requestRefresh().value }

    @discardableResult
    private func requestRefresh() -> Task<Void, Never> {
        if let running { return running }
        cancelWait()
        lastStart = clock.now()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.refresh()
            self.running = nil
            if self.enabled { self.schedule() }
        }
        running = task
        return task
    }
    private func cancelWait() {
        waitRevision += 1; waiting?.cancel(); waiting = nil
    }
    private func schedule() {
        cancelWait()
        let interval = TaskPollingPolicy.interval(panelVisible: panelVisible, hasRunningTasks: hasRunningTasks)
        let deadline = max(clock.now() + .seconds(1), (lastStart ?? clock.now()) + interval)
        let revision = waitRevision
        waiting = Task { [weak self, clock] in
            do {
                let delay = deadline - clock.now()
                if delay > .zero { try await clock.sleep(delay) }
            } catch { return }
            guard let self, !Task.isCancelled, self.enabled, revision == self.waitRevision else { return }
            self.waiting = nil
            self.requestRefresh()
        }
    }
}
