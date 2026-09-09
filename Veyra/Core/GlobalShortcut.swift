import Foundation
import Observation

struct ShortcutModifiers: OptionSet, Codable, Equatable, Sendable {
    let rawValue: UInt32
    static let control = Self(rawValue: 1 << 0)
    static let option = Self(rawValue: 1 << 1)
    static let command = Self(rawValue: 1 << 2)
    static let shift = Self(rawValue: 1 << 3)
    static let supported: Self = [.control, .option, .command, .shift]
}

struct GlobalShortcut: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: ShortcutModifiers
    static let standard = Self(keyCode: 9, modifiers: [.control, .option])

    var isValid: Bool {
        keyCode <= 127 && !(54...63).contains(keyCode)
            && !modifiers.intersection([.control, .option, .command]).isEmpty
            && modifiers.subtracting(.supported).isEmpty
    }
}

struct ShortcutPreferences: Codable, Equatable {
    var enabled = true
    var shortcut = GlobalShortcut.standard
}

enum HotKeyEvent { case pressed, released }

struct HotKeyFailure: Error, Equatable {
    let status: Int32
    var message: String {
        if status == -9878 { return L10n.text("This shortcut is already in use. Choose another combination.") }
        return L10n.text("Unable to register shortcut (error \(status)). Choose another combination or try again.")
    }
}

@MainActor
protocol HotKeyRegistering: AnyObject {
    func register(_ shortcut: GlobalShortcut, handler: @escaping @MainActor (HotKeyEvent) -> Void) throws -> Int
    func unregister(_ token: Int)
}

/// Preferences are committed only after registration succeeds. Tests inject a registrar
/// and an isolated defaults suite; no account data or real global hotkeys are needed.
@MainActor @Observable
final class ShortcutStore {
    static let preferencesKey = "globalShortcut.preferences"
    private(set) var preferences: ShortcutPreferences
    private(set) var isRecording = false
    private(set) var errorMessage: String?
    private(set) var isRegistered = false
    @ObservationIgnored var onTrigger: () -> Void = {}
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let registrar: any HotKeyRegistering
    @ObservationIgnored private var token: Int?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var keyIsDown = false
    @ObservationIgnored private var started = false

    init(registrar: any HotKeyRegistering, defaults: UserDefaults? = nil) {
        self.registrar = registrar
        self.defaults = defaults
        if let data = defaults?.data(forKey: Self.preferencesKey),
           let saved = try? JSONDecoder().decode(ShortcutPreferences.self, from: data), saved.shortcut.isValid {
            preferences = saved
        } else {
            preferences = ShortcutPreferences()
        }
    }

    func start() {
        guard !started else { return }
        started = true
        restoreRegistration()
    }

    func stop() {
        started = false
        isRecording = false
        releaseRegistration()
    }

    func setEnabled(_ enabled: Bool) {
        cancelRecording()
        apply(ShortcutPreferences(enabled: enabled, shortcut: preferences.shortcut))
    }

    func restoreDefault() {
        cancelRecording()
        apply(ShortcutPreferences(enabled: preferences.enabled, shortcut: .standard))
    }

    func beginRecording() {
        guard !isRecording else { return }
        errorMessage = nil
        isRecording = true
        releaseRegistration()
    }

    func cancelRecording() {
        guard isRecording else { return }
        isRecording = false
        errorMessage = nil
        restoreRegistration()
    }

    func record(_ shortcut: GlobalShortcut) {
        guard isRecording else { return }
        guard shortcut.isValid else {
            errorMessage = L10n.text("Include Control, Option, or Command with a key.")
            return
        }
        isRecording = false
        apply(ShortcutPreferences(enabled: preferences.enabled, shortcut: shortcut))
    }

    private func apply(_ candidate: ShortcutPreferences) {
        errorMessage = nil
        if candidate == preferences, token != nil { return }
        do {
            // The old token remains registered until the candidate is accepted.
            if started && candidate.enabled {
                try register(candidate.shortcut)
            } else {
                releaseRegistration()
            }
            preferences = candidate
            if let data = try? JSONEncoder().encode(candidate) { defaults?.set(data, forKey: Self.preferencesKey) }
        } catch {
            errorMessage = failureMessage(error)
            if token == nil { restoreRegistration(preservingError: true) }
        }
    }

    private func register(_ shortcut: GlobalShortcut) throws {
        let nextGeneration = generation + 1
        let nextToken = try registrar.register(shortcut) { [weak self] event in
            guard let self, self.generation == nextGeneration, self.isRegistered,
                  self.started, !self.isRecording else { return }
            switch event {
            case .pressed:
                guard !self.keyIsDown else { return }
                self.keyIsDown = true
                self.onTrigger()
            case .released: self.keyIsDown = false
            }
        }
        if let token { registrar.unregister(token) }
        token = nextToken
        generation = nextGeneration
        keyIsDown = false
        isRegistered = true
    }

    private func releaseRegistration() {
        if let token { registrar.unregister(token) }
        token = nil
        generation += 1
        keyIsDown = false
        isRegistered = false
    }

    private func restoreRegistration(preservingError: Bool = false) {
        guard started, preferences.enabled, !isRecording, token == nil else { return }
        do {
            try register(preferences.shortcut)
            if !preservingError { errorMessage = nil }
        } catch {
            let failure = failureMessage(error)
            errorMessage = preservingError ? [errorMessage, failure].compactMap { $0 }.joined(separator: " ") : failure
        }
    }

    private func failureMessage(_ error: Error) -> String {
        (error as? HotKeyFailure)?.message ?? L10n.text("Unable to register shortcut. Try another combination.")
    }
}
