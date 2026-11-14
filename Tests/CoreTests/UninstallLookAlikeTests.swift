import Foundation
import Testing

@testable import Core

/// Names shaped like the ones the tool writes but spelled with characters it never writes, such as
/// fullwidth digits and letters: in every folder `uninstall` empties each one stays and is counted,
/// and the probe cleanup refuses a probe folder spelled that way instead of deleting it.
extension UninstallTests {
    /// `text` with each ASCII character turned into its fullwidth form, which looks the same.
    func wide(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            out.unicodeScalars.append(Unicode.Scalar(scalar.value + 0xFEE0) ?? scalar)
        }
        return out
    }

    /// Plants each name as a file through the tool's writer, checks that the listing counts none
    /// of them as the tool's, runs `uninstall`, and checks that each stays and is counted once.
    func lookAlikesStayAndAreCounted(
        _ planted: [(folders: [String], name: String)],
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let (t, _) = try setUp()
        let before = try Uninstall.plan(context: t.context, leaseMinutes: 30, snapshot: .empty)
        let urls = try planted.map { try plant(t, $0.folders, $0.name) }
        let after = try Uninstall.plan(context: t.context, leaseMinutes: 30, snapshot: .empty)
        #expect(after == before, sourceLocation: sourceLocation)
        let done = try run(t)
        #expect(done.entriesLeft == planted.count, sourceLocation: sourceLocation)
        for url in urls {
            #expect(exists(url), "\(url.lastPathComponent)", sourceLocation: sourceLocation)
        }
        #expect(!done.dataFolderRemoved, sourceLocation: sourceLocation)
    }

    @Test func aProbeFolderSpelledInLookAlikeHexStaysAndIsCounted() throws {
        try lookAlikesStayAndAreCounted([
            (Layout.probeFolders + ["p-" + wide("0123456789abcdef")], "notes.txt"),
            (Layout.probeFolders + ["p-0123456789abcde" + wide("f")], "notes.txt"),
        ])
    }

    @Test func theProbeCleanupRefusesALookAlikeProbeFolderAndKeepsWhatIsInIt() throws {
        let t = try TestHome()
        let folder = "p-" + wide("0123456789abcdef")
        let note = try plant(t, Layout.probeFolders + [folder], "notes.txt")
        // Old enough that the cleanup would remove it if it took the folder for a probe's.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3600)],
            ofItemAtPath: note.deletingLastPathComponent().path)
        let writer = NoFollowWriter(root: t.context.dataRoot)
        #expect(throws: ToolError.self) {
            _ = try writer.makeScratchFolder(
                parent: Layout.probeFolders, prefix: Layout.probeFolderPrefix, staleAfter: 60)
        }
        #expect(text(note) == "{}")
    }

    @Test func aTemporaryNameInLookAlikeHexStaysAndIsCountedInEveryFolder() throws {
        let name = NoFollowWriter.temporaryPrefix + wide("0123456789abcdef")
        let folders: [[String]] = [
            [], Layout.stateFolders, Layout.readingsFolders, ReadingHistory.folders,
            Layout.backupsFolders, TokenPaths.folders, LaunchFiles.folders(label: "pool-a"),
        ]
        try lookAlikesStayAndAreCounted(folders.map { (folders: $0, name: name) })
    }

    @Test func aLockNameWithALookAlikeLabelOrLetterStaysAndIsCounted() throws {
        try lookAlikesStayAndAreCounted([
            (Layout.locksFolders, "probe-" + wide("pool") + "-" + wide("a") + ".lock"),
            (Layout.locksFolders, wide("pick") + ".lock"),
            (Layout.locksFolders, "links." + wide("lock")),
        ])
    }

    @Test func aBackupNameInLookAlikeDigitsStaysAndIsCounted() throws {
        try lookAlikesStayAndAreCounted([
            (Layout.backupsFolders, "config-" + wide("2026") + "-11-13.json"),
            (Layout.backupsFolders, "config-2026-11-13-" + wide("2") + ".json"),
        ])
    }

    @Test func aSetAsideEventsNameInLookAlikeDigitsStaysAndIsCounted() throws {
        try lookAlikesStayAndAreCounted([
            (Layout.stateFolders, "events-damaged-" + wide("1763000000") + "-abcd.jsonl"),
            (Layout.stateFolders, "events-damaged-1763000000-" + wide("abcd") + ".jsonl"),
        ])
    }

    @Test func aLabelNameInLookAlikeLettersStaysAndIsCountedInEveryFolder() throws {
        let label = wide("pool") + "-" + wide("a")
        try lookAlikesStayAndAreCounted([
            (Layout.readingsFolders, label + ".json"),
            (ReadingHistory.folders, label + ".jsonl"),
            (TokenPaths.folders, label + ".json"),
            (LaunchFiles.folders(label: label), "l-0a0b0c0d.json"),
            (LaunchFiles.folders(label: "pool-a"), "l-" + wide("0a0b0c0d") + ".json"),
        ])
    }

    @Test func aFixedNameWithALookAlikeLetterStaysAndIsCounted() throws {
        try lookAlikesStayAndAreCounted([
            (Layout.stateFolders, wide("status") + ".json"),
            (Layout.stateFolders, "leases.js\u{043E}n"),
            (Layout.logsFolders, "agent-balancer." + wide("log")),
            ([], wide("config") + ".json"),
            ([], "links." + wide("json")),
        ])
    }
}
