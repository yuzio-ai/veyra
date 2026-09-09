import SwiftUI

struct UpdateDownloadLink: View {
    let release: AppRelease

    var body: some View {
        Link(destination: release.pageURL) {
            Label("Go to Download", systemImage: "arrow.up.right")
        }
        .accessibilityIdentifier("updates.download")
        .help("Download the new version from GitHub, then quit Veyra and replace the app.")
    }
}

struct UpdateSettingsSection: View {
    @Bindable var updates: UpdateStore

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.contentSpacing) {
            Text("Software Update").font(.headline)
            VStack(alignment: .leading, spacing: SettingsLayout.rowSpacing) {
                VStack(alignment: .leading, spacing: SettingsLayout.descriptionSpacing) {
                    HStack {
                        Text("Automatically check for updates")
                        Spacer()
                        Toggle("Automatically check for updates", isOn: Binding(
                            get: { updates.automaticallyChecks }, set: { updates.setAutomaticallyChecks($0) }))
                            .toggleStyle(.switch).labelsHidden()
                            .accessibilityIdentifier("updates.automatic")
                    }
                    Text("Checks for a new version at most once a day.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                UpdateStatusRow(updates: updates)
            }
        }
        .accessibilityIdentifier("updates.settings")
    }
}

private struct UpdateStatusRow: View {
    @Bindable var updates: UpdateStore
    @Environment(\.monitorReferenceDate) private var referenceDate

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.labelSpacing) {
            TimelineView(.explicit([updates.nextManualCheckAt ?? .distantPast])) { context in
                let date = referenceDate ?? context.date
                VStack(alignment: .leading, spacing: SettingsLayout.labelSpacing) {
                    HStack(spacing: SettingsLayout.labelSpacing) {
                        if updates.isChecking {
                            ProgressView().controlSize(.small).accessibilityHidden(true)
                        }
                        Text(updates.settingsStatus)
                            .font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("updates.status")
                        Spacer(minLength: SettingsLayout.labelSpacing)
                        Button("Check for Updates…") { Task { await updates.checkManually() } }
                            .disabled(updates.isChecking || updates.nextManualCheckAt.map { date < $0 } == true)
                            .accessibilityIdentifier("updates.check")
                    }
                    if !updates.isChecking, let next = updates.nextManualCheckAt, next > date {
                        Text(L10n.text("Check again after \(next.formatted(date: .omitted, time: .standard))"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let release = updates.availableRelease {
                HStack(alignment: .firstTextBaseline, spacing: SettingsLayout.labelSpacing) {
                    VStack(alignment: .leading, spacing: SettingsLayout.descriptionSpacing) {
                        Text(L10n.text("New version available: \(release.version)"))
                            .font(.subheadline.weight(.medium))
                        Text("Download and install the new version manually.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: SettingsLayout.labelSpacing)
                    UpdateDownloadLink(release: release)
                }
            }
        }
    }
}
