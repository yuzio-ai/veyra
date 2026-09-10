import Foundation

/// Top-level model settings from Codex `config.toml`, read-only.
struct CodexModelConfig: Equatable, Sendable {
    let model: String?
    let provider: String?

    /// ChatGPT quotas and reset credits only exist for the default OpenAI provider.
    var usesCustomProvider: Bool {
        guard let provider else { return false }
        return provider != "openai"
    }

    var customProvider: String? { usesCustomProvider ? provider : nil }

    static func load(home: URL) -> CodexModelConfig? {
        let url = home.appendingPathComponent("config.toml")
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return nil }
        return parse(text)
    }

    private enum Section { case topLevel, activeProfile, other }

    /// Reads top-level keys and, when `profile` names one, the matching
    /// `[profiles.<name>]` table; every other table is ignored. Keys passed
    /// via `--profile` on the command line leave no trace here and stay undetected.
    static func parse(_ text: String) -> CodexModelConfig {
        var model: String?, provider: String?, profile: String?
        var section = Section.topLevel
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            if trimmed.hasPrefix("[") {
                if let name = profileName(trimmed), name == profile {
                    section = .activeProfile
                } else {
                    section = .other
                }
                continue
            }
            guard section != .other else { continue }
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            guard let value = quotedValue(trimmed[trimmed.index(after: equals)...]) else { continue }
            switch key {
            case "model": model = value
            case "model_provider": provider = value
            case "profile" where section == .topLevel: profile = value
            default: break
            }
        }
        return CodexModelConfig(model: model, provider: provider)
    }

    /// Header name for `[profiles.<name>]`; quoted segments are unquoted.
    private static func profileName(_ line: Substring) -> String? {
        guard let close = line.firstIndex(of: "]") else { return nil }
        var name = line[line.index(after: line.startIndex)..<close].trimmingCharacters(in: .whitespaces)
        guard name.hasPrefix("profiles.") else { return nil }
        name = name.dropFirst("profiles.".count).trimmingCharacters(in: .whitespaces)
        if let quote = name.first, quote == "\"" || quote == "'", name.last == quote, name.count > 1 {
            name = String(name.dropFirst().dropLast())
        }
        return name.isEmpty ? nil : name
    }

    /// TOML strings are quoted; anything else is ignored conservatively.
    private static func quotedValue(_ value: Substring) -> String? {
        guard let start = value.firstIndex(where: { $0 == "\"" || $0 == "'" }) else { return nil }
        let quote = value[start]
        let tail = value[value.index(after: start)...]
        guard let end = tail.firstIndex(of: quote) else { return nil }
        let text = String(tail[..<end])
        return text.isEmpty ? nil : text
    }
}
