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
        let store = ConfigStore(context: context)
        let leaseMinutes = (try? store.load())?.picker.leaseMinutes ?? PickerSettings().leaseMinutes
        let snapshot = SessionsReader.read(context: context)
        let plan = Uninstall.plan(context: context, leaseMinutes: leaseMinutes, snapshot: snapshot)
        if plan.isEmpty {
            print("Nothing to remove: the tool has made no files.")
            return
        }

        print("agent-balancer uninstall removes these files the tool made:")
        print("  links: \(plan.links) listed, \(plan.linksIntact) still in place")
        print("  link manifest: \(plan.hasLinksFile ? "yes" : "no")")
        print("  config: \(plan.hasConfig ? "yes" : "no")")
        print("  token files: \(plan.tokenFiles)")
        print("  launch files: \(plan.launchFiles)")
        if plan.recordsReadable {
            print("  launch files a session record still names: \(plan.launchFilesNamed)")
        } else {
            print("  session records could not be read, so every launch file counts as named")
        }
        print("  state files, events and history included: \(plan.stateFiles)")
        print("  log files: \(plan.logFiles)")
        print("  backup files: \(plan.backupFiles)")
        print(
            "A launch file that a session record names, that an open lease holds or that is younger than \(leaseMinutes) minutes is overwritten with a tombstone that holds no token, and kept with its folders."
        )
        print("Account folders and every login stay where they are.")

        guard Shared.ask("Type uninstall to remove these: ") == "uninstall" else {
            throw ToolError("Not confirmed. Nothing was removed.")
        }
        let done = try Uninstall.run(
            context: context, leaseMinutes: leaseMinutes, snapshot: snapshot)
        print(
            "Removed \(done.linksRemoved) links. Kept \(done.linksKept) listed paths that are no longer the link the tool made."
        )
        print("Deleted \(done.tokenFiles) token files and \(done.launchFiles) launch files.")
        if done.launchFilesKept > 0 {
            print(
                "Kept \(done.launchFilesKept) launch files as tombstones. They hold no token."
            )
        }
        print("Deleted \(done.otherFiles) other files (state, logs, backups, config).")
        if done.entriesLeft > 0 {
            print("Left \(done.entriesLeft) entries alone: the tool did not make them.")
        }
        if done.temporariesLeft > 0 {
            print(
                "Left \(done.temporariesLeft) temporary entries alone: they could not be deleted.")
        }
        print(
            "The tokens themselves may keep working until their year ends, because no way to cancel one is documented."
        )
        print(
            "Next, delete the app from Applications and run `brew uninstall agent-balancer`.")
    }
}
