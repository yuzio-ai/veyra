import Foundation

struct ProviderPreset: Identifiable, Sendable {
    let id: String
    let name: String
    let baseURL: String
    let source: String
    let uuid: UUID
    static let all: [Self] = [
        .init(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com", source: "https://api-docs.deepseek.com/quick_start/agent_integrations/codex/", uuid: UUID(uuidString: "62141F01-A521-4ECC-BF32-000000000001")!),
        .init(id: "kimi", name: "Kimi", baseURL: "https://api.moonshot.cn/v1", source: "https://platform.kimi.com/docs/guide/codex-kimi", uuid: UUID(uuidString: "62141F01-A521-4ECC-BF32-000000000002")!),
        .init(id: "glm", name: "GLM", baseURL: "https://open.bigmodel.cn/api/v1", source: "https://docs.bigmodel.cn/cn/guide/develop/responses/introduction", uuid: UUID(uuidString: "62141F01-A521-4ECC-BF32-000000000003")!),
        .init(id: "minimax", name: "MiniMax", baseURL: "https://api.minimax.cn/v1", source: "https://platform.minimax.cn/docs/m-plan/codex", uuid: UUID(uuidString: "62141F01-A521-4ECC-BF32-000000000004")!),
        .init(id: "mimo", name: "MiMo", baseURL: "https://api.xiaomimimo.com/v1", source: "https://mimo.mi.com/docs/en-US/tokenplan/integration/codex-configuration", uuid: UUID(uuidString: "62141F01-A521-4ECC-BF32-000000000005")!)
    ]
    static func find(_ id: String) -> Self? { all.first { $0.id == id } }
}

enum ProviderOrigin: String, Codable, Sendable { case builtin, custom }
enum ProviderConfigurationStatus: Sendable { case unconfigured, configured, invalid }
enum ProviderApplyStatus: Equatable, Sendable { case notApplied, applied, needsRepair, failed }
enum ProviderEditStatus: Equatable, Sendable { case clean, modified, saving, failed }
typealias ProviderDescriptor = ProviderSettings

struct ProviderSettings: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var model: String
    var baseURL: String
    var reasoning: String
    var credential: CredentialReference?
    var retiredCredentials: [CredentialReference]?
    var contextWindowOverride: Int?
    // Optional additions decode existing schema 1/2 without changing identity or references.
    var name: String?
    var symbol: String?
    var authentication: ModelProfileAuthentication?
    var wireAPI: String?
    var legacyProfile: CodexModelProfile?
    var connectivity: ProviderConnectivityResult?

    init(preset: ProviderPreset) {
        id = preset.id; model = ""; baseURL = preset.baseURL; reasoning = ""
    }
    init(name: String) {
        id = UUID().uuidString.lowercased(); self.name = name
        model = ""; baseURL = ""; reasoning = ""; authentication = .keychain
    }
    init(profile: CodexModelProfile) {
        id = "legacy:" + profile.id.uuidString.lowercased(); name = profile.name
        model = profile.model; baseURL = profile.baseURL; reasoning = profile.reasoning
        credential = profile.credentialReference; authentication = profile.authentication
        contextWindowOverride = profile.contextWindow; legacyProfile = profile
    }
    var origin: ProviderOrigin { id == "openai" || ProviderPreset.find(id) != nil ? .builtin : .custom }
    var displayName: String { name ?? ProviderPreset.find(id)?.name ?? legacyProfile?.name ?? id }
    var authMode: ModelProfileAuthentication { authentication ?? .keychain }
    var protocolName: String { wireAPI ?? "responses" }
    var codexProviderID: String {
        if let legacyProfile { return legacyProfile.providerID }
        return ProviderPreset.find(id).map { "veyra_preset_" + $0.id }
            ?? "veyra_" + id.replacingOccurrences(of: "-", with: "")
    }
    var isManagedEndpoint: Bool { legacyProfile == nil || legacyProfile?.kind == .custom }
    var source: String? { ProviderPreset.find(id)?.source }
    var legacyValue: CodexModelProfile? {
        guard var value = legacyProfile else { return nil }
        value.name = displayName; value.model = model; value.baseURL = baseURL
        value.reasoning = reasoning; value.authentication = authMode
        value.credentialReference = credential; value.contextWindow = contextWindowOverride
        return value
    }
    var validation: [String: String] {
        var errors: [String: String] = [:]
        if displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors["name"] = L10n.text("Enter a provider name.") }
        if !model.isEmpty && !DiscoveredModel.validToken(model) { errors["model"] = L10n.text("Enter a valid model ID.") }
        if isManagedEndpoint && !Self.validEndpoint(baseURL) {
            errors["baseURL"] = L10n.text("Use HTTPS, or HTTP on localhost, without credentials, query, or fragment.")
        }
        if !reasoning.isEmpty && !DiscoveredModel.validToken(reasoning) { errors["reasoning"] = L10n.text("Choose a supported reasoning effort.") }
        if let contextWindowOverride, contextWindowOverride <= 0 { errors["context"] = L10n.text("Enter a positive context window.") }
        return errors
    }
    static func validEndpoint(_ address: String) -> Bool {
        guard CodexModelProfile.validServiceURL(address), let parts = URLComponents(string: address) else { return false }
        if parts.scheme?.lowercased() == "https" { return true }
        let host = parts.host?.lowercased() ?? ""
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        let loopbackV4 = octets.count == 4 && octets.first == "127" && octets.allSatisfy { Int($0).map { (0...255).contains($0) } == true }
        return host == "localhost" || host == "::1" || host == "[::1]" || loopbackV4
    }
    func resolvedReasoning(using metadata: DiscoveredModel?) -> String {
        if !reasoning.isEmpty { return reasoning }
        return metadata?.id == model ? metadata?.defaultReasoning ?? "" : ""
    }
    func resolvedContextWindow(using metadata: DiscoveredModel?) -> Int? {
        contextWindowOverride ?? (metadata?.id == model ? metadata?.contextWindow : nil)
    }
    func profile(helper: URL, catalogPath: String = "", discoveredModel: DiscoveredModel? = nil) throws -> CodexModelProfile {
        guard validation.isEmpty, protocolName == "responses" else { throw ModelProfileFailure.invalid }
        if var value = legacyValue {
            if authMode == .keychain { value.helperPath = helper.path }
            guard value.validation.isEmpty else { throw ModelProfileFailure.invalid }
            return value
        }
        guard DiscoveredModel.validToken(model), authMode != .environment,
              authMode != .keychain || credential != nil else { throw ModelProfileFailure.invalid }
        let uuid = ProviderPreset.find(id)?.uuid ?? UUID(uuidString: id)
        guard let uuid else { throw ModelProfileFailure.invalid }
        var value = CodexModelProfile(id: uuid, name: displayName, kind: .custom, model: model,
            baseURL: baseURL, reasoning: resolvedReasoning(using: discoveredModel), authentication: authMode)
        value.providerName = displayName; value.presetID = ProviderPreset.find(id)?.id
        value.credentialReference = credential; value.helperPath = helper.path; value.catalogPath = catalogPath
        value.contextWindow = resolvedContextWindow(using: discoveredModel)
        return value
    }
}

enum ProviderCredentialCapability {
    /// Fail closed for wrappers/older native executables. Runtime integration is separately tested.
    static func supported(executable: URL?) -> Bool {
        guard let executable, let data = try? Data(contentsOf: executable.resolvingSymlinksInPath(), options: .mappedIfSafe) else { return false }
        return ["ModelProviderAuthInfo", "refresh_interval_ms", "external_bearer"].allSatisfy { data.range(of: Data($0.utf8)) != nil }
    }
}
