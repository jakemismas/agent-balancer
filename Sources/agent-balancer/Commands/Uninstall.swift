import ArgumentParser
import Core
import Foundation

struct UninstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Remove the files this tool made. Account folders and logins stay.")

    func run() throws {
        let context = ToolContext.current()
        try Shared.requireOwnTerminal(context)
        let leaseMinutes = Uninstall.leaseWindow(context: context)
        let plan = try Uninstall.plan(context: context, leaseMinutes: leaseMinutes)
        if plan.isEmpty {
            print("Nothing to remove: the tool has made no files.")
            return
        }

        for line in Self.listing(plan, leaseMinutes: leaseMinutes) { print(line) }
        guard Shared.ask("Type uninstall to remove these: ") == "uninstall" else {
            throw ToolError("Not confirmed. Nothing was removed.")
        }
        // The removal reads the session records again under the lock, not the ones listed above.
        let done = try Uninstall.run(context: context, leaseMinutes: leaseMinutes)
        // A rerun starts from the window it can read then: the default once the config is gone.
        let rerun = Uninstall.leaseWindow(context: context)
        for line in Self.closing(done, rerunMinutes: rerun) { print(line) }
        // A file that may still hold a token means the removal is not done.
        let mayHoldAToken =
            done.tokenFilesLeft + done.temporariesLeft + done.otherCaseEntries
            + done.launchEntriesNotFollowed
        if mayHoldAToken > 0 { throw ExitCode.failure }
    }

    /// What `uninstall` shows before the typed word: counts only, never a name or a path.
    static func listing(_ plan: Uninstall.Plan, leaseMinutes: Int) -> [String] {
        let named =
            plan.recordsReadable ? "\(plan.launchFilesNamed)" : "\(plan.launchFilesNamed) or more"
        var lines = [
            "agent-balancer uninstall removes these files the tool made:",
            "  launch files: \(plan.launchFiles)",
            "  launch files a session record still names: \(named)",
            "  token files: \(plan.tokenFiles)",
            "  temporary files that may hold a token: \(plan.temporaries)",
            "  state files, events and history included: \(plan.stateFiles)",
            "  log files: \(plan.logFiles)",
            "  backup files: \(plan.backupFiles)",
            "  probe files: \(plan.probeFiles)",
            "  links: \(plan.links) listed, \(plan.linksIntact) still in place",
            "  link manifest: \(plan.hasLinksFile ? "yes" : "no")",
            "  config: \(plan.hasConfig ? "yes" : "no")",
            "  temporary files of the config and the link manifest: \(plan.dataFolderTemporaries)",
            "  lock files: \(plan.lockFiles)",
        ]
        if !plan.recordsReadable {
            lines.append(
                "Some session records could not be read, so every launch file is kept as a tombstone."
            )
        }
        if !plan.leasesReadable {
            lines.append(
                "The lease file could not be read, so every launch file is kept as a tombstone.")
        }
        if plan.otherCaseEntries > 0 {
            lines.append(
                "\(plan.otherCaseEntries) entries in the token or launch folder are named like the tool's own in other letter case and may hold a token. They are left unopened, and the closing text says what to do."
            )
        }
        if plan.launchEntriesNotFollowed > 0 {
            lines.append(
                "\(plan.launchEntriesNotFollowed) entries in the launch folder where a label's folder belongs are a link, a file or another user's folder, and a launch file with a token may be behind them. They are not followed, and the closing text says what to do."
            )
        }
        if plan.stateTemporariesInUse > 0 {
            lines.append(
                "\(plan.stateTemporariesInUse) temporary files in `~/.agent-balancer/state/` are younger than a minute or dated ahead of the clock, so a save may still be using them. They stay until a run finds them a minute old, and the closing text says what to do."
            )
        }
        lines.append(
            "A launch file that a session record names, that an open lease holds or that is younger than \(leaseMinutes) minutes is overwritten with a tombstone that holds no token, and kept with its folders."
        )
        lines.append(
            "Account folders, every login and anything the tool did not make stay where they are. The data folder goes too when nothing is left in it."
        )
        return lines
    }

    /// What `uninstall` says once it is done. `rerunMinutes` is the lease window a rerun starts
    /// from.
    static func closing(_ done: Uninstall.Result, rerunMinutes: Int) -> [String] {
        var lines = [
            "Removed \(done.linksRemoved) links. Kept \(done.linksKept) listed paths that are no longer the link the tool made.",
            "Deleted \(done.tokenFiles) token files and \(done.launchFiles) launch files.",
        ]
        if done.tokenFilesLeft > 0 {
            lines.append(TokenAccounts.undeletedTokenFilesText(done.tokenFilesLeft))
        }
        if done.temporariesLeft > 0 {
            lines.append(TokenAccounts.undeletedTemporariesText(done.temporariesLeft))
        }
        if done.otherCaseEntries > 0 {
            lines.append(TokenAccounts.otherCaseEntriesText(done.otherCaseEntries))
        }
        if done.launchEntriesNotFollowed > 0 {
            lines.append(LaunchFiles.notFollowedEntriesText(done.launchEntriesNotFollowed))
        }
        if done.launchFilesKept > 0 {
            lines.append(
                "Kept \(done.launchFilesKept) launch files as tombstones. They hold no token, and a rerun of `agent-balancer uninstall` deletes them once nothing names them and \(rerunMinutes) minutes have passed since this run."
            )
        }
        lines.append(
            "Deleted \(done.otherFiles) other files (state, logs, backups, probe, locks, the link manifest, the config and their temporary files)."
        )
        if done.stateTemporariesKept > 0 {
            lines.append(
                "Kept \(done.stateTemporariesKept) temporary files in `~/.agent-balancer/state/` that a save may still be using. Quit the menu bar app, then run `agent-balancer uninstall` again in a minute to delete them. One dated ahead of the clock goes only on a run a minute or more after that date."
            )
        }
        if done.entriesLeft > 0 {
            lines.append(
                "Left \(done.entriesLeft) entries alone: the tool did not make them, or could not delete them."
            )
        }
        if done.dataFolderRemoved {
            lines.append("Removed the data folder, since nothing was left in it.")
        }
        lines.append(
            "The tokens themselves may keep working until their year ends, because no way to cancel one is documented."
        )
        lines.append(
            "Next, delete the app from Applications and run `brew uninstall agent-balancer`.")
        return lines
    }
}
