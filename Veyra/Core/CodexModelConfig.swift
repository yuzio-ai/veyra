import Foundation

/// Top-level model settings from Codex `config.toml`, read-only.
struct CodexModelConfig: Equatable, Sendable {
    let model: String?
    let provider: String?
    let openAIBaseURL: String?

    init(model: String?, provider: String?, openAIBaseURL: String? = nil) {
        self.model = model; self.provider = provider; self.openAIBaseURL = openAIBaseURL
    }

    /// ChatGPT quotas and reset credits only exist for the default OpenAI provider.
    var usesCustomProvider: Bool {
        openAIBaseURL != nil || (provider != nil && provider != "openai")
    }

    var customProvider: String? { usesCustomProvider ? provider ?? "openai" : nil }

    static func load(home: URL) -> CodexModelConfig? {
        let url = home.appendingPathComponent("config.toml")
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return nil }
        return parse(text)
    }

    /// Global defaults only. Modern Codex uses separate CLI profile files;
    /// a legacy `profile` selector is not evidence of the global default.
    static func parse(_ text: String) -> CodexModelConfig {
        var model: String?, provider: String?, openAIBaseURL: String?
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            if trimmed.hasPrefix("[") {
                break
            }
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            guard let value = quotedValue(trimmed[trimmed.index(after: equals)...],
                                          allowEmpty: key == "openai_base_url") else { continue }
            switch key {
            case "model": model = value
            case "model_provider": provider = value
            case "openai_base_url": openAIBaseURL = value
            default: break
            }
        }
        return CodexModelConfig(model: model, provider: provider, openAIBaseURL: openAIBaseURL)
    }

    /// TOML strings are quoted; anything else is ignored conservatively.
    private static func quotedValue(_ value: Substring, allowEmpty: Bool = false) -> String? {
        guard let start = value.firstIndex(where: { $0 == "\"" || $0 == "'" }) else { return nil }
        let quote = value[start]
        let tail = value[value.index(after: start)...]
        guard let end = tail.firstIndex(of: quote) else { return nil }
        let text = String(tail[..<end])
        return text.isEmpty && !allowEmpty ? nil : text
    }
}
