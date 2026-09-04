# Veyra

**English** · [简体中文](README.zh-CN.md)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/brand/veyra-logo-preview-dark.png">
  <img src="assets/brand/veyra-logo-preview.png" alt="Veyra" width="360">
</picture>

Veyra is a native Swift 6 and SwiftUI menu bar app for monitoring Codex quotas and local tasks. It shows quota windows and reset times alongside active tasks, models, elapsed time, and token usage without getting in the way of your work.

## Requirements

- macOS 14 or later.
- Codex Desktop or the Codex CLI installed and signed in.
- The local `codex` executable is only required for manual online quota calibration. No API key is needed.

## Install

Download the latest archive from [GitHub Releases](https://github.com/yuzio-ai/veyra/releases), unzip it, and move `Veyra.app` to the Applications folder. Launch Veyra from Applications; it appears only in the menu bar and does not add a Dock icon.

## Use

Click the Veyra menu bar icon to inspect active task families, task status, elapsed time, token totals, and the latest local quota snapshots. Use the quota refresh button when you want to calibrate those snapshots against the signed-in Codex account. If automatic Codex discovery does not match your installation, set the executable or data directory in Veyra settings.

Veyra monitors existing local data in read-only mode. It does not create, resume, or control tasks, trigger model requests, copy credentials, or modify Codex databases and session files.

## Documentation

Detailed documentation is currently available in Chinese:

- [User guide](docs/user-guide.zh-CN.md)
- [Data, privacy, and compatibility](docs/data-and-privacy.zh-CN.md)
- [Development and manual release](docs/development.zh-CN.md)
