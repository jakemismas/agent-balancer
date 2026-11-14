import Foundation
import Testing

@testable import Core

/// The session folder rule's literal checks: a job folder must be exactly `<folder>/jobs/<one
/// segment>`, and a chat is confirmed only by an all-digit `CLAUDE_PID` found by name.
extension FolderAccountsTests {
    static let notDefault = "ambient session folder not default"
    static let notConfirmed = "chat folder not confirmed default"

    @Test func aJobFolderUnderTheDefaultFolderButOutsideJobsIsNotTheDefaultFolder() throws {
        let home = try TestHome()
        let base = home.home.path + "/.claude"
        let config = Config(accounts: [])
        for value in [
            base + "/projects/abc", base + "/sessions/abc", base + "/job/abc", base + "/jobsx/abc",
            base + "/Jobs/abc",
        ] {
            let context = home.context(ambient: ["CLAUDE_JOB_DIR": value])
            #expect(SessionFolder.prefixlessReason(context: context) == Self.notDefault, "\(value)")
            #expect(SessionFolder.describe(context: context, config: config) == "not confirmed")
        }
        let inside = home.context(ambient: ["CLAUDE_JOB_DIR": base + "/jobs/abc"])
        #expect(SessionFolder.prefixlessReason(context: inside) == nil)
        #expect(SessionFolder.describe(context: inside, config: config) == "default")
    }

    @Test func aJobsDotOrDotDotPathIsNotTheDefaultFolder() throws {
        let home = try TestHome()
        let base = home.home.path + "/.claude"
        let config = Config(accounts: [])
        for value in [
            base + "/jobs/..", base + "/jobs/.", base + "/./jobs/abc", base + "/jobs/../jobs",
            base + "/jobs/abc/..", base + "/jobs//abc",
        ] {
            let context = home.context(ambient: ["CLAUDE_JOB_DIR": value])
            #expect(SessionFolder.prefixlessReason(context: context) == Self.notDefault, "\(value)")
            #expect(SessionFolder.describe(context: context, config: config) == "not confirmed")
        }
    }

    @Test func aNonNumericPidIsNeverConfirmedEvenWithASessionEntryOfThatName() throws {
        let (t, _) = try setUp(extra: [login()], settings: nil)
        defer { withExtendedLifetime(t) {} }
        let sessions = t.home.appendingPathComponent(".claude/sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let config = try ConfigStore(context: t.context).loadRequired()
        func chat(_ pid: String) -> ToolContext {
            t.context(ambient: ["CLAUDE_CODE_CHILD_SESSION": "1", "CLAUDE_PID": pid])
        }
        // Each pid has its own entry in the default folder's sessions and in no folder account's.
        for pid in ["4242", "12a", "4x2", "\u{0664}\u{0662}", "+42", "-42", " 42", "4 2", ""] {
            try "{}".write(
                to: sessions.appendingPathComponent(pid + ".json"), atomically: true,
                encoding: .utf8)
        }
        #expect(SessionFolder.prefixlessReason(context: chat("4242")) == nil)
        #expect(SessionFolder.describe(context: chat("4242"), config: config) == "default")
        for pid in ["12a", "4x2", "\u{0664}\u{0662}", "+42", "-42", " 42", "4 2", ""] {
            #expect(
                SessionFolder.prefixlessReason(context: chat(pid)) == Self.notConfirmed, "\(pid)")
            #expect(SessionFolder.describe(context: chat(pid), config: config) == "not confirmed")
        }
    }

    @Test func doctorNamesAFolderAccountOnlyForItsExactJobFolder() throws {
        let (t, context) = try setUp()
        defer { withExtendedLifetime(t) {} }
        let config = try ConfigStore(context: context).loadRequired()
        let own = try accountFolder(context).path
        func described(_ value: String) -> String {
            SessionFolder.describe(
                context: t.context(ambient: ["CLAUDE_JOB_DIR": value]), config: config)
        }
        #expect(described(own + "/jobs/abc") == "folder spare")
        for value in [
            own + "/jobs/..", own + "/jobs/.", own + "/jobs/../../x", own + "/jobs/./abc",
            own + "/jobs/abc/..", own + "/jobs/../jobs/abc", own + "/jobs/a/b", own + "/jobs/",
            own + "/jobs", own + "/x/abc", own + "/jobs//abc",
        ] {
            #expect(described(value) == "not confirmed", "\(value)")
        }
    }
}
