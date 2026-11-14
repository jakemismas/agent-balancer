import Core
import Foundation
import Testing

@testable import Core

private func output(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

/// What a typed approval covers, end to end with a scripted terminal: the record or the settings
/// change while the prompt waits, and the command refuses after the typed answer, writing nothing.
extension FolderAccountsCLITests {
    static let threeHooks =
        #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo one"}]},{"hooks":[{"type":"command","command":"echo two"}]},{"hooks":[{"type":"command","command":"echo three"}]}]}}"#
    static let linkPrompt = "Type the label (spare) to make these changes: "
    static let unlinkPrompt = "Type the label (spare) to remove them: "
    static let acceptPrompt = "Type accept to record these hooks: "

    func record(_ cli: CLIHome) -> Data {
        (try? Data(contentsOf: cli.dataRoot.appendingPathComponent("links.json"))) ?? Data()
    }

    // MARK: link --accept-source-change

    @Test func acceptRefusesWhenTheHookRecordChangedAfterTheDifferenceWasShown() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try cli.settings(Self.twoHooks)
        let hooks = HookRecord(context: context(cli))
        var changed = Data()
        let out = try cli.runOnTerminal(
            ["link", "--accept-source-change"], prompt: Self.acceptPrompt,
            between: {
                try hooks.record(.empty)
                changed = record(cli)
            }, typing: "accept\n")
        #expect(out.status == 1)
        #expect(output(out.stderr).contains("The hook record changed after you were shown"))
        #expect(!changed.isEmpty && record(cli) == changed)
        #expect(hooks.recorded()?.hooks.isEmpty == true)
    }

    @Test func acceptRefusesWhenTheSettingsChangedAfterTheDifferenceWasShown() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try cli.settings(Self.twoHooks)
        let before = record(cli)
        let out = try cli.runOnTerminal(
            ["link", "--accept-source-change"], prompt: Self.acceptPrompt,
            between: { try cli.settings(Self.threeHooks) }, typing: "accept\n")
        #expect(out.status == 1)
        #expect(output(out.stderr).contains("changed after you were shown them"))
        #expect(record(cli) == before)
        // With nothing changing while it waits, the same command records the hooks.
        let done = try cli.runOnTerminal(
            ["link", "--accept-source-change"], prompt: Self.acceptPrompt, between: {},
            typing: "accept\n")
        #expect(done.status == 0, "\(output(done.stderr))")
        #expect(HookRecord(context: context(cli)).recorded()?.hooks.count == 3)
    }

    // MARK: unlink

    @Test func unlinkRefusesWhenTheLinksItShowedChangedBeforeTheTypedLabel() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try linked(cli)
        let hooks = HookRecord(context: context(cli))
        var changed = Data()
        let out = try cli.runOnTerminal(
            ["unlink", "spare"], prompt: Self.unlinkPrompt,
            between: {
                let shown = hooks.linkState(for: "spare")
                try hooks.saveLinks(
                    label: "spare", entries: Array(shown.entries.dropLast()), linked: true)
                changed = record(cli)
            }, typing: "spare\n")
        #expect(out.status == 1)
        #expect(output(out.stderr).contains("changed after you were shown them"))
        #expect(record(cli) == changed)
        #expect(try destination(cli, "settings.json") != nil)
        #expect(try destination(cli, "CLAUDE.md") != nil)
    }

    @Test func unlinkRefusesAChangeToTheLinkedFlagAloneBeforeTheTypedLabel() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try linked(cli)
        let hooks = HookRecord(context: context(cli))
        var changed = Data()
        let out = try cli.runOnTerminal(
            ["unlink", "spare"], prompt: Self.unlinkPrompt,
            between: {
                let shown = hooks.linkState(for: "spare")
                try hooks.saveLinks(label: "spare", entries: shown.entries, linked: false)
                changed = record(cli)
            }, typing: "spare\n")
        #expect(out.status == 1)
        #expect(record(cli) == changed)
        #expect(try destination(cli, "CLAUDE.md") != nil)
    }

    // MARK: link

    @Test func linkRefusesAChangeToTheLinkedFlagAloneBeforeTheTypedLabel() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try linked(cli)
        try FileManager.default.createDirectory(
            at: cli.home.appendingPathComponent(".claude/skills"),
            withIntermediateDirectories: true)
        let hooks = HookRecord(context: context(cli))
        var changed = Data()
        let out = try cli.runOnTerminal(
            ["link", "spare"], prompt: Self.linkPrompt,
            between: {
                let shown = hooks.linkState(for: "spare")
                try hooks.saveLinks(label: "spare", entries: shown.entries, linked: false)
                changed = record(cli)
            }, typing: "spare\n")
        #expect(out.status == 1)
        #expect(output(out.stderr).contains("changed after you were shown them"))
        #expect(record(cli) == changed)
        #expect(try destination(cli, "skills") == nil)
    }

    @Test func linkRefusesWhenTheSettingsChangedAfterTheTypedLabel() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        let before = record(cli)
        let out = try cli.runOnTerminal(
            ["link", "spare"], prompt: Self.linkPrompt,
            between: { try cli.settings(Self.twoHooks) }, typing: "spare\n")
        #expect(out.status == 1)
        #expect(output(out.stderr).contains(Messages.settingsMovedAfterApproval))
        #expect(record(cli) == before)
        #expect(try destination(cli, "settings.json") == nil)
        #expect(try destination(cli, "CLAUDE.md") == nil)
        #expect(!HookRecord(context: context(cli)).isLinked("spare"))
    }

    // MARK: The readers of the default folder's settings

    @Test func everySettingsReaderSavesTheVerdictThatRunUses() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        let verdict = cli.dataRoot.appendingPathComponent("state/settings-seen.json")
        let hooks = HookRecord(context: context(cli))
        for args in [
            ["doctor"], ["pick", "--dry-run"], ["verify", "spare", "--no-reading"],
            ["link", "--accept-source-change", "--dry-run"],
        ] {
            try FileManager.default.removeItem(at: verdict)
            #expect(hooks.seenVerdict().issue == Messages.settingsNotChecked, "\(args)")
            _ = try cli.run(args)
            #expect(FileManager.default.fileExists(atPath: verdict.path), "\(args)")
            #expect(hooks.seenVerdict().issue == nil, "\(args)")
        }
        // `init` reads them in a home it sets up.
        let fresh = try CLIHome()
        defer { fresh.cleanup() }
        try fresh.fakeFixture("logged_in")
        try fresh.settings(Self.hookSettings)
        let done = try fresh.run(["init", "--label", "main"])
        #expect(done.status == 0, "\(output(done.stderr))")
        #expect(HookRecord(context: context(fresh)).seenVerdict().issue == nil)
    }

    // MARK: A settings path that no reader can fix

    @Test func linkNamesTheFixForASettingsPathThatGoesNowhereOrIsNotAFile() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        let url = cli.home.appendingPathComponent(".claude").appendingPathComponent(
            SharedItems.settingsName)
        let fix = "Fix ~/.claude/" + SharedItems.settingsName + " in the default folder"
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(
            at: url, withDestinationURL: cli.home.appendingPathComponent("gone.json"))
        _ = try cli.run(["doctor"])
        for args in [["link", "spare", "--dry-run"], ["link", "spare", "--repair", "--dry-run"]] {
            let out = try cli.run(args)
            let shown = output(out.stdout) + output(out.stderr)
            #expect(out.status == 1, "\(args)")
            #expect(shown.contains("the source is a link that goes nowhere."), "\(args) \(shown)")
            #expect(shown.contains(fix), "\(args)")
            #expect(!shown.contains(Messages.settingsNotChecked), "\(args)")
        }
        // A folder where the settings file belongs names its own fix the same way.
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        _ = try cli.run(["doctor"])
        let folder = try cli.run(["link", "spare", "--dry-run"])
        let shown = output(folder.stdout) + output(folder.stderr)
        #expect(folder.status == 1)
        #expect(shown.contains("the source is not a regular file."), "\(shown)")
        #expect(shown.contains(fix))
        #expect(!shown.contains(Messages.settingsNotChecked))
    }
}
