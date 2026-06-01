@preconcurrency import Sparkle
import Foundation

enum AppEnvironment {
    /// True only when running from a built .app bundle that carries a Sparkle
    /// feed URL — i.e. NOT `swift run`. Sparkle needs a real bundle; gating on
    /// this keeps development runs free of Sparkle "no feed" errors.
    static var isBundledApp: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
            && Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
    }
}

enum UpdateCheckSchedule: Int, CaseIterable {
    case daily   = 86400
    case weekly  = 604800
    case manual  = 0

    var displayName: String {
        switch self {
        case .daily:  "Every day"
        case .weekly: "Every week"
        case .manual: "Manual only"
        }
    }
}

/// Sparkle auto-update wrapper. Mirrors the Typa / WallP pattern.
///
/// Schedule options (persisted in UserDefaults under "lg.updateCheckSchedule"):
///   daily  — check + download + install every 24 h
///   weekly — check + download + install every 7 days (default)
///   manual — no automatic checking; user triggers via Settings / menu
@Observable
@MainActor
final class UpdaterService {
    @MainActor static let shared = UpdaterService()

    private let controller: SPUStandardUpdaterController
    private let scheduleKey = "lg.updateCheckSchedule"

    var updateCheckSchedule: UpdateCheckSchedule {
        get {
            let raw = UserDefaults.standard.integer(forKey: scheduleKey)
            return UpdateCheckSchedule(rawValue: raw) ?? .weekly
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: scheduleKey)
            applySchedule(newValue)
        }
    }

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        let raw = UserDefaults.standard.integer(forKey: scheduleKey)
        applySchedule(UpdateCheckSchedule(rawValue: raw) ?? .weekly)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    private func applySchedule(_ schedule: UpdateCheckSchedule) {
        let updater = controller.updater
        switch schedule {
        case .daily, .weekly:
            updater.automaticallyChecksForUpdates = true
            updater.automaticallyDownloadsUpdates = true
            updater.updateCheckInterval = TimeInterval(schedule.rawValue)
        case .manual:
            updater.automaticallyChecksForUpdates = false
            updater.automaticallyDownloadsUpdates = false
        }
    }
}
