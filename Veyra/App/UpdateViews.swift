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
    @Environment(\.monitorReferenceDate) private var referenceDate

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("App Updates").font(.headline)
                Spacer()
                Text(L10n.text("Current version: \(updates.currentVersion)"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Toggle("Automatically check for updates", isOn: Binding(
                get: { updates.automaticallyChecks }, set: { updates.setAutomaticallyChecks($0) }))
                .accessibilityIdentifier("updates.automatic")
            Text("Checks GitHub on launch or when opening the menu, at most once every 24 hours. Downloads and installation are manual.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TimelineView(.explicit([updates.nextManualCheckAt ?? .distantPast])) { context in
                let date = referenceDate ?? context.date
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Button("Check for Updates") { Task { await updates.checkManually() } }
                            .disabled(updates.isChecking || updates.nextManualCheckAt.map { date < $0 } == true)
                            .accessibilityIdentifier("updates.check")
                        if updates.isChecking {
                            ProgressView().controlSize(.small)
                            Text("Checking for updates…").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    if !updates.isChecking, let next = updates.nextManualCheckAt, next > date {
                        Text(L10n.text("Check again after \(next.formatted(date: .omitted, time: .standard))"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if !updates.isChecking {
                switch updates.result {
                case .notChecked:
                    Text("Updates have not been checked yet.").font(.callout).foregroundStyle(.secondary)
                case .upToDate:
                    Text("You’re up to date.").font(.callout).foregroundStyle(.secondary)
                case .failed(let failure):
                    Text(failure.message).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                case .available: EmptyView()
                }
            }
            if let release = updates.availableRelease {
                HStack {
                    Text(L10n.text("New version available: \(release.version)"))
                        .font(.callout.weight(.medium))
                    Spacer()
                    UpdateDownloadLink(release: release)
                }
            }
        }
        .accessibilityIdentifier("updates.settings")
    }
}
