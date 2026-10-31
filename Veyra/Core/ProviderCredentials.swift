import Foundation
import Security
import LocalAuthentication

struct CredentialReference: Codable, Hashable, Sendable {
    let id: UUID
    init(id: UUID = UUID()) { self.id = id }
    var argument: String { id.uuidString.lowercased() }
}

enum CredentialFailure: Error, LocalizedError, Sendable {
    case missing, locked, denied, storage, invalid, inUse
    var errorDescription: String? {
        switch self {
        case .missing: L10n.text("API Key is missing. Enter it again in Settings.")
        case .locked: L10n.text("Unlock the login keychain, then retry in Settings.")
        case .denied: L10n.text("Keychain access was denied. Allow Veyra in Keychain Access and retry.")
        case .storage: L10n.text("Unable to save the API Key in the system keychain.")
        case .invalid: L10n.text("Enter a nonempty API Key without spaces or line breaks.")
        case .inUse: L10n.text("This Key is used by the current configuration or an interrupted change. Switch providers or resolve the configuration first.")
        }
    }
    static func status(_ status: OSStatus) -> Self {
        switch status {
        case errSecItemNotFound: .missing
        case errSecInteractionNotAllowed: .locked
        case errSecAuthFailed, errSecUserCanceled: .denied
        default: .storage
        }
    }
    static func validate(_ key: String) throws {
        guard !key.isEmpty, key.utf8.count <= 16384,
              !key.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) else {
            throw Self.invalid
        }
    }
}

protocol CredentialStore: Sendable {
    func save(_ key: String, reference: CredentialReference) throws
    func read(_ reference: CredentialReference) throws -> String
    func contains(_ reference: CredentialReference) throws -> Bool
    func remove(_ reference: CredentialReference) throws
}

/// File-based login keychain, local only. The signed Veyra executable owns its default ACL.
/// Fixture queries use a different service and explicit independent keychain; never the login keychain.
/// SecKeychain remains necessary for selecting a file keychain, checking its lock state,
/// and fixture ACLs. Data Protection keychains use different storage/access rules;
/// changing this backend requires a separate migration. See docs/development.zh-CN.md.
struct KeychainCredentialStore: CredentialStore {
    let fixtureKeychain: URL?
    init(fixtureKeychain: URL? = nil) { self.fixtureKeychain = fixtureKeychain }
    private var service: String { fixtureKeychain == nil ? "ai.yuzio.veyra.providers" : "ai.yuzio.veyra.providers.fixture" }

    private func query(_ reference: CredentialReference, interactive: Bool = false) throws -> [String: Any] {
        var result: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: reference.argument,
            kSecAttrSynchronizable as String: false]
        if !interactive {
            let context = LAContext(); context.interactionNotAllowed = true
            result[kSecUseAuthenticationContext as String] = context
        }
        var selectedKeychain: SecKeychain?
        if let fixtureKeychain {
            guard fixtureKeychain.lastPathComponent == "veyra-fixture.keychain-db" else { throw CredentialFailure.storage }
            var keychain: SecKeychain?
            let status = SecKeychainOpen(fixtureKeychain.path, &keychain)
            guard status == errSecSuccess, let keychain else { throw CredentialFailure.status(status) }
            selectedKeychain = keychain
            result[kSecUseKeychain as String] = keychain
            result[kSecMatchSearchList as String] = [keychain]
        } else {
            guard SecKeychainCopyDefault(&selectedKeychain) == errSecSuccess else { throw CredentialFailure.storage }
        }
        if !interactive, let selectedKeychain {
            var status: SecKeychainStatus = 0
            guard SecKeychainGetStatus(selectedKeychain, &status) == errSecSuccess else { throw CredentialFailure.storage }
            guard status & UInt32(kSecUnlockStateStatus) != 0 else { throw CredentialFailure.locked }
        }
        return result
    }
    func save(_ key: String, reference: CredentialReference) throws { try insert(key, reference: reference, denyFixtureAccess: false) }
    func saveDeniedFixture(_ key: String, reference: CredentialReference) throws {
        guard fixtureKeychain != nil else { throw CredentialFailure.invalid }
        try insert(key, reference: reference, denyFixtureAccess: true)
    }
    private func insert(_ key: String, reference: CredentialReference, denyFixtureAccess: Bool) throws {
        try CredentialFailure.validate(key)
        var attributes = try query(reference, interactive: true)
        attributes.removeValue(forKey: kSecMatchSearchList as String)
        attributes[kSecValueData as String] = Data(key.utf8)
        attributes[kSecAttrLabel as String] = "Veyra provider API Key"
        if denyFixtureAccess {
            var access: SecAccess?
            // Empty means no trusted readers; nil would permit all applications.
            guard SecAccessCreate("Veyra denied fixture" as CFString, [] as CFArray, &access) == errSecSuccess,
                  let access else { throw CredentialFailure.storage }
            attributes[kSecAttrAccess as String] = access
        }
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw CredentialFailure.status(status) }
    }
    func read(_ reference: CredentialReference) throws -> String {
        var attributes = try query(reference)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &value)
        if status == errSecInteractionNotAllowed {
            _ = try query(reference) // A still-unlocked keychain means access was denied.
            throw CredentialFailure.denied
        }
        guard status == errSecSuccess else { throw CredentialFailure.status(status) }
        guard let data = value as? Data, let key = String(data: data, encoding: .utf8) else { throw CredentialFailure.storage }
        try CredentialFailure.validate(key)
        return key
    }
    func contains(_ reference: CredentialReference) throws -> Bool {
        var attributes = try query(reference)
        attributes[kSecReturnAttributes as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(attributes as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw CredentialFailure.status(status) }
        return true
    }
    func remove(_ reference: CredentialReference) throws {
        let status = SecItemDelete(try query(reference, interactive: true) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialFailure.status(status) }
    }
}

/// Checked before NSApplication is created. This path never starts application services.
enum ProviderCredentialCommand {
    static func run(_ arguments: [String]) -> Int32? {
        guard let mode = arguments.first, ["--provider-credential", "--provider-credential-fixture", "--create-credential-fixture", "--create-denied-credential-fixture", "--delete-credential-fixture", "--lock-credential-fixture", "--create-model-catalog-fixture"].contains(mode) else { return nil }
        var catalogFixtureStage = 0
        do {
            if ["--provider-credential", "--provider-credential-fixture"].contains(mode) {
                // This process exits before NSApplication. The process-wide legacy flag
                // cannot affect the GUI app, and also covers file-Keychain ACL prompts.
                guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { throw CredentialFailure.denied }
            }
            if mode == "--create-model-catalog-fixture", arguments.count == 3 {
                let directory = URL(fileURLWithPath: arguments[2]).resolvingSymlinksInPath()
                guard directory.lastPathComponent == "model-catalog-fixture",
                      ["/private/tmp/veyra-credential-", "/tmp/veyra-credential-"].contains(where: directory.path.hasPrefix),
                      let preset = ProviderPreset.find(arguments[1]) else { throw CredentialFailure.invalid }
                catalogFixtureStage = 1
                let input = try Data(contentsOf: directory.appendingPathComponent("models-response.json"))
                catalogFixtureStage = 2
                let models = try URLSessionProviderModelClient.parse(input, preset: preset)
                guard let first = models.first else { throw ModelDiscoveryFailure.unavailable }
                var settings = ProviderSettings(preset: preset); settings.model = first.id
                let data = try JSONEncoder().encode(ProviderRuntimeCatalog.build(models: models, preset: preset, settings: settings))
                catalogFixtureStage = 3
                try data.write(to: directory.appendingPathComponent(preset.id + ".json"), options: [.atomic])
                return 0
            }
            if ["--create-credential-fixture", "--create-denied-credential-fixture"].contains(mode), arguments.count == 2 {
                let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
                let url = directory.appendingPathComponent("veyra-fixture.keychain-db")
                guard !FileManager.default.fileExists(atPath: url.path) else { throw CredentialFailure.storage }
                var keychain: SecKeychain?
                let password = UUID().uuidString
                let status = password.withCString { SecKeychainCreate(url.path, UInt32(password.utf8.count), $0, false, nil, &keychain) }
                guard status == errSecSuccess, let keychain else { throw CredentialFailure.status(status) }
                // A dedicated fixture file is addressed explicitly, without changing the user's search list.
                let reference = CredentialReference()
                let store = KeychainCredentialStore(fixtureKeychain: url)
                if mode == "--create-denied-credential-fixture" { try store.saveDeniedFixture("veyra-fixture-only-key", reference: reference) }
                else { try store.save("veyra-fixture-only-key", reference: reference) }
                try JSONEncoder().encode(reference).write(to: directory.appendingPathComponent("credential-reference.json"))
                withExtendedLifetime(keychain) {}
                return 0
            }
            if ["--delete-credential-fixture", "--lock-credential-fixture"].contains(mode), arguments.count == 2 {
                let url = URL(fileURLWithPath: arguments[1])
                guard url.lastPathComponent == "veyra-fixture.keychain-db" else { throw CredentialFailure.invalid }
                var keychain: SecKeychain?
                let status = SecKeychainOpen(url.path, &keychain)
                guard status == errSecSuccess, let keychain else { throw CredentialFailure.status(status) }
                let result = mode == "--lock-credential-fixture" ? SecKeychainLock(keychain) : SecKeychainDelete(keychain)
                guard result == errSecSuccess else { throw CredentialFailure.storage }
                return 0
            }
            guard (mode == "--provider-credential" && arguments.count == 2) || (mode == "--provider-credential-fixture" && arguments.count == 3),
                  let id = UUID(uuidString: arguments[1]) else { throw CredentialFailure.invalid }
            let store = KeychainCredentialStore(fixtureKeychain: arguments.count == 3 ? URL(fileURLWithPath: arguments[2]) : nil)
            let key = try store.read(CredentialReference(id: id))
            try FileHandle.standardOutput.write(contentsOf: Data((key + "\n").utf8))
            return 0
        } catch {
            if mode == "--create-model-catalog-fixture" {
                try? FileHandle.standardError.write(contentsOf: Data("Veyra: isolated catalog fixture failed at stage \(catalogFixtureStage).\n".utf8))
                return 1
            }
            // No OS/backend error text, arguments, key or configuration content may reach stderr.
            try? FileHandle.standardError.write(contentsOf: Data("Veyra: credential unavailable; unlock Keychain or update the Key in Settings.\n".utf8))
            return 1
        }
    }
}

/// In-memory fixtures only; never selected by a production store.
final class MemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CredentialReference: String] = [:]
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
    func save(_ key: String, reference: CredentialReference) throws {
        try CredentialFailure.validate(key)
        lock.lock(); defer { lock.unlock() }; values[reference] = key
    }
    func read(_ reference: CredentialReference) throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard let value = values[reference] else { throw CredentialFailure.missing }; return value
    }
    func contains(_ reference: CredentialReference) throws -> Bool { lock.lock(); defer { lock.unlock() }; return values[reference] != nil }
    func remove(_ reference: CredentialReference) throws { lock.lock(); defer { lock.unlock() }; values[reference] = nil }
}
