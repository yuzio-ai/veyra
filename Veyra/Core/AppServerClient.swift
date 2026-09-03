import Foundation
import Darwin

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
        var didRequestQuota = false
        do {
            if process == nil { try await start(at: newLocation) }
            let auth = try await request("account/read", params: .object(["refreshToken": .bool(false)]))
            guard auth["account"].object != nil else {
                lastAccount = nil
                return QuotaRefresh(error: .notLoggedIn, invalidatePrevious: true)
            }
            let rawAccount = auth["account"]
            account = AccountSnapshot(json: rawAccount)
            guard account?.authType == "chatgpt" || account?.authType == "chatgptAuthTokens" else {
                lastAccount = account
                return QuotaRefresh(account: account, error: .unsupportedAuthentication, invalidatePrevious: true)
            }
            didRequestQuota = true
            let data = try await request("account/rateLimits/read")
            let snapshot = QuotaSnapshot.parse(data)
            account = AccountSnapshot(json: rawAccount, accountID: snapshot.accountID)
            let identityChanged = lastAccount != nil && lastAccount?.identity != account?.identity
            lastAccount = account
            // Codex may refresh its credentials while servicing the read.
            authStamp = Self.authenticationStamp(at: newLocation.home)
            return QuotaRefresh(account: account, snapshot: snapshot,
                                error: snapshot.windows.isEmpty ? .noQuotaWindows : nil,
                                invalidatePrevious: changed || identityChanged, didRequestQuota: true)
        } catch {
            shutdown()
            // Keep the full account identity when the account is unchanged but quota networking fails.
            if !changed, let old = lastAccount, old.email == account?.email, old.authType == account?.authType {
                account = old
            }
            let details = error as? QuotaFailureDetails
            return QuotaRefresh(account: account, error: details?.category ?? .classify(error), invalidatePrevious: changed,
                                failureDetails: details, didRequestQuota: didRequestQuota)
        }
    }

    private func start(at location: CodexLocation) async throws {
        guard let executable = location.executable, FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw QuotaFailure.missingExecutable
        }
        guard FileManager.default.fileExists(atPath: location.home.path) else {
            throw QuotaFailure.missingHome
        }
        let child = Process(), stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        // Suppress SIGPIPE only on our write descriptor; EPIPE must be a recoverable error.
        guard fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw QuotaFailure.launchFailed
        }
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
        do { try child.run() } catch { shutdown(); throw QuotaFailure.launchFailed }
        _ = try await request("initialize", params: .object([
            "clientInfo": .object(["name": .string("veyra"), "title": .string("Veyra"), "version": .string("1.0.0")]),
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
        guard let input else { throw QuotaFailure.disconnected }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        var data = try encoder.encode(message)
        data.append(0x0a)
        do { try input.write(contentsOf: data) }
        catch {
            shutdown(reason: .disconnected)
            throw QuotaFailure.disconnected
        }
    }

    private func receive(_ data: Data, generation: UUID) {
        guard generation == self.generation else { return }
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0a) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard let value = try? JSONValue.decode(line), let object = value.object else {
                shutdown(reason: .protocolError)
                return
            }
            guard let id = value["id"].integer, pending[id] != nil else { continue }
            if value["error"].object != nil {
                // Neither message nor data is retained: both can contain private account data.
                finish(id: id, result: .failure(QuotaFailureDetails(rpcError: value["error"])))
            } else if object["result"] != nil {
                finish(id: id, result: .success(value["result"]))
            } else {
                shutdown(reason: .protocolError)
                return
            }
        }
        if buffer.count > 8 * 1_024 * 1_024 { shutdown(reason: .protocolError) }
    }

    private func finish(id: Int64, result: Result<JSONValue, Error>) {
        timeouts.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: result)
    }
    private func timedOut(id: Int64) {
        guard pending[id] != nil else { return }
        shutdown(reason: .timeout)
    }
    private func exited(generation: UUID) {
        guard generation == self.generation else { return }
        shutdown(reason: .disconnected)
    }
    func shutdown(reason: QuotaFailure = .disconnected) {
        generation = UUID()
        output?.readabilityHandler = nil; errors?.readabilityHandler = nil
        try? input?.close()
        if let child = process, child.isRunning { child.terminate() }
        process?.terminationHandler = nil
        process = nil; input = nil; output = nil; errors = nil; buffer = Data()
        for id in Array(pending.keys) { finish(id: id, result: .failure(reason)) }
    }
    static func authenticationStamp(at home: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: home.appendingPathComponent("auth.json").path)
        let modified = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(attrs?[.systemFileNumber] ?? "missing"):\(modified):\(attrs?[.size] ?? 0)"
    }
}
