import Foundation

/// Bundled brand mark for a provider identity.
///
/// Provider names come from configuration, so resolution matches the built-in
/// preset names and their common aliases instead of trusting one spelling.
enum ProviderMark: String, CaseIterable, Sendable {
    case openAI
    case deepSeek
    case kimi
    case glm
    case miniMax
    case mimo

    var assetName: String {
        switch self {
        case .openAI: "OpenAIProvider"
        case .deepSeek: "DeepSeekProvider"
        case .kimi: "KimiProvider"
        case .glm: "GLMProvider"
        case .miniMax: "MiniMaxProvider"
        case .mimo: "MiMoProvider"
        }
    }

    /// Multi-color artwork keeps its own colors; single-color artwork follows the
    /// system appearance as a template image.
    var isTemplate: Bool {
        switch self {
        case .deepSeek, .miniMax, .mimo: false
        case .openAI, .kimi, .glm: true
        }
    }

    static func resolve(_ identity: CodexProviderIdentity) -> ProviderMark? {
        identity.isOfficial ? .openAI : resolve(providerName: identity.name)
    }

    static func resolve(providerName: String) -> ProviderMark? {
        let key = providerName.lowercased().filter { $0.isLetter || $0.isNumber }
        switch key {
        case "deepseek": return .deepSeek
        case "kimi", "moonshot", "moonshotai": return .kimi
        case "glm", "zai", "zhipu", "zhipuai", "bigmodel", "chatglm": return .glm
        case "minimax", "minimaxai", "hailuo", "hailuoai": return .miniMax
        case "mimo", "xiaomi", "xiaomimimo": return .mimo
        default: return nil
        }
    }
}
