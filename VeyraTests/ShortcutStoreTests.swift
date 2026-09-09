import Foundation
import XCTest

@MainActor
private final class FakeHotKeyRegistrar: HotKeyRegistering {
    var registrations: [Int: GlobalShortcut] = [:]
    var handlers: [Int: @MainActor (HotKeyEvent) -> Void] = [:]
    var rejected: Set<UInt32> = []
    var nextID = 0
    var activeHandler: (@MainActor (HotKeyEvent) -> Void)? { handlers[registrations.keys.max() ?? 0] }

    func register(_ shortcut: GlobalShortcut, handler: @escaping @MainActor (HotKeyEvent) -> Void) throws -> Int {
        if rejected.contains(shortcut.keyCode) { throw HotKeyFailure(status: -9878) }
        nextID += 1
        registrations[nextID] = shortcut
        handlers[nextID] = handler
        return nextID
    }

    func unregister(_ token: Int) { registrations[token] = nil }
}

@MainActor
final class ShortcutStoreTests: XCTestCase {
    private let alternate = GlobalShortcut(keyCode: 40, modifiers: [.command, .shift])

    private func defaults() -> UserDefaults {
        let suite = "veyra-shortcut-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testStartsOnceWithDefaultAndStopsCleanly() {
        let registrar = FakeHotKeyRegistrar(), store = ShortcutStore(registrar: FakeHotKeyRegistrar())
        XCTAssertEqual(store.preferences, ShortcutPreferences())
        let active = ShortcutStore(registrar: registrar)
        XCTAssertTrue(registrar.registrations.isEmpty)
        active.start(); active.start()
        XCTAssertEqual(Array(registrar.registrations.values), [.standard])
        active.stop(); active.stop()
        XCTAssertTrue(registrar.registrations.isEmpty)
        XCTAssertFalse(active.isRegistered)
    }

    func testRecordingSavesAndReloadsDisabledPreference() {
        let defaults = defaults(), registrar = FakeHotKeyRegistrar()
        let store = ShortcutStore(registrar: registrar, defaults: defaults)
        store.start()
        store.beginRecording()
        XCTAssertTrue(registrar.registrations.isEmpty)
        store.record(alternate)
        XCTAssertEqual(Array(registrar.registrations.values), [alternate])
        store.setEnabled(false)
        XCTAssertTrue(registrar.registrations.isEmpty)
        let restarted = ShortcutStore(registrar: FakeHotKeyRegistrar(), defaults: defaults)
        restarted.start()
        XCTAssertEqual(restarted.preferences, ShortcutPreferences(enabled: false, shortcut: alternate))
        XCTAssertFalse(restarted.isRegistered)
        restarted.setEnabled(true)
        XCTAssertTrue(restarted.isRegistered)
        XCTAssertEqual(restarted.preferences.shortcut, alternate)
    }

    func testConflictingRecordedShortcutRestoresOldRegistrationAndPersistence() {
        let defaults = defaults(), registrar = FakeHotKeyRegistrar()
        let store = ShortcutStore(registrar: registrar, defaults: defaults)
        store.start()
        store.beginRecording(); store.record(alternate)
        let saved = defaults.data(forKey: ShortcutStore.preferencesKey)
        registrar.rejected = [9]
        store.beginRecording(); store.record(.standard)
        XCTAssertEqual(store.preferences.shortcut, alternate)
        XCTAssertEqual(Array(registrar.registrations.values), [alternate])
        XCTAssertEqual(defaults.data(forKey: ShortcutStore.preferencesKey), saved)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertFalse(store.isRecording)
    }

    func testRestoreDefaultFailureDoesNotReleaseWorkingShortcut() {
        let registrar = FakeHotKeyRegistrar(), defaults = defaults()
        let store = ShortcutStore(registrar: registrar, defaults: defaults)
        store.start(); store.beginRecording(); store.record(alternate)
        let token = registrar.registrations.keys.first
        registrar.rejected = [9]
        store.restoreDefault()
        XCTAssertEqual(registrar.registrations.keys.first, token)
        XCTAssertEqual(store.preferences.shortcut, alternate)
        XCTAssertNotNil(store.errorMessage)
        registrar.rejected = []
        store.restoreDefault()
        XCTAssertEqual(Array(registrar.registrations.values), [.standard])
        XCTAssertNil(store.errorMessage)
    }

    func testStartupConflictKeepsSavedChoiceAndAllowsRetry() throws {
        let registrar = FakeHotKeyRegistrar(), defaults = defaults()
        defaults.set(try JSONEncoder().encode(ShortcutPreferences(shortcut: alternate)), forKey: ShortcutStore.preferencesKey)
        registrar.rejected = [alternate.keyCode]
        let store = ShortcutStore(registrar: registrar, defaults: defaults)
        store.start()
        XCTAssertTrue(store.preferences.enabled)
        XCTAssertEqual(store.preferences.shortcut, alternate)
        XCTAssertFalse(store.isRegistered)
        XCTAssertNotNil(store.errorMessage)
        registrar.rejected = []
        store.setEnabled(true)
        XCTAssertTrue(store.isRegistered)
        XCTAssertNil(store.errorMessage)
    }

    func testCancelAndInvalidRecordingPreserveShortcut() {
        let registrar = FakeHotKeyRegistrar(), store = ShortcutStore(registrar: FakeHotKeyRegistrar())
        store.beginRecording()
        store.record(GlobalShortcut(keyCode: 9, modifiers: [.shift]))
        XCTAssertTrue(store.isRecording)
        XCTAssertNotNil(store.errorMessage)
        store.cancelRecording()
        XCTAssertEqual(store.preferences.shortcut, .standard)
        XCTAssertNil(store.errorMessage)
        let active = ShortcutStore(registrar: registrar)
        active.start(); active.beginRecording(); active.beginRecording()
        active.cancelRecording(); active.cancelRecording()
        XCTAssertEqual(Array(registrar.registrations.values), [.standard])
        active.beginRecording(); active.stop()
        XCTAssertFalse(active.isRecording)
        XCTAssertTrue(registrar.registrations.isEmpty)
    }

    func testRepeatAndStaleCallbacksCannotTogglePanel() {
        let registrar = FakeHotKeyRegistrar(), store = ShortcutStore(registrar: FakeHotKeyRegistrar())
        var toggles = 0
        let active = ShortcutStore(registrar: registrar)
        active.onTrigger = { toggles += 1 }
        active.start()
        let original = registrar.activeHandler!
        original(.pressed); original(.pressed); original(.pressed)
        XCTAssertEqual(toggles, 1)
        original(.released); original(.pressed)
        XCTAssertEqual(toggles, 2)
        active.beginRecording()
        original(.released); original(.pressed)
        XCTAssertEqual(toggles, 2)
        active.cancelRecording()
        original(.released); original(.pressed)
        XCTAssertEqual(toggles, 2)
        registrar.activeHandler?(.pressed)
        XCTAssertEqual(toggles, 3)
        active.stop()
        registrar.activeHandler?(.pressed)
        XCTAssertEqual(toggles, 3)
        XCTAssertFalse(store.isRegistered)
    }

    func testValidationRejectsModifierKeysAndUnknownModifierBits() {
        XCTAssertTrue(GlobalShortcut.standard.isValid)
        XCTAssertTrue(alternate.isValid)
        for key in UInt32(54)...63 { XCTAssertFalse(GlobalShortcut(keyCode: key, modifiers: [.command]).isValid) }
        XCTAssertFalse(GlobalShortcut(keyCode: 200, modifiers: [.control]).isValid)
        XCTAssertFalse(GlobalShortcut(keyCode: 9, modifiers: []).isValid)
        XCTAssertFalse(GlobalShortcut(keyCode: 9, modifiers: [.shift]).isValid)
        XCTAssertFalse(GlobalShortcut(keyCode: 9, modifiers: ShortcutModifiers(rawValue: 17)).isValid)
    }

    func testMalformedSavedPreferencesUseDefaultWithoutRegistering() {
        let defaults = defaults(), registrar = FakeHotKeyRegistrar()
        defaults.set(Data("broken".utf8), forKey: ShortcutStore.preferencesKey)
        let store = ShortcutStore(registrar: registrar, defaults: defaults)
        XCTAssertEqual(store.preferences, ShortcutPreferences())
        XCTAssertTrue(registrar.registrations.isEmpty)
    }
}
