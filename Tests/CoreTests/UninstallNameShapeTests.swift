import Foundation
import Testing

@testable import Core

/// Names in ASCII that only look like the ones the tool writes (a number, a date, a length or a
/// letter case its writer never gives) stay in every folder `uninstall`, the probe cleanup and
/// launch file upkeep look at, and are counted once; every name the writers do give passes its
/// rule. An entry named like a token file or a label's launch folder in other letter case may
/// hold a token and is never opened, and a temporary file a save may still be using stays.
extension UninstallTests {
    /// Sets the access and modification times of each file to `date`.
    func setTimes(_ urls: [URL], to date: Date) {
        let second = Int(date.timeIntervalSince1970)
        let times: [timeval] = [
            timeval(tv_sec: second, tv_usec: 0), timeval(tv_sec: second, tv_usec: 0),
        ]
        for url in urls { #expect(utimes(url.path, times) == 0, "\(url.lastPathComponent)") }
    }

    // MARK: Each rule against its writer

    @Test func aBackupNameTheWriterNeverGivesStaysAndIsCounted() throws {
        let names = [
            // A number the writer never gives: it starts at 2, with no sign or leading zero.
            "config-2026-11-13-1.json", "config-2026-11-13-01.json", "config-2026-11-13-0.json",
            "config-2026-11-13-02.json", "config-2026-11-14--2.json", "config-2026-11-14-+2.json",
            "config-2026-11-14-a.json", "config-2026-11-14-\u{0662}.json",
            // A day that is not a real date.
            "config-0000-00-00.json", "config-2026-13-45.json", "config-2026-02-31.json",
            "config-2026-02-29.json", "config-2026-04-31.json",
            // Other case, and one character too few or too many.
            "Config-2026-11-15.json", "config-2026-11-16.JSON", "config-2026-1-17.json",
            "config-2026-11-1.json", "config-26-11-18.json", "config-2026-11-199.json",
            "config-20261-11-19.json", "config-2026-011-19.json", "config-2026-11-20.jsonx",
        ]
        try lookAlikesStayAndAreCounted(names.map { (folders: Layout.backupsFolders, name: $0) })
    }

    @Test func aSetAsideNameTheWriterNeverGivesStaysAndIsCounted() throws {
        let names = [
            // A second the writer never gives: no leading zero, no `+`, no `-0`, ASCII digits.
            "events-damaged-0001763000000-abcd.jsonl", "events-damaged--0-abcd.jsonl",
            "events-damaged-007-abcd.jsonl", "events-damaged-0007-abcd.jsonl",
            "events-damaged-+5-abcd.jsonl", "events-damaged---5-abcd.jsonl",
            "events-damaged-\u{0661}\u{0662}-abcd.jsonl", "events-damaged- 5-abcd.jsonl",
            "events-damaged--abcd.jsonl",
            // Random bytes the writer never gives: upper case, not hex, too few or too many.
            "events-damaged-1763000001-ABCD.jsonl", "events-damaged-123-wxyz.jsonl",
            "events-damaged-1763000002-abc.jsonl", "events-damaged-1763000003-abcde.jsonl",
            "events-damaged-1763000008-abcdef.jsonl", "events-damaged-1763000004abcd.jsonl",
            // Other case, and another suffix.
            "Events-damaged-1763000005-abcd.jsonl", "events-damaged-1763000006-abcd.json",
            "events-damaged-1763000007-abcd.JSONL",
        ]
        try lookAlikesStayAndAreCounted(names.map { (folders: Layout.stateFolders, name: $0) })
    }

    @Test func aTemporaryNameTheWriterNeverGivesStaysAndIsCountedInEveryFolder() throws {
        let names = [
            ".tmp-0123456789ABCDEF", ".tmp-ghijklmnopqrstuv", ".tmp-0123456789abcdef0",
            ".tmp-0123456789abcde", ".TMP-fedcba9876543210", "tmp-0123456789abcdef",
            ".tmp_0123456789abcdef",
        ]
        let folders: [[String]] = [
            [], Layout.stateFolders, Layout.readingsFolders, ReadingHistory.folders,
            Layout.backupsFolders, TokenPaths.folders, LaunchFiles.folders(label: "pool-a"),
        ]
        var planted: [(folders: [String], name: String)] = []
        for folder in folders {
            for name in names { planted.append((folders: folder, name: name)) }
        }
        try lookAlikesStayAndAreCounted(planted)
    }

    @Test func aProbeFolderNameTheWriterNeverGivesStaysAndTheCleanupRefusesIt() throws {
        let folders = [
            "p-0123456789ABCDEF", "p-ghijklmnopqrstuv", "p-0123456789abcdef0", "p-0123456789abcde",
            "x-0123456789abcdef", "P-fedcba9876543210", "p_0123456789abcdef",
        ]
        try lookAlikesStayAndAreCounted(
            folders.map { (folders: Layout.probeFolders + [$0], name: "notes.txt") })
        // The probe cleanup applies the same rule: it refuses each one instead of removing it.
        for folder in folders {
            let t = try TestHome()
            let note = try plant(t, Layout.probeFolders + [folder], "notes.txt")
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-3600)],
                ofItemAtPath: note.deletingLastPathComponent().path)
            let writer = NoFollowWriter(root: t.context.dataRoot)
            #expect(throws: ToolError.self) {
                _ = try writer.makeScratchFolder(
                    parent: Layout.probeFolders, prefix: Layout.probeFolderPrefix, staleAfter: 60)
            }
            #expect(text(note) == "{}", "\(folder)")
        }
    }

    @Test func aLaunchFileNameTheWriterNeverGivesStaysAndUpkeepKeepsIt() throws {
        let names = [
            "l-0a0b0c0z.json", "l-0a0b0c0d.mine", "l-4A4B4C4D.json", "L-1a1b1c1d.json",
            "l-0a0b0c0d0.json", "l-0a0b0c0.json", "l-2a2b2c2d.JSON", "l_3a3b3c3d.json",
        ]
        let folders = LaunchFiles.folders(label: "pool-a")
        try lookAlikesStayAndAreCounted(names.map { (folders: folders, name: $0) })
        // Launch file upkeep applies the same rule: of files old enough to go, only its own go.
        let (t, launch) = try setUp()
        let planted = try names.map { try plant(t, folders, $0) }
        setTimes(planted + [launch], to: Date().addingTimeInterval(-3 * 3600))
        _ = Upkeep.run(
            context: t.context, snapshot: .empty, openLeases: [], leaseMinutes: 1, keepDays: 1,
            now: Date())
        #expect(!exists(launch))
        for url in planted { #expect(exists(url), "\(url.lastPathComponent)") }
    }

    @Test func aLabelNameTheWriterNeverGivesStaysAndIsCountedInEveryFolder() throws {
        let long = String(repeating: "a", count: 33)
        let launchFolders = ["pool_a", long, "-pool"].map { LaunchFiles.folders(label: $0) }
        var planted: [(folders: [String], name: String)] = [
            (Layout.readingsFolders, "pool_a.json"), (Layout.readingsFolders, "-pool.json"),
            (Layout.readingsFolders, long + ".json"), (Layout.readingsFolders, ".json"),
            (Layout.readingsFolders, "pool-a.JSON"),
            (ReadingHistory.folders, "pool_a.jsonl"), (ReadingHistory.folders, long + ".jsonl"),
            (ReadingHistory.folders, ".jsonl"), (ReadingHistory.folders, "Pool-a.jsonl"),
            (Layout.locksFolders, "probe-pool_a.lock"),
            (Layout.locksFolders, "probe-" + long + ".lock"),
            (Layout.locksFolders, "probe--x.lock"), (Layout.locksFolders, "Probe-pool-b.lock"),
            (Layout.locksFolders, "probe-pool-c.LOCK"),
            (TokenPaths.folders, "pool_a.json"), (TokenPaths.folders, long + ".json"),
            (TokenPaths.folders, ".json"), (TokenPaths.folders, "-pool.json"),
        ]
        planted += launchFolders.map { (folders: $0, name: "l-0a0b0c0d.json") }
        try lookAlikesStayAndAreCounted(planted)
        // Launch file upkeep never opens a folder whose name is not a label.
        let (t, _) = try setUp()
        let inside = try launchFolders.map { try plant(t, $0, "l-0a0b0c0d.json") }
        setTimes(inside, to: Date().addingTimeInterval(-3 * 3600))
        _ = Upkeep.run(
            context: t.context, snapshot: .empty, openLeases: [], leaseMinutes: 1, keepDays: 1,
            now: Date())
        for url in inside { #expect(exists(url), "\(url.deletingLastPathComponent().path)") }
    }

    @Test func aFixedNameTheWriterNeverGivesStaysAndIsCounted() throws {
        // Each in other case while the tool's own file is absent, or one character off. (A lease
        // file in other case is not one: the volume hands it to the lease reader by name.)
        try lookAlikesStayAndAreCounted([
            (Layout.stateFolders, "STATUS.JSON"), (Layout.stateFolders, "Current.json"),
            (Layout.stateFolders, "leases.jso"), (Layout.stateFolders, "picks.lo"),
            (Layout.stateFolders, "settings-seen.json~"), (Layout.stateFolders, "event.jsonl"),
            (Layout.logsFolders, "AGENT-BALANCER.LOG"), (Layout.logsFolders, "agent-balancer.log1"),
            (Layout.logsFolders, "agent-balancer.lo"),
            (Layout.locksFolders, "LINKS.LOCK"), (Layout.locksFolders, "History.lock"),
            (Layout.locksFolders, "pick.lock2"), (Layout.locksFolders, "links.loc"),
        ])
        // In the data folder, a file the volume takes for a folder of the tool's is counted
        // once, by that folder's step.
        try lookAlikesStayAndAreCounted([
            ([], "Logs"), ([], "BACKUPS"), ([], "Probe"), ([], "config.json.bak"),
            ([], "links.jso"), ([], "accounts2"),
        ])
    }

    @Test func everyNameTheBackupAndSetAsideWritersGivePassesTheirRules() throws {
        // Days of every month, leap days included, in time zones on both sides of UTC, and the
        // numbers a busy day reaches.
        var refused: [String] = []
        for zone in ["UTC", "Pacific/Kiritimati", "Pacific/Pago_Pago", "America/Sao_Paulo"] {
            let formatter = ConfigStore.backupDayFormatter()
            guard let timeZone = TimeZone(identifier: zone) else {
                Issue.record("No time zone \(zone)")
                continue
            }
            formatter.timeZone = timeZone
            var moment = Date(timeIntervalSince1970: 0)
            while moment.timeIntervalSince1970 < 4_200_000_000 {
                for number in [1, 2, 10] {
                    let name = ConfigStore.backupName(moment, number: number, formatter: formatter)
                    if !ConfigStore.isBackupName(name) { refused.append(name) }
                }
                moment = moment.addingTimeInterval(86_400 * 29 + 3_607)
            }
        }
        let leapDay = try #require(
            Calendar(identifier: .gregorian).date(
                from: DateComponents(
                    timeZone: TimeZone(identifier: "UTC"), year: 2024, month: 2, day: 29, hour: 12))
        )
        let utc = ConfigStore.backupDayFormatter()
        if let zone = TimeZone(identifier: "UTC") { utc.timeZone = zone }
        #expect(
            ConfigStore.backupName(leapDay, number: 1, formatter: utc) == "config-2024-02-29.json")
        #expect(ConfigStore.isBackupName("config-2024-02-29.json"))
        #expect(ConfigStore.isBackupName("config-2026-11-13-12.json"))
        // A second of any sign and size, and every byte value in each place of the random part.
        for stamp in [0, 1, 9, 10, -1, -10, 1_763_000_000, Int.max, Int.min] {
            let name = EventLog.setAsideName(stamp: stamp, tag: [0x0a, 0xff])
            if !EventLog.isSetAsideName(name) { refused.append(name) }
        }
        for value in 0...255 {
            let tags: [[UInt8]] = [[UInt8(value), 0x00], [0xff, UInt8(value)]]
            for tag in tags {
                let name = EventLog.setAsideName(stamp: 1_763_000_000, tag: tag)
                if !EventLog.isSetAsideName(name) { refused.append(name) }
            }
        }
        #expect(refused.isEmpty, "\(refused.prefix(5))")
        // Three backups the real writer makes on one day.
        let t = try TestHome()
        let store = ConfigStore(context: t.context)
        try store.save(Config(accounts: [token()]))
        let day = ConfigStore.backupDayFormatter().string(from: Date())
        for _ in 0..<3 { try store.save(Config(accounts: [token()]), backup: true) }
        let made = try NoFollowWriter(root: t.context.dataRoot).listNames(
            folders: Layout.backupsFolders)
        #expect(made.count == 3 && made.allSatisfy(ConfigStore.isBackupName), "\(made)")
        // The first of a day has no number and the next ones count up from 2, unless the day
        // turned while they were made.
        if ConfigStore.backupDayFormatter().string(from: Date()) == day {
            let names = ["config-\(day).json", "config-\(day)-2.json", "config-\(day)-3.json"]
            #expect(Set(made) == Set(names), "\(made)")
        }
    }

    // MARK: Other letter case in the token and launch folders

    @Test func anEntryNamedLikeATokenFileOrLaunchFolderInOtherCaseIsCountedAndNeverOpened() throws {
        let (t, launch) = try setUp()
        let before = try Uninstall.plan(context: t.context, leaseMinutes: 30, snapshot: .empty)
        // Each folds to the name of a token file or a label: the long s, the Kelvin sign and the
        // sharp s fold to `s`, `k` and `ss` as on a volume that ignores case, and a Mac OS
        // Extended volume ignores a zero-width joiner or a byte order mark in a name.
        let tokenNames = [
            "Pool-b.json", "POOL-C.JSON", "pool-d.JSON", "\u{017F}pare.json", "\u{212A}ey.json",
            "poo\u{00DF}.json", "pool-e\u{FEFF}.json",
        ]
        let labelNames = ["Pool-b", "POOL-C", "\u{017F}pare", "pool-f\u{200D}"]
        let files = try tokenNames.map { try plant(t, TokenPaths.folders, $0, "kept") }
        let inside = try labelNames.map {
            try plant(t, LaunchFiles.folders(label: $0), "l-0a0b0c0d.json", "kept")
        }
        // A name that differs only by an accent, which a volume that ignores case still tells
        // apart, is an entry left, not one of them.
        let accented = try [
            plant(t, TokenPaths.folders, "pool-\u{00E1}.json", "kept"),
            plant(t, LaunchFiles.folders(label: "pool-\u{00E1}"), "l-0a0b0c0d.json", "kept"),
        ]
        let count = tokenNames.count + labelNames.count
        let plan = try Uninstall.plan(context: t.context, leaseMinutes: 30, snapshot: .empty)
        #expect(plan.otherCaseEntries == count && !plan.isEmpty)
        var rest = plan
        rest.otherCaseEntries = before.otherCaseEntries
        #expect(rest == before)
        let done = try run(t)
        #expect(done.otherCaseEntries == count && done.entriesLeft == accented.count)
        #expect(done.tokenFiles == 1 && done.launchFiles == 1 && !exists(launch))
        for url in files + inside + accented {
            #expect(text(url) == "kept", "\(url.lastPathComponent)")
        }
        #expect(!done.dataFolderRemoved)
        let again = try Uninstall.plan(context: t.context, leaseMinutes: 30, snapshot: .empty)
        #expect(again.otherCaseEntries == count && !again.isEmpty)
    }

    @Test func aTokenOrLaunchFileSavedIntoAnEntryOfOtherCaseIsCountedAndKept() throws {
        let t = try TestHome()
        try ConfigStore(context: t.context).save(Config(accounts: [token()]))
        // Made before the tool's saves. On a volume that ignores case, the token file is renamed
        // onto the first and the launch file written into the second, each keeping its spelling.
        let tokenEntry = try plant(t, TokenPaths.folders, "Pool-a.json")
        let writer = NoFollowWriter(root: t.context.dataRoot)
        try writer.prepare(folders: [LaunchFiles.folder, "Pool-a"])
        let launchEntry = LaunchFiles.rootURL(context: t.context).appendingPathComponent("Pool-a")
        _ = try TokenAccounts.install(context: t.context, label: "pool-a", token: Canaries.oauth())
        _ = try launchFile(t, "l-0a0b0c0d")
        let plan = try Uninstall.plan(context: t.context, leaseMinutes: 30, snapshot: .empty)
        #expect(plan.otherCaseEntries == 2 && !plan.isEmpty)
        let done = try run(t)
        #expect(done.otherCaseEntries == 2)
        #expect(exists(tokenEntry) && exists(launchEntry))
        #expect(!done.dataFolderRemoved)
    }

    // MARK: A temporary file a save may still be using

    @Test func aStateTemporaryThatASaveMayStillUseStaysAndALaterRunDeletesIt() throws {
        let (t, _) = try setUp()
        let now = Date()
        var fresh: [URL] = []
        var ahead: [URL] = []
        var stopped: [URL] = []
        let saved: [[String]] = [
            Layout.stateFolders, Layout.readingsFolders, ReadingHistory.folders,
        ]
        for folders in saved {
            fresh.append(try plant(t, folders, ".tmp-00000000000000aa"))
            ahead.append(try plant(t, folders, ".tmp-00000000000000bb"))
            stopped.append(try plant(t, folders, ".tmp-00000000000000cc"))
        }
        setTimes(fresh, to: now.addingTimeInterval(-10))
        setTimes(ahead, to: now.addingTimeInterval(3600))
        setTimes(stopped, to: now.addingTimeInterval(-120))
        let plan = try Uninstall.plan(
            context: t.context, leaseMinutes: 30, snapshot: .empty, now: now)
        #expect(plan.stateFiles == stopped.count)
        #expect(plan.stateTemporariesInUse == fresh.count + ahead.count)
        let done = try Uninstall.run(
            context: t.context, leaseMinutes: 30, snapshot: .empty, now: now)
        for url in stopped { #expect(!exists(url), "\(url.path)") }
        for url in fresh + ahead { #expect(exists(url), "\(url.path)") }
        // Kept on purpose, so counted on their own and not as entries left alone.
        #expect(done.stateTemporariesKept == fresh.count + ahead.count && done.entriesLeft == 0)
        #expect(!done.dataFolderRemoved)
        // Two minutes on, the one that was fresh goes; one dated ahead waits until it is old.
        let afterTwoMinutes = now.addingTimeInterval(120)
        let later = try Uninstall.run(
            context: t.context, leaseMinutes: 30, snapshot: .empty, now: afterTwoMinutes)
        for url in fresh { #expect(!exists(url), "\(url.path)") }
        for url in ahead { #expect(exists(url), "\(url.path)") }
        #expect(later.stateTemporariesKept == ahead.count && later.entriesLeft == 0)
        // While they are all that is left, the listing still shows them.
        let alone = try Uninstall.plan(
            context: t.context, leaseMinutes: 30, snapshot: .empty, now: afterTwoMinutes)
        #expect(alone.stateTemporariesInUse == ahead.count && alone.stateFiles == 0)
        #expect(!alone.isEmpty)
        // A run a minute after their date deletes them, and the data folder with them.
        let due = now.addingTimeInterval(3600 + 60)
        let last = try Uninstall.run(
            context: t.context, leaseMinutes: 30, snapshot: .empty, now: due)
        for url in ahead { #expect(!exists(url), "\(url.path)") }
        #expect(last.stateTemporariesKept == 0 && last.dataFolderRemoved)
    }

    @Test func aStateTemporaryStaysOnlyUnderAMinuteOldAndOnlyWhereASaveTakesNoPickLock() throws {
        let t = try TestHome()
        // Whole seconds, as a file's time is read, so a minute old is exactly 60 seconds.
        let now = Date(timeIntervalSince1970: Double(Int(Date().timeIntervalSince1970)))
        let minute = try plant(t, Layout.stateFolders, ".tmp-00000000000000dd")
        let half = try plant(t, Layout.stateFolders, ".tmp-00000000000000ee")
        let backup = try plant(t, Layout.backupsFolders, ".tmp-00000000000000ff")
        setTimes([minute], to: now.addingTimeInterval(-60))
        setTimes([half], to: now.addingTimeInterval(-30))
        setTimes([backup], to: now.addingTimeInterval(-10))
        let plan = try Uninstall.plan(
            context: t.context, leaseMinutes: 30, snapshot: .empty, now: now)
        #expect(plan.stateFiles == 1 && plan.stateTemporariesInUse == 1 && plan.backupFiles == 1)
        let done = try Uninstall.run(
            context: t.context, leaseMinutes: 30, snapshot: .empty, now: now)
        #expect(!exists(minute) && exists(half) && !exists(backup))
        #expect(done.stateTemporariesKept == 1 && done.entriesLeft == 0)
    }
}
