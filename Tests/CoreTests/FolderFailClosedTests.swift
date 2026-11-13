import Foundation
import Testing

@testable import Core

/// Check 4, ownership, unlinked sources and the links record, in a temporary home against the
/// fake `claude`.
@Suite struct FolderFailClosedTests {
    let base = FolderAccountsTests()

    func codes(_ context: ToolContext, label: String = "spare") throws -> [StateCode] {
        let account = try #require(try ConfigStore(context: context).loadRequired().account(label))
        return Verifier.failures(
            context: context, account: account, runner: ClaudeRunner(context: context),
            settingsIssue: nil, now: Date(), stopAtFirst: false
        ).failures.map(\.code)
    }

    // MARK: Check 4

    @Test func aReportedFolderThatIsNotThisOneOrCannotBePinnedFails() throws {
        let folder = URL(fileURLWithPath: "/h/.agent-balancer/accounts/spare-account/.claude")
        let marker = Scrubber.redacted
        let ok = [
            "/h/.agent-balancer/accounts/spare-account/.claude",
            "/h/.agent-balancer/accounts/\(marker)/.claude",
            "/h/.agent-balancer/accounts/sp\(marker)/.claude",
            "/\(marker)/.agent-balancer/accounts/spare-account/.claude",
        ]
        for text in ok { #expect(FolderPaths.sameFolder(text, folder), "\(text)") }
        let refused = [
            "",
            "relative/accounts/spare-account/.claude",
            "\(marker)",
            "/\(marker)",
            "/\(marker)/\(marker)/\(marker)/\(marker)/\(marker)",
            // A marker never crosses a slash.
            "/h/\(marker)/.claude",
            "/h/.agent-balancer\(marker)",
            "/\(marker)/.claude",
            "\(marker)/accounts/spare-account/.claude",
            // A segment without a marker matches literally.
            "/h/.agent-balancer/accounts/other/.claude",
            "/h/.agent-balancer/accounts/\(marker)/.other",
            "/h/.agent-balancer/accounts/\(marker)/\(marker)",
            "/h/.agent-balancer/accounts/spare-account/.claude/\(marker)",
            "/h/.agent-balancer/accounts//.claude",
            "/h/.agent-balancer/accounts/\(marker)/.claude/.claude",
            "/\(marker)/\(marker)/\(marker)/\(marker)/.claude",
            "/h/.agent-balancer/accounts/\(marker)/../.claude",
            "/h/.agent-balancer/accounts/spare\(marker)\(marker)/.claude",
        ]
        for text in refused { #expect(!FolderPaths.sameFolder(text, folder), "\(text)") }
        let short = URL(fileURLWithPath: "/accounts/spare-account/.claude")
        #expect(!FolderPaths.sameFolder("x\(marker)/accounts/spare/.claude", short))
    }

    @Test func aMarkerInTheLabelSegmentNeedsALabelThatLongRedactionCouldHaveProducedIt() throws {
        let marker = Scrubber.redacted
        let shortest = Scrubber.shortestRedactedRun
        func folder(_ label: String) -> URL {
            URL(fileURLWithPath: "/h/.agent-balancer/accounts/\(label)/.claude")
        }
        let tooShort = String(repeating: "a", count: shortest - 1)
        let atLimit = String(repeating: "a", count: shortest)
        let path = "/h/.agent-balancer/accounts/\(marker)/.claude"
        #expect(!FolderPaths.sameFolder(path, folder(tooShort)))
        #expect(!FolderPaths.sameFolder(path, folder("work")))
        #expect(FolderPaths.sameFolder(path, folder(atLimit)))
        #expect(FolderPaths.sameFolder(path, folder("sk-ant-x")))
    }

    @Test func aHashInvalidDefaultRecordStopsEverySaveButTheAcceptReplacesIt() throws {
        let t = try TestHome()
        let context = t.context
        let hooks = HookRecord(context: context)
        let url = context.dataRoot.appendingPathComponent("links.json")
        let good = String(repeating: "c", count: 64)
        for (fingerprint, commandHash) in [("bad", good), (good, "bad")] {
            let json =
                #"{"schemaVersion":1,"defaultFolder":{"disableAllHooks":false,"hooks":[{"event":"Stop","matcher":"","commandHash":"\#(commandHash)","fingerprint":"\#(fingerprint)"}]},"links":[{"path":"\#(context.dataRoot.path)/accounts/spare/.claude/CLAUDE.md","target":"/x"}],"linkedLabels":["spare"]}"#
            let bytes = try writeRecord(context, json)
            #expect(hooks.entries(for: "spare").isEmpty)
            let state = hooks.linkState(for: "spare")
            #expect(throws: ToolError.self) {
                try hooks.changeLinks(label: "spare", expecting: state) { _ in }
            }
            #expect(throws: ToolError.self) {
                try hooks.saveLinks(label: "spare", entries: [], linked: false)
            }
            #expect(throws: ToolError.self) { try hooks.forgetAllLinks() }
            #expect(try Data(contentsOf: url) == bytes)
            try hooks.record(.empty)
            #expect(hooks.isLinked("spare"))
            #expect(hooks.entries(for: "spare").count == 1)
        }
    }

    @Test func aRecordOfAnotherSchemaVersionStopsEverySave() throws {
        let t = try TestHome()
        let context = t.context
        let hooks = HookRecord(context: context)
        let url = context.dataRoot.appendingPathComponent("links.json")
        let bytes = try writeRecord(
            context, #"{"schemaVersion":2,"links":[],"linkedLabels":["spare"]}"#)
        #expect(throws: ToolError.self) {
            try hooks.saveLinks(label: "other", entries: [], linked: true)
        }
        #expect(throws: ToolError.self) { try hooks.record(.empty) }
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func aMissingEmptyOrOddConfigDirectoryFailsEveryCheck() throws {
        let (t, context) = try base.setUp()
        defer { withExtendedLifetime(t) {} }
        _ = try base.link(context)
        try base.fakeAuth(t, context: context, label: "spare")
        #expect(try codes(context).isEmpty)
        let bodies = [
            #"{"loggedIn":true,"email":"acct@example.com","planTier":"max_20x"}"#,
            #"{"loggedIn":true,"email":"acct@example.com","planTier":"max_20x","configDirectory":""}"#,
            #"{"loggedIn":true,"email":"acct@example.com","planTier":"max_20x","configDirectory":7}"#,
            #"{"loggedIn":true,"email":"acct@example.com","planTier":"max_20x","configDirectory":null}"#,
            #"{"loggedIn":true,"email":"acct@example.com","planTier":"max_20x","configDirectory":"accounts/spare/.claude"}"#,
            #"{"loggedIn":true,"email":"acct@example.com","planTier":"max_20x","configDirectory":"[redacted]"}"#,
            #"{"loggedIn":true,"email":"acct@example.com","planTier":"max_20x","configDirectory":"/[redacted]/[redacted]"}"#,
        ]
        for body in bodies {
            try t.fake("auth.json", body)
            #expect(try codes(context) == [.checkFailed], "\(body)")
            let result = try base.pick(context)
            #expect(result.label == nil, "\(body)")
            #expect(throws: ToolError.self, "\(body)") {
                _ = try PickService(context: context).prepareRun(
                    label: "spare", arguments: [], printOnly: true)
            }
        }
    }

    @Test func aFolderSignInReadingTheRedactedLabelStillPasses() throws {
        // Only a label of 7 or more characters can come back redacted.
        let label = "spare-account"
        let (t, context) = try base.setUp(folders: [label])
        defer { withExtendedLifetime(t) {} }
        _ = try base.link(context, label)
        let folder = try base.accountFolder(context, label).path
        let shown = folder.replacingOccurrences(
            of: "/\(label)/", with: "/\(Scrubber.redacted)/")
        try base.fakeAuth(t, context: context, label: label, folder: shown)
        #expect(try codes(context, label: label).isEmpty)
        let wrong = folder.replacingOccurrences(
            of: "/accounts/\(label)/", with: "/\(Scrubber.redacted)/")
        try base.fakeAuth(t, context: context, label: label, folder: wrong)
        #expect(try codes(context, label: label) == [.checkFailed])
    }

    // MARK: Ownership and the folder rules

    @Test func theValidatorRefusesAFolderTheUserDoesNotOwn() throws {
        let (t, context) = try base.setUp()
        defer { withExtendedLifetime(t) {} }
        let config = try ConfigStore(context: context).loadRequired()
        try ConfigValidator.validate(config, context: context)
        let foreign = ToolContext(home: t.home, ambient: [:], ownerId: getuid() &+ 1)
        #expect(throws: ToolError.self) { try ConfigValidator.validate(config, context: foreign) }
        let before = t.home.appendingPathComponent(".agent-balancer/config.json")
        let bytes = try Data(contentsOf: before)
        #expect(throws: ToolError.self) { try ConfigStore(context: foreign).save(config) }
        #expect(try Data(contentsOf: before) == bytes)
    }

    @Test func theValidatorRefusesAFolderThatIsALinkOrWider() throws {
        let (t, context) = try base.setUp()
        defer { withExtendedLifetime(t) {} }
        let config = try ConfigStore(context: context).loadRequired()
        let folder = try base.accountFolder(context)
        chmod(folder.path, 0o755)
        #expect(throws: ToolError.self) { try ConfigValidator.validate(config, context: context) }
        chmod(folder.path, 0o700)
        try ConfigValidator.validate(config, context: context)
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createSymbolicLink(
            at: folder, withDestinationURL: t.home.appendingPathComponent("elsewhere"))
        #expect(throws: ToolError.self) { try ConfigValidator.validate(config, context: context) }
    }

    @Test func theValidatorRefusesAFolderPathThatIsNotPlain() throws {
        let t = try TestHome()
        let config = Config(accounts: [
            Account(label: "spare", kind: Kind.folder, role: Role.pool)
        ])
        let spaced = t.home.appendingPathComponent("a b")
        try FileManager.default.createDirectory(at: spaced, withIntermediateDirectories: true)
        let odd = ToolContext(home: spaced, ambient: [:])
        #expect(throws: ToolError.self) { try ConfigValidator.validate(config, context: odd) }
        let dots = ToolContext(
            home: URL(fileURLWithPath: t.home.path + "/x/../y"), ambient: [:])
        #expect(throws: ToolError.self) { try ConfigValidator.validate(config, context: dots) }
        try ConfigValidator.validate(config, context: t.context)
    }

    @Test func verifyFailsOnAForeignOwnedLinkTarget() throws {
        let (t, context) = try base.setUp()
        defer { withExtendedLifetime(t) {} }
        _ = try base.link(context)
        #expect(Verifier.linkFacts(context: context, label: "spare").verdict == .ok)
        let foreign = ToolContext(home: t.home, ambient: [:], ownerId: getuid() &+ 1)
        guard
            case .broken(let detail) = Verifier.linkFacts(context: foreign, label: "spare").verdict
        else {
            Issue.record("a foreign-owned target passed")
            return
        }
        #expect(detail.contains("not yours"))
    }

    // MARK: A source that appears after link

    @Test func aSourceThatAppearsAfterLinkFailsVerifyAndRepairClearsIt() throws {
        let (t, context) = try base.setUp(settings: nil)
        defer { withExtendedLifetime(t) {} }
        _ = try base.link(context)
        #expect(Verifier.linkFacts(context: context, label: "spare").verdict == .ok)
        let skills = t.home.appendingPathComponent(".claude/skills")
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
        guard
            case .broken(let detail) = Verifier.linkFacts(context: context, label: "spare").verdict
        else {
            Issue.record("a new unlinked source passed")
            return
        }
        #expect(detail.contains("skills"))
        let account = try #require(
            try ConfigStore(context: context).loadRequired().account("spare"))
        let out = Verifier.failures(
            context: context, account: account, runner: ClaudeRunner(context: context),
            settingsIssue: nil, now: Date(), stopAtFirst: true)
        #expect(out.failures.first?.text.contains("link --repair spare") == true)
        #expect(try base.pick(context).label == nil)
        let applied = try base.link(context, repair: true)
        #expect(applied.created == 1)
        #expect(Verifier.linkFacts(context: context, label: "spare").verdict == .ok)
        #expect(try base.pick(context).label == "spare")
    }

    @Test func aFolderLinkedWhenEverySourceWasMissingNoticesTheFirstOneThatAppears() throws {
        let (t, context) = try base.setUp(settings: nil)
        defer { withExtendedLifetime(t) {} }
        try FileManager.default.removeItem(at: t.home.appendingPathComponent(".claude/CLAUDE.md"))
        _ = try base.link(context)
        #expect(HookRecord(context: context).isLinked("spare"))
        #expect(Verifier.linkFacts(context: context, label: "spare").verdict == .ok)
        try "notes".write(
            to: t.home.appendingPathComponent(".claude/CLAUDE.md"), atomically: true,
            encoding: .utf8)
        guard case .broken = Verifier.linkFacts(context: context, label: "spare").verdict else {
            Issue.record("a source that appeared after an empty link passed")
            return
        }
        _ = try base.link(context, repair: true)
        #expect(Verifier.linkFacts(context: context, label: "spare").verdict == .ok)
        #expect(try base.destination(context, "CLAUDE.md") != nil)
    }

    // MARK: The links record

    func labels(_ context: ToolContext) throws -> [String] {
        let data = try Data(contentsOf: context.dataRoot.appendingPathComponent("links.json"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return object["linkedLabels"] as? [String] ?? []
    }

    @Test func twoWritersOfTheLinksRecordLoseNoRecord() throws {
        let t = try TestHome()
        let context = t.context
        try HookRecord(context: context).record(.empty)
        let group = DispatchGroup()
        for prefix in ["a", "b"] {
            group.enter()
            onOwnThread {
                let hooks = HookRecord(context: context)
                for i in 0..<30 {
                    try? hooks.saveLinks(label: "\(prefix)\(i)", entries: [], linked: true)
                }
                group.leave()
            }
        }
        #expect(group.wait(timeout: .now() + 60) == .success)
        #expect(try labels(context).count == 60)
    }

    func writeRecord(_ context: ToolContext, _ json: String) throws -> Data {
        try FileManager.default.createDirectory(
            at: context.dataRoot, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let url = context.dataRoot.appendingPathComponent("links.json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, 0o600)
        return try Data(contentsOf: url)
    }

    @Test func aSaveRefusesAndWritesNothingWhenAPartOfTheRecordCannotBeDecoded() throws {
        let t = try TestHome()
        let context = t.context
        let hooks = HookRecord(context: context)
        let url = context.dataRoot.appendingPathComponent("links.json")
        let badDefault =
            #"{"schemaVersion":1,"defaultFolder":{"disableAllHooks":"yes","hooks":7},"links":[],"linkedLabels":["spare"]}"#
        var bytes = try writeRecord(context, badDefault)
        #expect(throws: ToolError.self) {
            try hooks.saveLinks(label: "other", entries: [], linked: true)
        }
        #expect(try Data(contentsOf: url) == bytes)
        let badList =
            #"{"schemaVersion":1,"links":[{"path":1}],"linkedLabels":["spare"]}"#
        bytes = try writeRecord(context, badList)
        #expect(throws: ToolError.self) {
            try hooks.saveLinks(label: "other", entries: [], linked: true)
        }
        #expect(throws: ToolError.self) { try hooks.record(.empty) }
        #expect(throws: ToolError.self) { try hooks.forgetAllLinks() }
        #expect(try Data(contentsOf: url) == bytes)
        // A new default folder record replaces an unreadable one and keeps the rest.
        _ = try writeRecord(context, badDefault)
        try hooks.record(.empty)
        #expect(hooks.isLinked("spare"))
    }

    @Test func forgettingEveryLinkKeepsTheDefaultFolderRecord() throws {
        let t = try TestHome()
        let context = t.context
        let hooks = HookRecord(context: context)
        try hooks.record(.empty)
        try hooks.saveLinks(label: "spare", entries: [], linked: true)
        #expect(hooks.isLinked("spare"))
        try hooks.forgetAllLinks()
        #expect(!hooks.isLinked("spare"))
        #expect(hooks.recorded() != nil)
    }

    // MARK: Stale readings

    @Test func aStaleReadingFailsPickForAFolder() throws {
        let (t, context) = try base.setUp()
        defer { withExtendedLifetime(t) {} }
        _ = try base.link(context)
        let old = Date().addingTimeInterval(-7_200)
        try ReadingStore(context: context).save(
            Reading(
                readAt: old,
                windows: [
                    WindowName.sevenDay: WindowReading(
                        usedPercent: 10, resetsAt: Date().addingTimeInterval(86_400 * 3),
                        readAt: old)
                ]), label: "spare")
        try t.fake("probe.jsonl", "")
        try t.fake("probe.exit", "1")
        let result = try base.pick(context)
        #expect(result.label == nil)
        #expect(result.candidates.allSatisfy { $0.reason == "stale reading, refresh failed" })
    }
}
