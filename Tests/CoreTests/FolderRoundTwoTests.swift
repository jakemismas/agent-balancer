import Foundation
import Testing

@testable import Core

private final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Bool] = []

    func add(_ ok: Bool) {
        lock.lock()
        defer { lock.unlock() }
        results.append(ok)
    }

    var wins: Int {
        lock.lock()
        defer { lock.unlock() }
        return results.filter { $0 }.count
    }
}

/// The caller's session folder through `pick`, a terminal check with a stand-in, and changes
/// that are refused when the record moved after the person was shown it.
extension FolderAccountsTests {
    func token(_ label: String = "tok") -> Account {
        Account(label: label, kind: Kind.token, role: Role.pool)
    }

    // MARK: Ambient session folder, through pick

    @Test func aJobFolderThatIsNotTheDefaultOneSkipsLoginAndTokenThroughPick() throws {
        let (t, _) = try setUp(extra: [login(), token()], settings: nil)
        defer { withExtendedLifetime(t) {} }
        _ = try t.makeTokenFile(label: "tok", secret: Canaries.oauthRealShape())
        _ = try link(t.context)
        let home = t.home.path
        let values = [
            try accountFolder(t.context).path + "/jobs/abc", home + "/.claude/jobs/../x",
            "relative/jobs/abc", home + "/.claude/jobs/a/b", home + "/.claude/jobs",
        ]
        // Each pick takes a lease, so the variants are few: every value in a plain shell, then one
        // value in a chat shell, then a launcher.
        var runs = values.map { ($0, false) }
        runs.append((values[0], true))
        for (value, chat) in runs {
            var env = ["CLAUDE_JOB_DIR": value]
            if chat { env["CLAUDE_CODE_CHILD_SESSION"] = "1" }
            let context = t.context(ambient: env)
            let result = try pick(context)
            #expect(result.label == "spare", "\(value) chat \(chat)")
            #expect((result.launchPrefix ?? "").hasPrefix("CLAUDE_CONFIG_DIR='"), "\(value)")
            let reasons = Dictionary(
                uniqueKeysWithValues: result.candidates.map { ($0.label, $0.reason) })
            #expect(reasons["main"] == "ambient session folder not default", "\(value)")
            #expect(reasons["tok"] == "ambient session folder not default", "\(value)")
        }
        let context = t.context(ambient: ["CLAUDE_JOB_DIR": values[0]])
        let launcher = try pick(context, PickRequest(caller: .launcher, exclude: ["spare", "tok"]))
        #expect(launcher.label == "main")
    }

    // MARK: Unreadable sessions folder

    func unreadable(_ url: URL) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path)) == nil
    }

    @Test func anUnreadableSessionsFolderSkipsLoginAndTokenAndKeepsFolderAccounts() throws {
        let (t, _) = try setUp(extra: [login(), token()], settings: nil)
        defer { withExtendedLifetime(t) {} }
        _ = try t.makeTokenFile(label: "tok", secret: Canaries.oauthRealShape())
        let own = t.home.appendingPathComponent(".claude/sessions")
        let theirs = try accountFolder(t.context).appendingPathComponent("sessions")
        for folder in [own, theirs] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try "{}".write(
            to: own.appendingPathComponent("4242.json"), atomically: true, encoding: .utf8)
        _ = try link(t.context)
        defer {
            chmod(own.path, 0o700)
            chmod(theirs.path, 0o700)
        }
        let chat = t.context(ambient: ["CLAUDE_CODE_CHILD_SESSION": "1", "CLAUDE_PID": "4242"])
        let notConfirmed = "chat folder not confirmed default"

        func expectSkipped(_ note: String) throws {
            #expect(SessionFolder.prefixlessReason(context: chat) == notConfirmed, "\(note)")
            let result = try pick(chat)
            #expect(result.label == "spare", "\(note)")
            #expect((result.launchPrefix ?? "").hasPrefix("CLAUDE_CONFIG_DIR='"), "\(note)")
            let reasons = Dictionary(
                uniqueKeysWithValues: result.candidates.map { ($0.label, $0.reason) })
            #expect(reasons["main"] == notConfirmed, "\(note)")
            #expect(reasons["tok"] == notConfirmed, "\(note)")
        }

        // Readable, the entry is found by name and the chat is confirmed.
        #expect(!unreadable(own) && !unreadable(theirs))
        #expect(SessionFolder.prefixlessReason(context: chat) == nil)

        // The default folder's sessions cannot be listed.
        chmod(own.path, 0o000)
        #expect(unreadable(own))
        try expectSkipped("default folder sessions")
        chmod(own.path, 0o700)
        #expect(SessionFolder.prefixlessReason(context: chat) == nil)

        // A configured folder account's sessions cannot be listed.
        chmod(theirs.path, 0o000)
        #expect(unreadable(theirs))
        try expectSkipped("folder account sessions")
        chmod(theirs.path, 0o700)
        #expect(SessionFolder.prefixlessReason(context: chat) == nil)
    }

    // MARK: The terminal check

    @Test func theTerminalCheckAsksTheInjectedClosureAndRefusesBeforeAnyPrompt() {
        #expect(throws: Never.self) { try ConsentTerminal.require(isTerminal: { true }) }
        do {
            try ConsentTerminal.require(isTerminal: { false })
            Issue.record("a missing terminal passed")
        } catch let error as ToolError {
            #expect(error.message == Messages.terminalRequired)
        } catch {
            Issue.record("unexpected error")
        }
        #expect(Messages.terminalRequired.contains("own terminal"))
    }

    // MARK: A change made from a plan the record has moved past

    func recordBytes(_ context: ToolContext) throws -> Data {
        try Data(contentsOf: context.dataRoot.appendingPathComponent("links.json"))
    }

    func plan(_ context: ToolContext, repair: Bool = false) throws -> LinkPlan {
        try Linker.plan(
            context: context, config: try ConfigStore(context: context).loadRequired(),
            label: "spare", repair: repair)
    }

    @Test func aPlanTheRecordMovedPastIsRefusedAndWritesNothing() throws {
        let (t, context) = try setUp()
        defer { withExtendedLifetime(t) {} }
        let first = try plan(context)
        let second = try plan(context)
        let applied = try Linker.apply(context: context, plan: first)
        #expect(applied.created > 0)
        let bytes = try recordBytes(context)
        let links = try FileManager.default.contentsOfDirectory(atPath: accountFolder(context).path)
        #expect(throws: ToolError.self) { _ = try Linker.apply(context: context, plan: second) }
        #expect(try recordBytes(context) == bytes)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: accountFolder(context).path)
                == links)
        #expect(HookRecord(context: context).isLinked("spare"))
    }

    @Test func unlinkingFromAListTheRecordMovedPastRemovesNothing() throws {
        let (t, context) = try setUp()
        defer { withExtendedLifetime(t) {} }
        let hooks = HookRecord(context: context)
        let shown = hooks.linkState(for: "spare")
        _ = try link(context)
        let bytes = try recordBytes(context)
        #expect(throws: ToolError.self) {
            _ = try Linker.removeLinks(context: context, label: "spare", expecting: shown)
        }
        #expect(try recordBytes(context) == bytes)
        #expect(try destination(context, "CLAUDE.md") != nil)
        let current = hooks.linkState(for: "spare")
        let result = try Linker.removeLinks(context: context, label: "spare", expecting: current)
        #expect(result.removed > 0)
        #expect(try destination(context, "CLAUDE.md") == nil)
    }

    @Test func aHookRecordTheRecordMovedPastIsNotOverwritten() throws {
        let (t, context) = try setUp()
        defer { withExtendedLifetime(t) {} }
        let hooks = HookRecord(context: context)
        let seen = hooks.snapshot()
        let facts = try hooks.readSettings()
        try hooks.record(.empty)
        let bytes = try recordBytes(context)
        #expect(throws: ToolError.self) { try hooks.record(facts, ifRecordIs: seen) }
        #expect(try recordBytes(context) == bytes)
        try hooks.record(facts, ifRecordIs: hooks.snapshot())
        #expect(hooks.recorded()?.hooks == facts.hooks)
    }

    @Test func twoLinkRunsForOneLabelApplyOnceAndLoseNoEntry() throws {
        for round in 0..<5 {
            let (t, context) = try setUp()
            defer { withExtendedLifetime(t) {} }
            let first = try plan(context)
            let second = try plan(context)
            let gate = DispatchSemaphore(value: 0)
            let done = DispatchGroup()
            let tally = Tally()
            for stalePlan in [first, second] {
                done.enter()
                onOwnThread {
                    gate.wait()
                    let ok = (try? Linker.apply(context: context, plan: stalePlan)) != nil
                    tally.add(ok)
                    done.leave()
                }
            }
            gate.signal()
            gate.signal()
            #expect(done.wait(timeout: .now() + 60) == .success, "round \(round)")
            #expect(tally.wins == 1, "round \(round)")
            let hooks = HookRecord(context: context)
            let names = Set(
                hooks.entries(for: "spare").map { URL(fileURLWithPath: $0.path).lastPathComponent })
            #expect(names == ["CLAUDE.md", "settings.json"], "round \(round)")
            #expect(hooks.isLinked("spare"), "round \(round)")
            #expect(try destination(context, "CLAUDE.md") != nil)
        }
    }
}
