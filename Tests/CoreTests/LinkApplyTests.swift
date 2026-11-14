import Foundation
import Testing

@testable import Core

/// What `Linker.apply` and `Linker.removeLinks` check after the typed approval, and what a link
/// that fails part way leaves in the record.
extension FolderAccountsTests {
    static let otherKeySettings =
        #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo one"}]}]},"model":"opus"}"#

    func writeDefaultSettings(_ t: TestHome, _ body: String) throws {
        try body.write(
            to: t.home.appendingPathComponent(".claude/settings.json"), atomically: true,
            encoding: .utf8)
    }

    func expectNothingLinked(_ context: ToolContext, record bytes: Data) throws {
        #expect(try recordBytes(context) == bytes)
        #expect(try destination(context, "settings.json") == nil)
        #expect(try destination(context, "CLAUDE.md") == nil)
        #expect(!HookRecord(context: context).isLinked("spare"))
    }

    // MARK: The settings verdict after the typed approval

    @Test func applyRefusesWhenTheSettingsChangedAfterThePlan() throws {
        let (t, context) = try setUp()
        defer { withExtendedLifetime(t) {} }
        let built = try plan(context)
        #expect(built.verdict.issue == nil && built.verdict.stamp != nil)
        let bytes = try recordBytes(context)
        try writeDefaultSettings(t, Self.otherKeySettings)
        do {
            _ = try Linker.apply(context: context, plan: built)
            Issue.record("apply went ahead")
        } catch let error as ToolError {
            #expect(error.message.hasPrefix(Messages.settingsMovedAfterApproval))
            #expect(error.message.contains(Messages.settingsNotChecked))
        }
        try expectNothingLinked(context, record: bytes)
    }

    @Test func applyRefusesAVerdictSavedAgainForSettingsEditedAfterThePlan() throws {
        let (t, context) = try setUp()
        defer { withExtendedLifetime(t) {} }
        let built = try plan(context)
        let bytes = try recordBytes(context)
        // The hooks still match the record, and a reader saved the new file's verdict.
        try writeDefaultSettings(t, Self.otherKeySettings)
        let hooks = HookRecord(context: context)
        _ = try hooks.readSettings()
        #expect(hooks.seenVerdict().issue == nil)
        #expect(throws: ToolError.self) { _ = try Linker.apply(context: context, plan: built) }
        try expectNothingLinked(context, record: bytes)
        // A plan built now goes ahead.
        _ = try Linker.apply(context: context, plan: try plan(context))
        #expect(hooks.isLinked("spare"))
    }

    @Test func applyRefusesAPlanBuiltWhileTheVerdictFailed() throws {
        let (t, context) = try setUp()
        defer { withExtendedLifetime(t) {} }
        try FileManager.default.removeItem(
            at: context.dataRoot.appendingPathComponent("state/settings-seen.json"))
        let built = try plan(context)
        #expect(built.verdict.issue == Messages.settingsNotChecked)
        _ = try HookRecord(context: context).readSettings()
        let bytes = try recordBytes(context)
        #expect(throws: ToolError.self) { _ = try Linker.apply(context: context, plan: built) }
        try expectNothingLinked(context, record: bytes)
    }

    @Test func applyRefusesAPlanBuiltWhileTheVerdictFailedThatStillFails() throws {
        let (t, context) = try setUp()
        defer { withExtendedLifetime(t) {} }
        try FileManager.default.removeItem(
            at: context.dataRoot.appendingPathComponent("state/settings-seen.json"))
        let built = try plan(context)
        #expect(built.verdict.issue == Messages.settingsNotChecked)
        // No reader runs before the apply, so the verdict is still the plan's, and still fails.
        #expect(HookRecord(context: context).seenVerdict() == built.verdict)
        let bytes = try recordBytes(context)
        #expect(throws: ToolError.self) { _ = try Linker.apply(context: context, plan: built) }
        try expectNothingLinked(context, record: bytes)
    }

    // MARK: The linked flag alone

    @Test func aChangeToTheLinkedFlagAloneBetweenPlanAndApplyIsRefused() throws {
        let (t, context) = try setUp()
        defer { withExtendedLifetime(t) {} }
        _ = try link(context)
        let hooks = HookRecord(context: context)
        try FileManager.default.createDirectory(
            at: t.home.appendingPathComponent(".claude/skills"), withIntermediateDirectories: true)
        let built = try plan(context)
        #expect(built.changesAnything)
        let state = hooks.linkState(for: "spare")
        try hooks.saveLinks(label: "spare", entries: state.entries, linked: false)
        #expect(hooks.linkState(for: "spare").entries == state.entries)
        let bytes = try recordBytes(context)
        #expect(throws: ToolError.self) { _ = try Linker.apply(context: context, plan: built) }
        #expect(try recordBytes(context) == bytes)
        #expect(try destination(context, "skills") == nil)

        // The same for removing: the list shown while not linked, the flag set before the removal.
        let shown = hooks.linkState(for: "spare")
        #expect(!shown.linked)
        try hooks.saveLinks(label: "spare", entries: shown.entries, linked: true)
        let again = try recordBytes(context)
        #expect(throws: ToolError.self) {
            _ = try Linker.removeLinks(context: context, label: "spare", expecting: shown)
        }
        #expect(try recordBytes(context) == again)
        #expect(try destination(context, "CLAUDE.md") != nil)
    }

    // MARK: A link that fails part way

    @Test func aLinkThatFailsPartWayKeepsTheLinksMadeListedAndTheFolderNotLinked() throws {
        let (t, context) = try setUp()
        defer { withExtendedLifetime(t) {} }
        let built = try plan(context)
        let actions = Array(built.items.map(\.action).prefix(2))
        #expect(actions == [LinkPlan.Action.create, LinkPlan.Action.create])
        // A file appears where the second link goes, after the plan.
        let blocker = try accountFolder(context).appendingPathComponent("CLAUDE.md")
        try "mine".write(to: blocker, atomically: true, encoding: .utf8)
        #expect(throws: ToolError.self) { _ = try Linker.apply(context: context, plan: built) }
        let hooks = HookRecord(context: context)
        #expect(!hooks.isLinked("spare"))
        let listed = hooks.entries(for: "spare")
        #expect(listed.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["settings.json"])
        #expect(try destination(context, "settings.json") == listed.first?.target)
        #expect(try String(contentsOf: blocker, encoding: .utf8) == "mine")
    }

    @Test func aLinkThatFailsPartWayKeepsThePriorEntryOfTheItemThatFailed() throws {
        let (t, context) = try setUp()
        defer { withExtendedLifetime(t) {} }
        // Two shared folders the failing item comes before, so the run never reaches them.
        for name in ["skills", "agents"] {
            try FileManager.default.createDirectory(
                at: t.home.appendingPathComponent(".claude").appendingPathComponent(name),
                withIntermediateDirectories: true)
        }
        _ = try link(context)
        let hooks = HookRecord(context: context)
        let old = try #require(
            hooks.entries(for: "spare").first { $0.path.hasSuffix("/CLAUDE.md") })
        // CLAUDE.md in the default folder now resolves to another file, so repair replaces it.
        let source = t.home.appendingPathComponent(".claude/CLAUDE.md")
        let moved = t.home.appendingPathComponent("notes/CLAUDE.md")
        try FileManager.default.createDirectory(
            at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: source, to: moved)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: moved)
        let built = try plan(context, repair: true)
        #expect(built.items.first { $0.name == "CLAUDE.md" }?.action == LinkPlan.Action.replace)
        let names = built.items.map(\.name)
        let failing = try #require(names.firstIndex(of: "CLAUDE.md"))
        let skillsAt = try #require(names.firstIndex(of: "skills"))
        let agentsAt = try #require(names.firstIndex(of: "agents"))
        #expect(skillsAt > failing && agentsAt > failing)
        // After the plan, the agents link goes; its entry must not outlive it.
        let agents = try accountFolder(context).appendingPathComponent("agents")
        try FileManager.default.removeItem(at: agents)
        // The account folder takes no change, so the replace fails with the old link in place.
        let folder = try accountFolder(context)
        chmod(folder.path, 0o500)
        defer { chmod(folder.path, 0o700) }
        try #require(access(folder.path, W_OK) != 0)
        #expect(throws: ToolError.self) { _ = try Linker.apply(context: context, plan: built) }
        chmod(folder.path, 0o700)
        #expect(!hooks.isLinked("spare"))
        let listed = hooks.entries(for: "spare")
        #expect(listed.contains(old))
        #expect(listed.contains { $0.path.hasSuffix("/settings.json") })
        #expect(try destination(context, "CLAUDE.md") == old.target)
        // An item the run never reached keeps its entry while its link stands, and only then.
        #expect(listed.contains { $0.path.hasSuffix("/skills") })
        #expect(try destination(context, "skills") != nil)
        #expect(!listed.contains { $0.path.hasSuffix("/agents") })
    }
}
