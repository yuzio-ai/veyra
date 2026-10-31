import Foundation

enum ModelProfileKind: String, Codable, CaseIterable, Sendable {
    case official, custom, reference
}

enum ModelProfileAuthentication: String, Codable, CaseIterable, Sendable {
    case environment, none, keychain
}

/// Display identity only. A model name never establishes a provider's identity.
struct CodexProviderIdentity: Equatable, Sendable {
    var name: String
    var isOfficial = false

    var initial: String? {
        name.trimmingCharacters(in: .whitespacesAndNewlines).first.map {
            // Uppercase can expand a character (for example ß); keep one grapheme.
            String(String($0).uppercased().prefix(1))
        }
    }
}

struct CodexModelProfile: Codable, Equatable, Identifiable, Sendable {
    static let supportedReasoning = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]
    var id = UUID()
    var name: String
    var kind: ModelProfileKind = .official
    var model = ""
    var baseURL = ""
    var reasoning = ""
    var authentication: ModelProfileAuthentication = .environment
    var environmentKey = ""
    var providerName = ""
    var catalogPath = ""
    // References never copy provider credentials or unrecognized provider settings.
    var presetID: String?
    var credentialReference: CredentialReference?
    var helperPath: String?
    var contextWindow: Int?
    var referencedProvider: String?
    var referencedOpenAIBaseURL: String?

    var providerID: String {
        switch kind {
        case .official: "openai"
        case .custom: presetID.map { "veyra_preset_" + $0 } ?? ("veyra_" + id.uuidString.replacingOccurrences(of: "-", with: "").lowercased())
        case .reference: referencedProvider ?? "openai"
        }
    }

    var provider: JSONValue {
        var fields: [String: JSONValue] = [
            "name": .string(providerName.isEmpty ? name : providerName),
            "base_url": .string(baseURL), "wire_api": .string("responses")
        ]
        if authentication == .environment { fields["env_key"] = .string(environmentKey) }
        if authentication == .keychain, let credentialReference, let helperPath {
            fields["auth"] = .object(["command": .string(helperPath),
                "args": .array([.string("--provider-credential"), .string(credentialReference.argument)]),
                "timeout_ms": .number(5000), "refresh_interval_ms": .number(0)])
        }
        return .object(fields)
    }

    var providerIdentity: CodexProviderIdentity {
        let official = kind == .official || (kind == .reference && providerID == "openai" && referencedOpenAIBaseURL == nil)
        if official { return CodexProviderIdentity(name: "OpenAI", isOfficial: true) }
        let provider = providerName.trimmingCharacters(in: .whitespacesAndNewlines)
        return CodexProviderIdentity(name: provider.isEmpty ? name.trimmingCharacters(in: .whitespacesAndNewlines) : provider)
    }

    /// Provider membership deliberately ignores the default model, effort and catalog.
    /// Imported connections can use an existing ID; exact IDs are preferred by the caller.
    func matchesProvider(_ snapshot: CodexConfigSnapshot) -> Bool {
        guard snapshot.configuredOpenAIBaseURL == (kind == .reference ? referencedOpenAIBaseURL : nil) else { return false }
        if kind != .custom { return snapshot.configuredProviderID == providerID }
        let actual = snapshot.configuredProvider
        if authentication == .keychain {
            return snapshot.configuredProviderID == providerID && actual["base_url"].string == baseURL
                && actual["auth"]["args"] == provider["auth"]["args"]
        }
        return actual["base_url"].string == baseURL
            && actual["env_key"].string == (authentication == .none ? nil : environmentKey)
            && (actual["wire_api"].string ?? "responses") == "responses"
            && Set(actual.object?.keys.map { $0 } ?? []).isSubset(of: ["name", "base_url", "wire_api", "env_key"])
    }

    func normalized() -> Self {
        var result = self
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        result.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        result.environmentKey = environmentKey.trimmingCharacters(in: .whitespacesAndNewlines)
        result.providerName = providerName.trimmingCharacters(in: .whitespacesAndNewlines)
        result.catalogPath = catalogPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }

    var validation: [String: String] {
        let value = normalized()
        var errors: [String: String] = [:]
        if value.name.isEmpty { errors["name"] = L10n.text("Enter a profile name.") }
        if value.kind == .custom {
            if value.model.isEmpty { errors["model"] = L10n.text("Enter a model name.") }
            if !Self.validServiceURL(value.baseURL) {
                errors["baseURL"] = L10n.text("Enter an HTTP or HTTPS address without credentials, query, or fragment.")
            }
            if value.authentication == .keychain, (credentialReference == nil || helperPath?.hasPrefix("/") != true) {
                errors["credential"] = L10n.text("API Key is missing. Enter it again in Settings.")
            }
            if value.authentication == .environment,
               value.environmentKey.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) == nil {
                errors["environmentKey"] = L10n.text("Enter a valid environment variable name.")
            }
        }
        if !value.catalogPath.isEmpty, !(value.catalogPath as NSString).isAbsolutePath {
            errors["catalogPath"] = L10n.text("Use an absolute model catalog path.")
        }
        if !value.reasoning.isEmpty && !Self.supportedReasoning.contains(value.reasoning) {
            errors["reasoning"] = L10n.text("Choose a supported reasoning effort.")
        }
        return errors
    }

    static func validServiceURL(_ value: String) -> Bool {
        guard let url = URLComponents(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else { return false }
        return url.user == nil && url.password == nil && url.query == nil && url.fragment == nil
    }

    func matches(_ snapshot: CodexConfigSnapshot) -> Bool {
        let config = snapshot.user
        if authentication == .keychain {
            return matchesProvider(snapshot) && config["model"].string == model
                && snapshot.configuredProvider["auth"] == provider["auth"]
                && config["model_reasoning_effort"].string ?? "" == reasoning
                && config["model_catalog_json"].string ?? "" == catalogPath
        }
        guard config["model"].string ?? "" == model,
              config["model_reasoning_effort"].string ?? "" == reasoning,
              config["model_catalog_json"].string ?? "" == catalogPath else { return false }
        let actualProvider = config["model_provider"].string ?? "openai"
        if kind == .custom {
            let raw = snapshot.user["model_providers"][actualProvider]
            let actual = raw.object == nil ? snapshot.effective["model_providers"][actualProvider] : raw
            return actual["base_url"].string == baseURL && actual["env_key"].string == (authentication == .none ? nil : environmentKey)
                && actual["wire_api"].string ?? "responses" == "responses"
                && config["openai_base_url"].string == nil
                && Set(actual.object?.keys.map { $0 } ?? []).isSubset(of: ["name", "base_url", "wire_api", "env_key"])
        }
        return actualProvider == providerID && config["openai_base_url"].string == (kind == .reference ? referencedOpenAIBaseURL : nil)
    }
}

struct CodexConfigSnapshot: Equatable, Sendable {
    var user: JSONValue
    var effective: JSONValue
    var version: String
    var file: URL
    var overridden = false

    var configuredProviderID: String { user["model_provider"].string ?? effective["model_provider"].string ?? "openai" }
    var configuredOpenAIBaseURL: String? { user["openai_base_url"].string ?? effective["openai_base_url"].string }
    var configuredProvider: JSONValue {
        let raw = user["model_providers"][configuredProviderID]
        return raw.object == nil ? effective["model_providers"][configuredProviderID] : raw
    }
    var providerIdentity: CodexProviderIdentity {
        if configuredProviderID == "openai", configuredOpenAIBaseURL == nil {
            return CodexProviderIdentity(name: "OpenAI", isOfficial: true)
        }
        let name = configuredProvider["name"].string?.trimmingCharacters(in: .whitespacesAndNewlines)
        // An OpenAI base URL override is a custom route, never the official logo.
        let fallback = configuredProviderID == "openai" ? L10n.text("Custom service") : configuredProviderID
        return CodexProviderIdentity(name: name.flatMap { $0.isEmpty ? nil : $0 } ?? fallback)
    }

    init(user: JSONValue, effective: JSONValue? = nil, version: String, file: URL, overridden: Bool = false) {
        self.user = user; self.effective = effective ?? user
        self.version = version; self.file = file; self.overridden = overridden
    }

    init(response: JSONValue, home: URL) throws {
        let expected = home.appendingPathComponent("config.toml").resolvingSymlinksInPath().standardizedFileURL
        guard let layers = response["layers"].array,
              let layer = layers.first(where: {
                  $0["name"]["type"].string == "user" && $0["name"]["profile"].string == nil
                  && $0["name"]["file"].string.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL == expected } == true
              }), let version = layer["version"].string, !version.isEmpty, layer["config"].object != nil else {
            throw ModelProfileFailure.unsupported
        }
        self.init(user: layer["config"], effective: response["config"], version: version, file: expected,
                  overridden: layer["disabledReason"].string != nil)
        let controlled = ["model", "model_provider", "model_reasoning_effort", "model_catalog_json", "openai_base_url"]
        overridden = overridden || controlled.contains { user.object?[$0] != nil && user[$0] != effective[$0] }
    }

    func value(at path: String) -> JSONValue {
        path.split(separator: ".").reduce(user) { $0[String($1)] }
    }
}

struct CodexConfigEdit: Codable, Equatable, Sendable {
    var keyPath: String
    var value: JSONValue
    var rpc: JSONValue { .object(["keyPath": .string(keyPath), "value": value, "mergeStrategy": .string("replace")]) }
}

struct CodexConfigWriteReceipt: Sendable {
    var version: String
    var overridden: Bool
}

protocol CodexModelConfigurationTransport: Sendable {
    func readConfiguration(location: CodexLocation) async throws -> CodexConfigSnapshot
    func writeConfiguration(location: CodexLocation, edits: [CodexConfigEdit], expectedVersion: String) async throws -> CodexConfigWriteReceipt
}

enum ModelProfileFailure: Error, Equatable, Sendable, LocalizedError {
    case unsupported, conflict, invalid, unavailable, storage, busy, changed, referenceMissing, unsafeBackup

    var errorDescription: String? {
        switch self {
        case .unsupported: L10n.text("This Codex version does not support model configuration. Update Codex and retry.")
        case .conflict: L10n.text("Codex configuration changed. It has been reloaded. Review it and retry.")
        case .invalid: L10n.text("Codex rejected this configuration. Check the profile fields and provider compatibility.")
        case .unavailable: L10n.text("Unable to read or update Codex configuration. Check its paths and retry.")
        case .storage: L10n.text("Unable to save model profiles or the recovery record. No further changes were made.")
        case .busy: L10n.text("A model configuration operation is already in progress.")
        case .changed: L10n.text("Configuration fields changed outside Veyra. Reload or resolve the configuration before switching providers.")
        case .referenceMissing: L10n.text("The referenced provider is unavailable. Restore it in Codex or create a custom profile.")
        case .unsafeBackup: L10n.text("The existing service address contains credentials. Move them to Codex authentication before switching.")
        }
    }

    static func rpc(_ value: JSONValue) -> Self {
        switch value["data"]["config_write_error_code"].string {
        case "configVersionConflict": .conflict
        case "configValidationError": .invalid
        default: value["code"].integer == -32601 ? .unsupported : .invalid
        }
    }
}

struct ModelProfileJournal: Codable, Equatable, Sendable {
    var before: [CodexConfigEdit]
    var after: [CodexConfigEdit]
}

struct ModelProfileLibrary: Codable, Equatable, Sendable {
    var schemaVersion = 3
    var connections: [ProviderDescriptor] = []
    var openAISnapshot: [CodexConfigEdit]?
    var pending: ModelProfileJournal?
    // Compatibility projections; only connections is serialized in schema 3.
    var profiles: [CodexModelProfile] {
        get { connections.compactMap(\.legacyValue) }
        set { connections.removeAll { $0.legacyProfile != nil }; connections += newValue.map(ProviderSettings.init(profile:)) }
    }
    var providers: [ProviderSettings] {
        get { connections.filter { $0.legacyProfile == nil } }
        set { connections.removeAll { $0.legacyProfile == nil }; connections += newValue }
    }
    init() {}
    enum CodingKeys: String, CodingKey { case schemaVersion, connections, profiles, providers, openAISnapshot, pending }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        guard [1, 2, 3].contains(schemaVersion) else { throw ModelProfileFailure.storage }
        if schemaVersion == 3 { connections = try c.decode([ProviderSettings].self, forKey: .connections) }
        else {
            connections = try c.decodeIfPresent([ProviderSettings].self, forKey: .providers) ?? []
            connections += (try c.decodeIfPresent([CodexModelProfile].self, forKey: .profiles) ?? []).map(ProviderSettings.init(profile:))
        }
        guard Set(connections.map(\.id)).count == connections.count else { throw ModelProfileFailure.storage }
        openAISnapshot = try c.decodeIfPresent([CodexConfigEdit].self, forKey: .openAISnapshot)
        // Completed Undo history from older builds is obsolete. Pending writes
        // still decode below so interrupted transactions can be reconciled.
        pending = try c.decodeIfPresent(ModelProfileJournal.self, forKey: .pending)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(3, forKey: .schemaVersion); try c.encode(connections, forKey: .connections)
        try c.encodeIfPresent(openAISnapshot, forKey: .openAISnapshot)
        try c.encodeIfPresent(pending, forKey: .pending)
    }
}

enum ModelProfilePatch {
    static func edits(for profile: CodexModelProfile, snapshot: CodexConfigSnapshot) throws -> [CodexConfigEdit] {
        guard profile.validation.isEmpty else { throw ModelProfileFailure.invalid }
        if profile.kind == .reference, profile.providerID != "openai",
           snapshot.effective["model_providers"][profile.providerID].object == nil,
           !["ollama", "lmstudio", "amazon-bedrock"].contains(profile.providerID) {
            throw ModelProfileFailure.referenceMissing
        }
        let nullable: (String) -> JSONValue = { $0.isEmpty ? .null : .string($0) }
        var edits = [
            CodexConfigEdit(keyPath: "model", value: nullable(profile.model)),
            CodexConfigEdit(keyPath: "model_provider", value: .string(profile.providerID)),
            CodexConfigEdit(keyPath: "model_reasoning_effort", value: nullable(profile.reasoning)),
            CodexConfigEdit(keyPath: "model_catalog_json", value: nullable(profile.catalogPath)),
            CodexConfigEdit(keyPath: "openai_base_url", value: profile.kind == .reference ? profile.referencedOpenAIBaseURL.map(JSONValue.string) ?? .null : .null)
        ]
        try validateRecovery([CodexConfigEdit(keyPath: "openai_base_url", value: snapshot.user["openai_base_url"])])
        if profile.kind == .custom {
            edits.append(CodexConfigEdit(keyPath: "model_context_window", value: profile.contextWindow.map { .number(Double($0)) } ?? .null))
        }
        if profile.authentication == .keychain {
            edits += [CodexConfigEdit(keyPath: "model_supports_reasoning_summaries", value: profile.presetID == nil ? .bool(true) : .null),
                CodexConfigEdit(keyPath: "model_reasoning_summary", value: profile.presetID == nil ? .string("none") : .null),
                CodexConfigEdit(keyPath: "service_tier", value: .null),
                CodexConfigEdit(keyPath: "preferred_auth_method", value: .string("apikey")),
                CodexConfigEdit(keyPath: "forced_login_method", value: .string("api")),
                CodexConfigEdit(keyPath: "web_search", value: .string("disabled"))]
        }
        if profile.kind == .custom {
            let path = "model_providers." + profile.providerID
            if snapshot.value(at: path) == .null {
                edits.append(CodexConfigEdit(keyPath: path, value: profile.provider))
            } else {
                let authenticationKeys = ["auth", "experimental_bearer_token", "requires_openai_auth", "http_headers", "env_http_headers"]
                let existing = snapshot.value(at: path)
                let ownsAuth = existing["auth"]["args"].array?.first?.string == "--provider-credential"
                    && existing["auth"]["args"].array?.count == 2
                    && existing["auth"]["args"].array?.last?.string.flatMap(UUID.init(uuidString:)) != nil
                    && existing["auth"]["command"].string?.hasSuffix("/Contents/MacOS/Veyra") == true
                    && (existing["auth"]["timeout_ms"] == .null || (existing["auth"]["timeout_ms"].integer.map { $0 > 0 && $0 <= 60000 } ?? false))
                    && (existing["auth"]["refresh_interval_ms"] == .null || (existing["auth"]["refresh_interval_ms"].integer.map { $0 >= 0 } ?? false))
                    && Set(existing["auth"].object?.keys.map { $0 } ?? []).isSubset(of: ["command", "args", "timeout_ms", "refresh_interval_ms"])
                guard !authenticationKeys.contains(where: { existing[$0] != .null && !($0 == "auth" && ownsAuth) }) else {
                    throw ModelProfileFailure.changed
                }
                // Preserve unknown provider fields, including authentication handled by Codex.
                for key in (["name", "base_url", "wire_api", "env_key"] + (profile.authentication == .keychain || ownsAuth ? ["auth"] : [])) {
                    edits.append(CodexConfigEdit(keyPath: path + "." + key, value: profile.provider[key]))
                }
            }
        }
        return edits.filter { snapshot.value(at: $0.keyPath) != $0.value }
    }

    /// Both sides of a transaction become persistent recovery data, including on direct OpenAI restores.
    static func validateRecovery(_ edits: [CodexConfigEdit]) throws {
        for edit in edits where edit.keyPath == "openai_base_url" {
            guard edit.value == .null || edit.value.string.map(CodexModelProfile.validServiceURL) == true else {
                throw ModelProfileFailure.unsafeBackup
            }
        }
    }

    static func matches(_ edits: [CodexConfigEdit], snapshot: CodexConfigSnapshot) -> Bool {
        edits.allSatisfy { snapshot.value(at: $0.keyPath) == $0.value }
    }
}

/// Compares executable paths by their canonical form so a symlinked or
/// differently spelled path to the same binary is not reported as a moved app.
enum ExecutablePath {
    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Missing operands cannot be proven equal, so they keep the repair prompt.
    static func matches(_ recorded: String?, _ running: String?) -> Bool {
        guard let recorded, let running else { return false }
        return canonical(recorded) == canonical(running)
    }
}
