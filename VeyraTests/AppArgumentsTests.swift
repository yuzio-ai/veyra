import XCTest

final class AppArgumentsTests: XCTestCase {
    func testNormalLaunchAndFoundationOptionsRemainAvailable() {
        XCTAssertTrue(AppArguments.accepts([]))
        XCTAssertTrue(AppArguments.accepts(["-psn_0_12345"]))
        XCTAssertTrue(AppArguments.accepts(["--diagnose", "--network", "-codexHome", "/tmp/fixture",
                                         "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]))
        XCTAssertTrue(AppArguments.accepts(["--preview-menu", "multiple", "--show-menu",
                                         "--exercise-menu-to", "/tmp/fixture", "--preview-lease", "fixture-token"]))
    }

    func testUnknownCommandsAndIncompleteOptionsFailBeforeAppStartup() {
        for arguments in [["--unknown-command", "PRIVATE_VALUE"], ["--render-previews"],
                          ["--preview-lease", "--diagnose"], ["--preview-menu", ""],
                          ["-codexHome"], ["unexpected-value"]] {
            XCTAssertFalse(AppArguments.accepts(arguments))
        }
    }
    func testRemovedUnknownAndDuplicatePreviewValuesAreRejected() {
        for arguments in [
            ["--preview-menu", "custom-model"], ["--preview-menu", "dsh-only"],
            ["--preview-menu", "dsh-idle"], ["--preview-menu", "dsh-unknown"], ["--preview-menu", "dsh-error"],
            ["--render-previews", "/tmp/fixture", "--preview-dsh-only"], ["--preview-menu", "unknown-scenario"],
            ["--preview-menu", "single", "--preview-appearance", "purple"],
            ["--preview-menu", "single", "--preview-menu", "multiple"]
        ] {
            XCTAssertFalse(AppArguments.accepts(arguments), String(describing: arguments))
        }
    }

    func testPreviewModifiersRequireTheirFixtureMode() {
        for arguments in [
            ["--preview-settings-only"], ["--preview-dsh-only"], ["--exercise-settings"],
            ["--exercise-settings-only"], ["--preview-appearance", "dark"],
            ["--preview-reduce-transparency"], ["--exercise-menu-to", "/tmp/fixture"],
            ["--exit-after-menu-checks"], ["--network"],
            ["--diagnose", "--preview-menu", "single"],
            ["--render-previews", "/tmp/fixture", "--preview-menu", "single"]
        ] {
            XCTAssertFalse(AppArguments.accepts(arguments), String(describing: arguments))
        }
    }

    func testValidPreviewModesAndBenchmarkRemainSupported() {
        for arguments in [
            ["--render-previews", "/tmp/fixture", "--exercise-settings"],
            ["--render-previews", "/tmp/fixture", "--preview-settings-only"],
            ["--preview-menu", "tasks-only", "--preview-appearance", "dark-increased", "--show-menu",
             "--exercise-menu-to", "/tmp/fixture", "--exit-after-menu-checks"],
            ["--preview-focus-host", "/tmp/fixture", "--preview-lease", UUID().uuidString],
            ["--energy-benchmark", "--diagnose", "--network"],
            ["--energy-benchmark", "--show-panel"], ["--capture-menu-to", "/tmp/fixture/menu.png"]
        ] {
            XCTAssertTrue(AppArguments.accepts(arguments), String(describing: arguments))
        }
    }

}
