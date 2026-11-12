import Foundation

/// The `doctor` checks that need no `claude`: the launch file count and age, and a data folder in
/// a synced location (docs/ARCHITECTURE.md section 13).
public enum DoctorChecks {
    /// The launch files the tool holds, and the age of the oldest. Never a path or any content.
    public struct LaunchSummary: Equatable, Sendable {
        public var count: Int
        public var oldestAge: TimeInterval?
    }

    public static func launchFiles(
        context: ToolContext, snapshot: SessionsSnapshot, now: Date = Date()
    ) -> LaunchSummary {
        let inventory = Core.LaunchFiles.inventory(context: context, snapshot: snapshot, now: now)
        return LaunchSummary(count: inventory.files, oldestAge: inventory.oldestAge)
    }

    /// `3 days`, `5 hours`, `12 minutes` or `under a minute`.
    public static func describe(age: TimeInterval) -> String {
        let minutes = Int(age / 60)
        if minutes < 1 { return "under a minute" }
        if minutes < 120 { return "\(minutes) minutes" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours) hours" }
        return "\(hours / 24) days"
    }

    private static func provider(_ part: String) -> String? {
        if part == "Mobile Documents" || part == "iCloud Drive" { return "iCloud Drive" }
        if part == "Dropbox" || part.hasPrefix("Dropbox (") || part.hasPrefix("Dropbox-") {
            return "Dropbox"
        }
        if part == "OneDrive" || part.hasPrefix("OneDrive-") || part.hasPrefix("OneDrive - ") {
            return "OneDrive"
        }
        if part == "Google Drive" || part.hasPrefix("GoogleDrive") { return "Google Drive" }
        if part == "Box" || part == "Box Sync" || part.hasPrefix("Box-") { return "Box" }
        if part == "pCloud Drive" || part == "MEGA" { return "a sync service" }
        if part == "CloudStorage" { return "a cloud storage provider" }
        return nil
    }

    /// The name of the sync service when the data folder sits inside a synced location, or nil.
    /// The path is read as text; no file is opened.
    public static func syncedFolder(context: ToolContext) -> String? {
        for part in context.dataRoot.standardizedFileURL.pathComponents {
            if let name = provider(part) { return name }
        }
        return nil
    }
}
