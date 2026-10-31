# Repository Guidelines

Veyra is a Swift 6/SwiftUI macOS menu bar app monitoring Codex quotas and local tasks without third-party dependencies.

## Project Structure & Module Organization

- `Veyra/App/`: app entry point, views, observable state, settings, diagnostics, and previews.
- `Veyra/Core/`: models, quota RPC client, read-only SQLite/JSONL readers, process evidence, and panel sizing.
- `VeyraTests/`: XCTest suites for core behavior and sizing.
- `assets/brand/`: source SVG artwork; `Veyra/Resources/` and `Veyra/AppIcon.icns`: generated app assets.
- `scripts/`: build, test, release-app verification, and asset utilities. `Veyra.xcodeproj/` is maintained by hand; `build/` contains ignored outputs.

## Build, Test, and Development Commands

Use Xcode 26/Swift 6 targeting macOS 14. Run from the repository root:

- `./scripts/build.sh`: build the Release app with automatic signing; the team comes from the gitignored `Local.xcconfig`, so a fresh clone must fill one in (or the build fails at signing).
- `./scripts/test.sh`: run the XCTest suite in Debug on macOS, then the isolated app diagnostics, then `scripts/verify_configuration.py`. When the repository sits inside ~/Documents, ~/Desktop, or ~/Downloads, derived data moves to `~/Library/Developer/Xcode/DerivedData/Veyra` because the TCC-protected folders block the test runner from reading the bundle; override with `VEYRA_DERIVED_DATA_PATH`.
- `open build/Build/Products/Release/Veyra.app`: launch the menu bar app.
- `open Veyra.xcodeproj`: develop using the `Veyra` scheme.
- `./scripts/verify_release_app.sh path/to/Veyra.app [--zip build/releases/vX.Y.Z/Veyra.zip]`: verify an exported release app (version, build, bundle ID, universal binary, Developer ID signing, Hardened Runtime, notarization, stapled ticket) before publishing; with `--zip` it also packages the app and prints the SHA-256. Version and build expectations default to the values in `project.pbxproj`.
- Project configuration lives in `Veyra.xcodeproj/project.pbxproj`; change it directly or through the Xcode GUI (General tab for version, display name, and category). Xcode synchronized folders automatically pick up file additions/removals for their default targets, but after adding/removing/renaming shared Core sources you must update the test target's `membershipExceptions` in `project.pbxproj` yourself; `scripts/verify_configuration.py` fails on missing or stale entries.
- `python3 scripts/verify_configuration.py`: read-only check of configuration and packaging invariants (App Sandbox off, app Hardened Runtime on, `LSUIElement` menu-bar mode, no `DEVELOPMENT_TEAM` in `project.pbxproj` so the gitignored `Local.xcconfig` override stays authoritative, hybrid `Info.plist` hygiene, macOS 14 target, Swift 6 strict concurrency, sqlite3 linkage, complete test membership, and the universal Release binary plus merged Info.plist when `--derived-data` is supplied). Update its expectations whenever an invariant changes.

See `docs/development.zh-CN.md` for brand regeneration and preview commands.

## Coding Style & Naming Conventions

Use four-space indentation and same-line opening braces. Use `UpperCamelCase` for types/files and `lowerCamelCase` for methods/properties. Keep UI state on `@MainActor` and respect Swift 6 strict concurrency. Keep parsing and sizing logic in `Core`. No formatter or linter is configured; follow surrounding code.

## Testing Guidelines

Use `XCTestCase`, `*Tests.swift` filenames, and descriptive `test...` methods. Add regression coverage for changed parsing, caching, process detection, or sizing behavior. Use temporary fixtures and fake subprocesses rather than live account data. No numeric coverage threshold is configured.

For UI changes, check the real menu in light/dark modes, reduced transparency, increased contrast, and overflow scrolling. Layout previews alone cannot verify native glass rendering.

## Commit & Pull Request Guidelines

History uses concise imperative subjects with `feat:` or `fix:` prefixes. Keep commits focused. PRs should describe the problem and resulting behavior, link relevant issues, report validation, and include screenshots for UI changes. Commit regenerated assets when their inputs change.

## Security & Configuration

Preserve read-only monitoring: never modify Codex databases or control tasks. Provider credentials are an explicit exception: only user-initiated save, replace, or remove actions may store API Keys in the local macOS Keychain. Never store Key values in JSON, config.toml, environment variables, command arguments, logs, exports, or diagnostics. Respect configurable paths and `CODEX_HOME`; keep diagnostics free of private account or session content.

Model configuration is the explicit write exception: only user-initiated apply/undo actions may update user-level `config.toml` through Codex's version-checked configuration RPC. Keep model profiles, discovered capability catalogs and field-level recovery records in Veyra's own directory; these may contain opaque Keychain references but never Key values. Never copy existing provider secrets or edit Codex authentication files. The --provider-credential mode must run before NSApplication and return only the requested Key to Codex on stdout; it must not initialize UI, monitoring, or updates. Keychain integration tests must use an independent fixture keychain and local mock endpoint. Stable signing is required for real Keychain acceptance; unsigned builds only establish compilation and fixture evidence.

Keep signing overrides local: `DEVELOPMENT_TEAM` belongs only in the gitignored `Local.xcconfig` (optionally included by `Signing.xcconfig`). Never pick a Team in Xcode's Signing panel — it writes `DEVELOPMENT_TEAM` back into `project.pbxproj` and overrides the xcconfig layer. `Veyra/Info.plist` only holds keys Xcode cannot generate (`CFBundleIconFile`, `NSHighResolutionCapable`); standard and `INFOPLIST_KEY_*` keys come from target build settings.

## Automated Sessions

`./scripts/test.sh` probes whether the derived data directory is writable and exits with a clear message if it is not, naming `VEYRA_DERIVED_DATA_PATH` as the override. A file sandbox that confines writes to the workspace cannot use the `~/Library/Developer/Xcode/DerivedData/Veyra` fallback, so pass `VEYRA_DERIVED_DATA_PATH="$PWD/build/TestDerivedData"` in that case.

A file sandbox also breaks the Swift macro plugin server (`swift-plugin-server`), so `ObservationMacros`/`SwiftMacros` expansion fails with `produced malformed response` regardless of the derived data path. Build and test steps need unsandboxed execution; report that requirement instead of treating the failure as a code defect.

Use `/usr/bin/python3 -I -B /Users/zhubowen/Documents/yuzio-ai/veyra/scripts/verify_local.py` with `test`, `previews menu|settings`, or `release-build` for automated verification. Keep environment setup and log redirection inside the entrypoint so its narrow command rules can match. `test` reuses the existing `test.sh`; `release-build` reuses `build.sh`. The entrypoint uses unsigned builds, isolated fixtures, fixed non-TCC derived data, unique logs, and a nonblocking lock. `--dry-run` prints commands without running them.

For intermediate edits, use `test --only-testing VeyraTests/TestClass[/testMethod]`; run a full `test` at final validation. Reuse unchanged successful evidence rather than repeating a full suite. The entrypoint invalidates evidence when source, toolchain, environment, or artifacts change; failures and concurrent invocations never count as passes. `--force` explicitly reruns. A focused test pass does not replace a full-suite pass. Preserve `SKIP` as reuse of prior evidence, not a fresh execution.

Rules are reviewed in `scripts/codex-local-verification.rules` and installed with `scripts/install_verification_rules.py` into trusted project `.codex/rules/local-verification.rules`. Restart Codex after installation. Do not add generic interpreter, shell, or xcodebuild allow rules. Rules trust script content, so review script changes. Real `launch` and read-only `ax-read <PID>` remain separate approval requests; they must not be folded into automatic testing or previews. Keep sandbox settings and existing generic command permissions unchanged. See `docs/development.zh-CN.md` for commands and evidence paths.

## Agent Instructions

For library, framework, SDK, API, CLI, or cloud-service questions, use current Context7 docs: `resolve-library-id`, then `query-docs` with the full question. Skip resolution for supplied exact IDs. Excludes general programming, new scripts, refactoring, business-logic debugging, and code review.

## Vistra static visuals

Vistra delivers static images using the host image tools. The shared Vistra executor, user Hook and rules have been retired. Do not use the former rendering or frame-extraction entry. Existing project build/test commands and historical design artifacts remain unchanged.
