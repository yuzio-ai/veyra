# Veyra

**English** · [简体中文](README.zh-CN.md)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/brand/veyra-logo-preview-dark.png">
  <img src="assets/brand/veyra-logo-preview.png" alt="Veyra" width="360">
</picture>

Veyra is a native Swift 6 and SwiftUI menu bar app for monitoring Codex quotas and local Codex and dsh tasks. It shows quota windows and reset times alongside active tasks, models, elapsed time, and token usage without getting in the way of your work.

## Requirements

- macOS 14 or later.
- Local Codex or dsh usage. Monitoring dsh alone does not require Codex.
- Codex quota sync and provider configuration require a local `codex` executable and data directory. Quota sync also requires your Codex ChatGPT sign-in and needs no API key.

## Install

Download the latest archive from [GitHub Releases](https://github.com/yuzio-ai/veyra/releases), unzip it, and move `Veyra.app` to the Applications folder. Launch Veyra from Applications; it appears only in the menu bar and does not add a Dock icon.

## Use

Press **Control + Option + V** (`⌃⌥V`) from any app to show or hide the panel while Veyra is running. Press **Esc** or click outside to close it. In **Settings → Keyboard Shortcut**, record a different combination, disable the shortcut, or restore the default. Include Control, Option, or Command; Shift is optional. Recording pauses the active shortcut, and Esc or leaving the recorder cancels it. Conflicts are shown in settings without replacing your previous choice. No Accessibility or Input Monitoring permission is required.

Click the Veyra menu bar icon to inspect active task families, task status, elapsed time, token totals, and online quota data. Quotas sync every minute while tasks run and every hour while idle; the quota refresh button also supports manual sync. Quotas are hidden and polling stops for third-party providers. The menu bar shows remaining quota as a ring with a larger centered number (without a percent sign) and running tasks as a count inside a rounded rectangle. If automatic Codex discovery does not match your installation, set the executable or data directory in Veyra settings. Valid paths apply automatically when you press Return, leave the field, or confirm a file selection. Clear a field to use automatic detection; **Restore automatic detection** clears both overrides.

When using only dsh, the panel shows local tasks and the confirmed running count. Codex quota and provider controls are hidden, and their requests are stopped. Choose a data directory in **Settings → General → dsh**. The path order is your saved override, a nonblank `DSH_HOME`, then `~/.dsh`. Finder launches usually do not inherit terminal environment variables. A failure in one source leaves the other source working, with a notice that the running count may be incomplete.

Veyra checks the public GitHub Releases feed on launch and when opening the menu, at most once every 24 hours. Turn off automatic checks or use **Check for Updates…** in Settings → **Software Update**. When a newer version is available, **Go to Download** opens that release in your browser. Download the app archive, quit Veyra, and replace it in Applications; Veyra does not download or install updates itself. Update checks use no GitHub token or Codex credentials.

Veyra monitors existing local data in read-only mode. It does not create, resume, or control tasks, automatically run model inference, copy Codex sign-in credentials, or modify Codex databases and session files. The user-initiated **Test connection** action in provider settings sends a small model request and may incur API charges.

Use **Settings → Models** to choose DeepSeek, Kimi, GLM, MiniMax, or MiMo, enter a standard API key, and **Save**. Then use **Refresh models** to fetch the provider list. Veyra bundles no model list and never selects the first model automatically. Choose a model and click **Save and set as default** or **Set as default**, then restart Codex. For the current default provider, use **Save and apply** or **Apply** to update its configuration. Saving updates Veyra only; it does not fetch models or change Codex defaults. App startup, Settings, and menu switching do not fetch models either. Sidebar highlighting marks the editor selection; checkmarks mark the default provider for new sessions. Configuration status and problems appear in the detail pane. Domestic endpoints and authentication are preset. Provider context windows and default reasoning efforts use discovered metadata, with manual overrides taking precedence and missing values following Codex defaults. Keys stay in this Mac's system Keychain. Codex calls Veyra's headless credential command using an opaque reference; keys never enter config files or environment variables. **Add provider** creates custom connections. External Codex configuration changes sync automatically; quota polling follows the selected provider. Existing connections keep their identities. Legacy environment-based connections require a new Key to convert; Veyra never reads their environment values. Switch configured providers or return to official OpenAI sign-in from the menu or Settings. **Test connection** checks Responses compatibility with a user-initiated model request that may incur API charges; it does not establish full Codex tool support.

Uncertain tasks are hidden after 24 hours without recorded activity when a successful process check finds no matching Codex process. Tasks with matching processes remain visible regardless of age; failed process checks keep the existing uncertain status and warning. This display filter does not modify task history.

Veyra supports English and Simplified Chinese and follows your macOS language preferences. To choose a language just for Veyra, add it under **System Settings → General → Language & Region → Applications**, then restart Veyra. English is used when none of your preferred languages is supported. Dates and times follow your regional settings. Task titles and original Codex progress text are shown as recorded.

## Documentation

Detailed documentation is currently available in Chinese:

- [User guide](docs/user-guide.zh-CN.md)
- [Data, privacy, and compatibility](docs/data-and-privacy.zh-CN.md)
- [Development](docs/development.zh-CN.md)
- [Manual release runbook](docs/release.zh-CN.md)
