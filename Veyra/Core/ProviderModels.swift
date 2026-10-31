import Foundation

enum ModelDiscoveryFailure: String, Error, Codable, Equatable, LocalizedError, Sendable {
    case authentication, network, timeout, rateLimited, server, invalidResponse, tooLarge, storage, unavailable
    var errorDescription: String? {
        switch self {
        case .authentication: L10n.text("The provider rejected this API Key. Replace it or refresh successfully before enabling.")
        case .network: L10n.text("Unable to fetch models. Check your connection and retry.")
        case .timeout: L10n.text("Fetching models timed out. Try again.")
        case .rateLimited: L10n.text("The provider is limiting model requests. Try again later.")
        case .server: L10n.text("The provider could not return models. Try again later.")
        case .invalidResponse: L10n.text("The provider returned an unsupported model list.")
        case .tooLarge: L10n.text("The provider model list exceeds the size limit.")
        case .storage: L10n.text("Unable to save the model list locally.")
        case .unavailable: L10n.text("Fetch models and choose a model before enabling this provider.")
        }
    }
    static func safe(_ error: Error) -> Self {
        if let error = error as? Self { return error }
        if (error as? URLError)?.code == .timedOut { return .timeout }
        return .network
    }
}

struct DiscoveredModel: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String?
    var contextWindow: Int?
    var inputModalities: [String]?
    var reasoningLevels: [String]?
    var defaultReasoning: String?

    init(id: String, name: String? = nil, contextWindow: Int? = nil, inputModalities: [String]? = nil,
         reasoningLevels: [String]? = nil, defaultReasoning: String? = nil) {
        self.id = id; self.name = name; self.contextWindow = contextWindow
        self.inputModalities = inputModalities; self.reasoningLevels = reasoningLevels; self.defaultReasoning = defaultReasoning
    }
    static func validToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512
            && !value.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }
    }
}

struct ProviderModelScope: Codable, Equatable, Sendable {
    var providerID: String
    var baseURL: String
    var credential: CredentialReference?
    var authentication: ModelProfileAuthentication?
    init?(_ settings: ProviderSettings) {
        guard settings.authMode != .environment, settings.authMode != .keychain || settings.credential != nil else { return nil }
        providerID = settings.id; baseURL = settings.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.credential = settings.authMode == .keychain ? settings.credential : nil
        authentication = settings.authMode == .none ? ModelProfileAuthentication.none : nil
    }
}

struct ProviderModelCache: Codable, Equatable, Sendable {
    var scope: ProviderModelScope
    var models: [DiscoveredModel] = []
    var fetchedAt: Date?
    var failure: ModelDiscoveryFailure?
    var permitsEnable: Bool {
        fetchedAt != nil && (failure.map { [.network, .timeout, .rateLimited, .server].contains($0) } ?? true)
    }
    func contains(_ id: String) -> Bool { permitsEnable && models.contains { $0.id == id } }
}

protocol ProviderModelClient: Sendable {
    func models(preset: ProviderPreset, baseURL: String, key: String) async throws -> [DiscoveredModel]
    func models(provider: ProviderSettings, key: String?) async throws -> [DiscoveredModel]
}
extension ProviderModelClient {
    func models(provider: ProviderSettings, key: String?) async throws -> [DiscoveredModel] {
        try await models(preset: provider.modelAdapter, baseURL: provider.baseURL, key: key ?? "")
    }
}
extension ProviderSettings {
    var modelAdapter: ProviderPreset {
        ProviderPreset.find(id) ?? ProviderPreset(id: id, name: displayName, baseURL: baseURL, source: "", uuid: UUID(uuidString: id) ?? UUID())
    }
}

final class ProviderModelRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var blocked = false
    var rejected: Bool { lock.lock(); defer { lock.unlock() }; return blocked }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock(); blocked = true; lock.unlock()
        completionHandler(nil)
    }
}

struct URLSessionProviderModelClient: ProviderModelClient {
    static let maximumBytes = 2 * 1024 * 1024
    // Protocol classes are injectable for isolated URLProtocol tests, never user configuration.
    var protocolClasses: [AnyClass] = []

    func models(preset: ProviderPreset, baseURL: String, key: String) async throws -> [DiscoveredModel] {
        var provider = ProviderSettings(preset: preset); provider.baseURL = baseURL
        return try await fetch(provider: provider, key: key)
    }
    func models(provider: ProviderSettings, key: String?) async throws -> [DiscoveredModel] {
        try await fetch(provider: provider, key: key)
    }
    private func fetch(provider: ProviderSettings, key: String?) async throws -> [DiscoveredModel] {
        let baseURL = provider.baseURL, preset = provider.modelAdapter
        guard ProviderSettings.validEndpoint(baseURL), let base = URL(string: baseURL) else {
            throw ModelDiscoveryFailure.invalidResponse
        }
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 15
        if !protocolClasses.isEmpty { config.protocolClasses = protocolClasses }
        let redirects = ProviderModelRedirectGuard()
        let session = URLSession(configuration: config, delegate: redirects, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: base.appendingPathComponent("models"), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"; request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let key { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw ModelDiscoveryFailure.invalidResponse }
            switch response.statusCode {
            case 200: break
            case 401, 403: throw ModelDiscoveryFailure.authentication
            case 429: throw ModelDiscoveryFailure.rateLimited
            case 500...599: throw ModelDiscoveryFailure.server
            default: throw ModelDiscoveryFailure.invalidResponse
            }
            guard response.expectedContentLength <= Self.maximumBytes else { throw ModelDiscoveryFailure.tooLarge }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < Self.maximumBytes else { throw ModelDiscoveryFailure.tooLarge }
                data.append(byte)
            }
            let models = try Self.parse(data, preset: preset)
            // Even allowed display fields must not persist a credential reflected by a server.
            guard key == nil || !models.contains(where: { model in
                ([model.id] + [model.name, model.defaultReasoning].compactMap { $0 } + (model.reasoningLevels ?? []))
                    .contains { $0.contains(key ?? "") }
            }) else { throw ModelDiscoveryFailure.invalidResponse }
            return models
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            if redirects.rejected { throw ModelDiscoveryFailure.invalidResponse }
            throw ModelDiscoveryFailure.safe(error)
        }
    }

    static func parse(_ data: Data, preset: ProviderPreset) throws -> [DiscoveredModel] {
        guard data.count <= maximumBytes, let root = try? JSONValue.decode(data), root.object != nil else {
            throw data.count > maximumBytes ? ModelDiscoveryFailure.tooLarge : .invalidResponse
        }
        // GLM can return an application-level authentication error with HTTP 200.
        if preset.id == "glm", root["success"].bool == false,
           [1001, 1002, 1003, 1004].contains(root["code"].integer ?? -1) { throw ModelDiscoveryFailure.authentication }
        guard root["success"].bool != false, root["error"] == .null else { throw ModelDiscoveryFailure.invalidResponse }
        let native = preset.id == "glm" && root["data"] == .null
        guard let rows = root[native ? "models" : "data"].array else { throw ModelDiscoveryFailure.invalidResponse }
        var seen: Set<String> = []
        var result: [DiscoveredModel] = []
        for row in rows {
            guard let id = row[native ? "slug" : "id"].string, DiscoveredModel.validToken(id) else {
                throw ModelDiscoveryFailure.invalidResponse
            }
            guard seen.insert(id).inserted else { continue }
            let rawContext = row["context_window"].integer ?? row["context_length"].integer
            let context = rawContext.flatMap { $0 > 0 && $0 <= Int64(Int.max) ? Int(exactly: $0) : nil }
            var modalities = row["input_modalities"].array?.compactMap(\.string)
            if modalities == nil, row["supports_image_in"].bool != nil {
                modalities = ["text"] + (row["supports_image_in"].bool == true ? ["image"] : [])
            }
            let effort = row["effort"]["supported_levels"].array?.compactMap(\.string)
                ?? row["supported_reasoning_levels"].array?.compactMap { $0["effort"].string ?? $0.string }
            let levels = effort.map { Array(NSOrderedSet(array: $0.filter(DiscoveredModel.validToken))) as? [String] ?? [] }
            let proposedDefault = row["effort"]["default_level"].string ?? row["default_reasoning_level"].string
            let defaultEffort = proposedDefault.flatMap { levels?.contains($0) == true ? $0 : nil }
            let name = row["name"].string ?? row["display_name"].string
            result.append(DiscoveredModel(id: id, name: name.flatMap { $0.count <= 512 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) ? $0 : nil },
                contextWindow: context, inputModalities: modalities.map { $0.filter { ["text", "image", "audio"].contains($0) } },
                reasoningLevels: levels, defaultReasoning: defaultEffort))
        }
        return result
    }
}

/// Codex's wire schema needs a few client defaults even when the provider supplies only IDs.
/// Model-specific capacities and effort levels are never invented. Instructions are owned locally.
enum ProviderRuntimeCatalog {
    static func build(models: [DiscoveredModel], preset: ProviderPreset, settings: ProviderSettings) -> JSONValue {
        .object(["models": .array(models.map { model in
            var value: [String: JSONValue] = [
                "slug": .string(model.id), "display_name": .string(model.name ?? model.id), "description": .string(""),
                "supported_reasoning_levels": .array((model.reasoningLevels ?? []).map { .object(["effort": .string($0), "description": .string($0)]) }),
                "shell_type": .string("unified_exec"), "visibility": .string("list"), "supported_in_api": .bool(true),
                "priority": .number(0), "support_verbosity": .bool(false), "supports_reasoning_summaries": .bool(false),
                "truncation_policy": .object(["mode": .string("bytes"), "limit": .number(10000)]),
                "experimental_supported_tools": .array([]), "use_responses_lite": .bool(preset.id == "mimo"),
                "base_instructions": .string("You are a coding assistant. Follow the user instructions and repository guidelines.")
            ]
            if preset.id != "kimi" { value["apply_patch_tool_type"] = .string("freeform") }
            if let context = model.id == settings.model ? settings.contextWindowOverride ?? model.contextWindow : model.contextWindow {
                value["context_window"] = .number(Double(context))
            }
            if let input = model.inputModalities { value["input_modalities"] = .array(input.map(JSONValue.string)) }
            if let effort = model.defaultReasoning { value["default_reasoning_level"] = .string(effort) }
            return .object(value)
        })])
    }
}
