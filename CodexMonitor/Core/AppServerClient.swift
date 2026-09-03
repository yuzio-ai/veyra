import Foundation

/// Owns only the monitor's sidecar; never attaches, resumes, or writes a Codex task.
actor AppServerClient {
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errors: FileHandle?
    private var buffer = Data()
    private var pending: [Int64: CheckedContinuation<JSONValue, Error>] = [:]
    private var timeouts: [Int64: Task<Void, Never>] = [:]
    private var nextID: Int64 = 0
    private var generation = UUID()
    private var location: CodexLocation?
    private var authStamp: String?
    private var lastAccount: AccountSnapshot?
    private let requestTimeout: Duration

    init(requestTimeout: Duration = .seconds(25)) { self.requestTimeout = requestTimeout }

    func fetch(location newLocation: CodexLocation) async -> QuotaRefresh {
        let stamp = Self.authenticationStamp(at: newLocation.home)
        let changed = location != nil && (location != newLocation || authStamp != stamp)
        if location != newLocation || authStamp != stamp { shutdown() }
        location = newLocation
        authStamp = stamp
        var account: AccountSnapshot?
        do {
            if process == nil { try await start(at: newLocation) }
            let auth = try await request("account/read", params: .object(["refreshToken": .bool(false)]))
            guard auth["account"].object != nil else {
                lastAccount = nil
                return QuotaRefresh(error: "尚未登录 Codex。请先在 Codex 桌面端或 CLI 中登录。", invalidatePrevious: true)
            }
            let rawAccount = auth["account"]
            account = AccountSnapshot(json: rawAccount)
            guard account?.authType == "chatgpt" || account?.authType == "chatgptAuthTokens" else {
                lastAccount = account
                return QuotaRefresh(account: account, error: "当前登录方式不提供 ChatGPT 订阅额度。", invalidatePrevious: true)
            }
            let data = try await request("account/rateLimits/read")
            let snapshot = QuotaSnapshot.parse(data)
            account = AccountSnapshot(json: rawAccount, accountID: snapshot.accountID)
            let identityChanged = lastAccount != nil && lastAccount?.identity != account?.identity
            lastAccount = account
            // Codex may refresh its credentials while servicing the read.
            authStamp = Self.authenticationStamp(at: newLocation.home)
            return QuotaRefresh(account: account, snapshot: snapshot,
                                error: snapshot.windows.isEmpty ? "账号暂未返回可用额度窗口。" : nil,
                                invalidatePrevious: changed || identityChanged)
        } catch {
            shutdown()
            // Keep the full account identity when the account is unchanged but quota networking fails.
            if !changed, let old = lastAccount, old.email == account?.email, old.authType == account?.authType {
                account = old
            }
            return QuotaRefresh(account: account, error: error.localizedDescription, invalidatePrevious: changed)
        }
    }

    private func start(at location: CodexLocation) async throws {
        guard let executable = location.executable, FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw MonitorFailure("未找到 Codex 可执行文件，请在设置中指定。")
        }
        guard FileManager.default.fileExists(atPath: location.home.path) else {
            throw MonitorFailure("Codex 数据目录不存在，请检查设置。")
        }
        let child = Process(), stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        let currentGeneration = UUID()
        generation = currentGeneration
        child.executableURL = executable
        child.arguments = ["app-server", "--stdio"]
        child.currentDirectoryURL = location.home
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = location.home.path
        child.environment = environment
        child.standardInput = stdinPipe; child.standardOutput = stdoutPipe; child.standardError = stderrPipe
        input = stdinPipe.fileHandleForWriting; output = stdoutPipe.fileHandleForReading; errors = stderrPipe.fileHandleForReading
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { await self?.receive(data, generation: currentGeneration) }
        }
        // Drain diagnostics, but never persist raw CLI output or credentials.
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        child.terminationHandler = { [weak self] _ in
            Task { await self?.exited(generation: currentGeneration) }
        }
        process = child
        do { try child.run() } catch { shutdown(); throw MonitorFailure("无法启动 Codex：\(error.localizedDescription)") }
        _ = try await request("initialize", params: .object([
            "clientInfo": .object(["name": .string("codex_monitor"), "title": .string("Codex Monitor"), "version": .string("1.0.0")]),
            "capabilities": .object(["experimentalApi": .bool(false)])
        ]))
        try send(.object(["method": .string("initialized")]))
    }

    private func request(_ method: String, params: JSONValue? = nil) async throws -> JSONValue {
        nextID += 1
        let id = nextID
        var message: [String: JSONValue] = ["id": .number(Double(id)), "method": .string(method)]
        if let params { message["params"] = params }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            timeouts[id] = Task { [weak self] in
                guard let self else { return }
                do { try await Task.sleep(for: self.requestTimeout) } catch { return }
                await self.timedOut(id: id)
            }
            do { try send(.object(message)) }
            catch { finish(id: id, result: .failure(error)) }
        }
    }

    private func send(_ message: JSONValue) throws {
        guard let input else { throw MonitorFailure("Codex 连接已断开。") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        var data = try encoder.encode(message)
        data.append(0x0a)
        try input.write(contentsOf: data)
    }

    private func receive(_ data: Data, generation: UUID) {
        guard generation == self.generation else { return }
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0a) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard let value = try? JSONValue.decode(line), let id = value["id"].integer else { continue }
            if value["error"].object != nil {
                // Backend messages may contain account data: show a bounded description, never log it.
                let description = value["error"]["message"].string ?? "未知错误"
                finish(id: id, result: .failure(MonitorFailure("额度读取失败：\(description.prefix(240))")))
            } else { finish(id: id, result: .success(value["result"])) }
        }
        if buffer.count > 8 * 1_024 * 1_024 { shutdown(reason: "Codex 返回了无法识别的数据。") }
    }

    private func finish(id: Int64, result: Result<JSONValue, Error>) {
        timeouts.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: result)
    }
    private func timedOut(id: Int64) {
        guard pending[id] != nil else { return }
        shutdown(reason: "连接 Codex 超时，稍后将自动重试。")
    }
    private func exited(generation: UUID) {
        guard generation == self.generation else { return }
        shutdown(reason: "Codex 连接已断开，稍后将自动重试。")
    }
    func shutdown(reason: String = "连接已重新建立。") {
        generation = UUID()
        output?.readabilityHandler = nil; errors?.readabilityHandler = nil
        try? input?.close()
        if let child = process, child.isRunning { child.terminate() }
        process?.terminationHandler = nil
        process = nil; input = nil; output = nil; errors = nil; buffer = Data()
        for id in Array(pending.keys) { finish(id: id, result: .failure(MonitorFailure(reason))) }
    }
    private static func authenticationStamp(at home: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: home.appendingPathComponent("auth.json").path)
        let modified = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(attrs?[.systemFileNumber] ?? "missing"):\(modified):\(attrs?[.size] ?? 0)"
    }
}
