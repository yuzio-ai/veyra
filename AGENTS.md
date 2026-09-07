# Repository Guidelines

Veyra is a Swift 6/SwiftUI macOS menu bar app monitoring Codex quotas and local tasks without third-party dependencies.

## Project Structure & Module Organization

- `Veyra/App/`: app entry point, views, observable state, settings, diagnostics, and previews.
- `Veyra/Core/`: models, quota RPC client, read-only SQLite/JSONL readers, process evidence, and panel sizing.
- `VeyraTests/`: XCTest suites for core behavior and sizing.
- `assets/brand/`: source SVG artwork; `Veyra/Resources/` and `Veyra/AppIcon.icns`: generated app assets.
- `scripts/`: build, test, project generation, and asset utilities. `Veyra.xcodeproj/` is generated; `build/` contains ignored outputs.

## Build, Test, and Development Commands

Use Xcode 26/Swift 6 targeting macOS 14. Run from the repository root:

- `./scripts/build.sh`: build the Release app with local ad-hoc signing.
- `./scripts/test.sh`: run the XCTest suite in Debug on macOS.
- `open build/Build/Products/Release/Veyra.app`: launch the menu bar app.
- `open Veyra.xcodeproj`: develop using the `Veyra` scheme.
- `python3 scripts/generate_project.py`: regenerate project configuration. Xcode synchronized folders automatically pick up file additions/removals for their default targets; regenerate after adding/removing/renaming shared Core sources to update test membership exceptions. Make persistent project configuration and target membership changes in this generator.

See `README.md` for brand regeneration and preview commands.

## Coding Style & Naming Conventions

Use four-space indentation and same-line opening braces. Use `UpperCamelCase` for types/files and `lowerCamelCase` for methods/properties. Keep UI state on `@MainActor` and respect Swift 6 strict concurrency. Keep parsing and sizing logic in `Core`. No formatter or linter is configured; follow surrounding code.

## Testing Guidelines

Use `XCTestCase`, `*Tests.swift` filenames, and descriptive `test...` methods. Add regression coverage for changed parsing, caching, process detection, or sizing behavior. Use temporary fixtures and fake subprocesses rather than live account data. No numeric coverage threshold is configured.

For UI changes, check the real menu in light/dark modes, reduced transparency, increased contrast, and overflow scrolling. Layout previews alone cannot verify native glass rendering.

## Commit & Pull Request Guidelines

History uses concise imperative subjects with `feat:` or `fix:` prefixes. Keep commits focused. PRs should describe the problem and resulting behavior, link relevant issues, report validation, and include screenshots for UI changes. Commit regenerated project/assets when their inputs change.

## Security & Configuration

Preserve read-only monitoring: never modify Codex databases, control tasks, or persist credentials. Respect configurable paths and `CODEX_HOME`; keep diagnostics free of private account or session content.

## Agent Instructions

For library, framework, SDK, API, CLI, or cloud-service questions, use current Context7 docs: `resolve-library-id`, then `query-docs` with the full question. Skip resolution for supplied exact IDs. Excludes general programming, new scripts, refactoring, business-logic debugging, and code review.
