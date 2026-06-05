import SwiftUI

struct SettingsAboutTab: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    var body: some View {
        Form {
            appInfoSection
            if AppEnvironment.isBundledApp {
                updatesSection
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: App info

    private var appInfoSection: some View {
        Section {
            HStack(spacing: 16) {
                if let icon = Asset.nsImage("appicon") {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentColor)
                        .frame(width: 56, height: 56)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Looking Glass")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Version \(version)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("Personal AI research companion")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 4)

            Link("View on GitHub", destination: URL(string: "https://github.com/yogiee/LookingGlass")!)
                .font(.system(size: 12))
        }
    }

    // MARK: Updates

    @ViewBuilder
    private var updatesSection: some View {
        Section("Updates") {
            Picker("Check for Updates", selection: Binding(
                get: { UpdaterService.shared.updateCheckSchedule },
                set: { UpdaterService.shared.updateCheckSchedule = $0 }
            )) {
                ForEach(UpdateCheckSchedule.allCases, id: \.rawValue) { schedule in
                    Text(schedule.displayName).tag(schedule)
                }
            }
            Button("Check for Updates…") {
                UpdaterService.shared.checkForUpdates()
            }
        }
    }
}
