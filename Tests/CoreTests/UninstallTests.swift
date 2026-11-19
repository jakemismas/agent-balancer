import Foundation
import Testing

@testable import Core

/// `uninstall` through the calls the command uses: the order of its steps, entries it did not
/// make, an unreadable lease file and the read-back that guards the token files.
@Suite struct UninstallTests {
    struct Stop: Error {}

    func token(_ label: String = "pool-a") -> Account {
        Account(label: label, kind: Kind.token, role: Role.pool)
    }

    /// A configured home with one token account, its token file, and one launch file that is
    /// older than the lease window and that nothing names, so it is due to be deleted.
    func setUp() throws -> (TestHome, URL) {
        let t = try TestHome()
        try ConfigStore(context: t.context).save(Config(accounts: [token()]))
        _ = try TokenAccounts.install(context: t.context, label: "pool-a", token: Canaries.oauth())
        let launch = try launchFile(t, "l-0a0b0c0d")
        return (t, launch)
    }

    func launchFile(_ t: TestHome, _ leaseId: String) throws -> URL {
        let url = try LaunchFiles.create(
            context: t.context, account: token(), leaseId: leaseId, caller: .none)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3 * 3600)], ofItemAtPath: url.path)
        return url
    }

    func tokenFile(_ t: TestHome) throws -> URL {
        try TokenPaths.fileURL(context: t.context, label: "pool-a")
    }

    /// Writes a file under the data folder through the tool's own writer, folders at 0700.
    func plant(_ t: TestHome, _ folders: [String], _ name: String, _ body: String = "{}") throws
        -> URL
    {
        try NoFollowWriter(root: t.context.dataRoot).put(
            Data(body.utf8), folders: folders, name: name)
        return folders.reduce(t.context.dataRoot) { $0.appendingPathComponent($1) }
            .appendingPathComponent(name)
    }

    /// True when anything is at the path, a link to nothing included.
    func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    func isLink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    func text(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    func isTombstone(_ url: URL) throws -> Bool {
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let env = try #require(object["env"] as? [String: String])
        return env[ProtectedEnv.tokenVariable] == "invalid"
    }

    func run(_ t: TestHome, afterStep: (Uninstall.Step) throws -> Void = { _ in }) throws
        -> Uninstall.Result
    {
        try Uninstall.run(
            context: t.context, leaseMinutes: 30, snapshot: .empty, afterStep: afterStep)
    }

    /// The listed links of one folder account: a real link and a path that is no longer one.
    func listedLinks(_ t: TestHome) throws -> (link: URL, kept: URL) {
        let writer = NoFollowWriter(root: t.context.dataRoot)
        try writer.prepare(folders: FolderPaths.folders(label: "spare"))
        let folder = try FolderPaths.configDir(context: t.context, label: "spare")
        let target = t.home.appendingPathComponent("shared.md")
        try "shared".write(to: target, atomically: true, encoding: .utf8)
        let link = folder.appendingPathComponent("CLAUDE.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let kept = folder.appendingPathComponent("settings.json")
        try "mine".write(to: kept, atomically: true, encoding: .utf8)
        let record: [String: Any] = [
            "schemaVersion": 1,
            "links": [
                ["path": link.path, "target": target.path],
                ["path": kept.path, "target": target.path],
            ],
            "linkedLabels": ["spare"],
        ]
        _ = try plant(
            t, [], "links.json",
            String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self))
        return (link, kept)
    }

    // MARK: The order

    @Test func uninstallDeletesInTheSettledOrder() throws {
        // The settled order: launch files, token files, writer leftovers, state, logs, backups,
        // probe, the listed links, the link record, the config, the locks, the data folder.
        #expect(
            Uninstall.Step.allCases == [
                .launchFiles, .tokenFiles, .writerLeftovers, .state, .logs, .backups, .probe,
                .links, .linkRecord, .config, .locks, .dataFolder,
            ])
        let (t, launch) = try setUp()
        let tokens = try tokenFile(t)
        let leftover = tokens.deletingLastPathComponent().appendingPathComponent(
            ".tmp-0123456789abcdef")
        try "{}".write(to: leftover, atomically: false, encoding: .utf8)
        let launchLeftover = launch.deletingLastPathComponent().appendingPathComponent(
            ".tmp-fedcba9876543210")
        try "{}".write(to: launchLeftover, atomically: false, encoding: .utf8)
        let rootLeftover = t.context.dataRoot.appendingPathComponent(".tmp-00112233445566ff")
        try "{}".write(to: rootLeftover, atomically: false, encoding: .utf8)
        let links = try listedLinks(t)
        let items: [(step: Uninstall.Step, url: URL)] = [
            (.launchFiles, launch), (.tokenFiles, tokens), (.writerLeftovers, leftover),
            (.writerLeftovers, launchLeftover), (.writerLeftovers, rootLeftover),
            (.state, try plant(t, Layout.stateFolders, StatusBuilder.statusName)),
            (.logs, try plant(t, Layout.logsFolders, Layout.logName)),
            (.backups, try plant(t, Layout.backupsFolders, "config-2026-11-13.json")),
            (.probe, try plant(t, ["probe", "p-0123456789abcdef"], "x.jsonl")),
            (.links, links.link),
            (.linkRecord, t.context.dataRoot.appendingPathComponent("links.json")),
            (.config, t.context.dataRoot.appendingPathComponent("config.json")),
            (.locks, try plant(t, Layout.locksFolders, StatusBuilder.lockName, "")),
        ]
        for item in items { #expect(exists(item.url), "\(item.url.lastPathComponent)") }
        var steps: [Uninstall.Step] = []
        var present: [Uninstall.Step: Set<String>] = [:]
        _ = try run(t) { step in
            steps.append(step)
            present[step] = Set(items.filter { exists($0.url) }.map(\.url.path))
        }
        #expect(steps == Uninstall.Step.allCases)
        for item in items {
            let due = try #require(Uninstall.Step.allCases.firstIndex(of: item.step))
            for (index, step) in Uninstall.Step.allCases.enumerated() {
                let stays = present[step]?.contains(item.url.path) ?? true
                #expect(
                    stays == (index < due), "\(item.url.lastPathComponent) after \(step.rawValue)")
            }
        }
        #expect(text(links.kept) == "mine")
    }

    // MARK: Entries the tool did not make

    @Test func aLaunchLabelFolderThatIsALinkIsSkippedCountedAndNeverFollowed() throws {
        let (t, launch) = try setUp()
        let elsewhere = t.home.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let outside = elsewhere.appendingPathComponent("l-1a1b1c1d.json")
        try "outside".write(to: outside, atomically: true, encoding: .utf8)
        let stray = LaunchFiles.rootURL(context: t.context).appendingPathComponent("pool-b")
        try FileManager.default.createSymbolicLink(at: stray, withDestinationURL: elsewhere)
        // A launch file with a token may be behind it, so it is listed as such.
        let plan = try Uninstall.plan(context: t.context, leaseMinutes: 30, snapshot: .empty)
        #expect(plan.launchEntriesNotFollowed == 1 && plan.launchFiles == 1)
        let done = try run(t)
        // Every other step still runs, and the link is counted on its own, never followed.
        #expect(done.launchFiles == 1 && done.tokenFiles == 1)
        #expect(done.launchEntriesNotFollowed == 1 && done.entriesLeft == 0)
        #expect(try !exists(launch) && !exists(tokenFile(t)))
        #expect(isLink(stray) && text(outside) == "outside")
        #expect(!exists(t.context.dataRoot.appendingPathComponent("config.json")))
        #expect(!exists(t.context.dataRoot.appendingPathComponent(Layout.locksFolders[0])))
        // A data folder that holds nothing but such a link still has something to say.
        let bare = try TestHome()
        try NoFollowWriter(root: bare.context.dataRoot).prepare(folders: [LaunchFiles.folder])
        try FileManager.default.createSymbolicLink(
            at: LaunchFiles.rootURL(context: bare.context).appendingPathComponent("pool-a"),
            withDestinationURL: elsewhere)
        let alone = try Uninstall.plan(context: bare.context, leaseMinutes: 30, snapshot: .empty)
        #expect(alone.launchEntriesNotFollowed == 1 && !alone.isEmpty)
    }

    @Test func aFileWhereALaunchLabelFolderBelongsIsSkippedAndCounted() throws {
        let (t, launch) = try setUp()
        let stray = LaunchFiles.rootURL(context: t.context).appendingPathComponent("pool-c")
        try "mine".write(to: stray, atomically: true, encoding: .utf8)
        #expect(
            try Uninstall.plan(context: t.context, leaseMinutes: 30, snapshot: .empty)
                .launchEntriesNotFollowed == 1)
        let done = try run(t)
        #expect(done.launchFiles == 1 && done.tokenFiles == 1)
        #expect(done.launchEntriesNotFollowed == 1 && done.entriesLeft == 0)
        #expect(!exists(launch) && text(stray) == "mine")
        #expect(!exists(t.context.dataRoot.appendingPathComponent("config.json")))
        // A name in the launch folder that is not a label is only an entry left.
        let (u, _) = try setUp()
        let note = LaunchFiles.rootURL(context: u.context).appendingPathComponent("notes.txt")
        try "mine".write(to: note, atomically: true, encoding: .utf8)
        // No launch file can be behind a name that is not a label, so the listing leaves it out.
        let listed = try Uninstall.plan(context: u.context, leaseMinutes: 30, snapshot: .empty)
        #expect(listed.launchEntriesNotFollowed == 0)
        let other = try run(u)
        #expect(other.launchEntriesNotFollowed == 0 && other.entriesLeft == 1)
        #expect(text(note) == "mine")
    }

    @Test func aStateFolderThatIsALinkIsSkippedCountedAndUninstallStillFinishes() throws {
        let (t, launch) = try setUp()
        let elsewhere = t.home.appendingPathComponent("elsewhere-state")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let outside = elsewhere.appendingPathComponent("leases.json")
        try "outside".write(to: outside, atomically: true, encoding: .utf8)
        let state = t.context.dataRoot.appendingPathComponent("state")
        try FileManager.default.createSymbolicLink(at: state, withDestinationURL: elsewhere)
        let done = try run(t)
        // The lease file behind the link is not read, so the launch file is kept, holding no token.
        #expect(done.launchFiles == 0 && done.launchFilesKept == 1)
        #expect(try isTombstone(launch))
        #expect(try done.tokenFiles == 1 && !exists(tokenFile(t)))
        #expect(done.entriesLeft == 1)
        #expect(isLink(state) && text(outside) == "outside")
        #expect(!exists(t.context.dataRoot.appendingPathComponent("config.json")))
        #expect(!exists(t.context.dataRoot.appendingPathComponent("locks")))
    }

    @Test func aTokenOrLaunchFolderThatIsALinkOrAFileIsRefusedAndNeverFollowed() throws {
        let places: [(subject: String, name: String)] = [
            ("The token folder", TokenPaths.folderName), ("The launch folder", LaunchFiles.folder),
        ]
        for place in places {
            for asLink in [true, false] {
                let t = try TestHome()
                try ConfigStore(context: t.context).save(Config(accounts: [token()]))
                let outside = t.home.appendingPathComponent("outside")
                try FileManager.default.createDirectory(
                    at: outside, withIntermediateDirectories: true)
                let kept = outside.appendingPathComponent("pool-a.json")
                try "outside".write(to: kept, atomically: true, encoding: .utf8)
                let entry = t.context.dataRoot.appendingPathComponent(place.name)
                let typed = "~/.agent-balancer/" + place.name
                let refused: ToolError
                if asLink {
                    try FileManager.default.createSymbolicLink(
                        at: entry, withDestinationURL: outside)
                    refused = ToolError(Messages.uninstallFolderIsALink(place.subject, typed))
                } else {
                    try "mine".write(to: entry, atomically: true, encoding: .utf8)
                    refused = ToolError(Messages.uninstallFolderIsNotAFolder(typed))
                }
                let before = tree(t.context.dataRoot)
                #expect(throws: refused) {
                    _ = try Uninstall.plan(context: t.context, leaseMinutes: 30)
                }
                #expect(throws: refused) { _ = try run(t) }
                #expect(tree(t.context.dataRoot) == before, "\(place.name) \(asLink)")
                #expect(text(kept) == "outside")
                #expect(asLink ? isLink(entry) : text(entry) == "mine")
            }
        }
        // Past the refusal, the steps themselves still count such an entry once and never follow
        // it, for a folder swapped in after the check.
        let t = try TestHome()
        let outside = t.home.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let kept = outside.appendingPathComponent("pool-a.json")
        try "outside".write(to: kept, atomically: true, encoding: .utf8)
        try NoFollowWriter(root: t.context.dataRoot).prepare(folders: [])
        for name in [TokenPaths.folderName, LaunchFiles.folder] {
            try FileManager.default.createSymbolicLink(
                at: t.context.dataRoot.appendingPathComponent(name), withDestinationURL: outside)
        }
        let tokens = try TokenAccounts.deleteTokenFilesForUninstall(context: t.context)
        #expect(tokens == TokenAccounts.TokenFilesCleared(deleted: 0, undeleted: 0, left: 1))
        let launch = try LaunchFiles.clearForUninstall(
            context: t.context, snapshot: .empty, leased: [], keepModifiedAfter: Date(),
            keepAll: false)
        #expect(launch == LaunchFiles.WipeCount(deleted: 0, tombstoned: 0, skipped: 1))
        #expect(text(kept) == "outside")
    }

    @Test func noStepAfterTheTokenFilesStopsOnWhatItCannotRemove() throws {
        let (t, _) = try setUp()
        let root = t.context.dataRoot
        let outside = t.home.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "mine".write(to: root.appendingPathComponent("logs"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("backups"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("probe"), withDestinationURL: outside)
        // A folder of the tool's that is not private stops the run before anything goes.
        let wide = try plant(t, Layout.readingsFolders, "pool-a.json")
        chmod(wide.deletingLastPathComponent().path, 0o755)
        defer { chmod(wide.deletingLastPathComponent().path, 0o700) }
        let stateFile = try plant(t, Layout.stateFolders, StatusBuilder.statusName)
        let place = (["~/.agent-balancer"] + Layout.readingsFolders).joined(separator: "/")
        let refused = ToolError(
            Messages.uninstallFolderRefused("The folder", place, .widerThanPrivate))
        #expect(throws: refused) { _ = try run(t) }
        let token = try tokenFile(t)
        #expect(exists(wide) && exists(stateFile) && exists(token))
        chmod(wide.deletingLastPathComponent().path, 0o700)
        let done = try run(t)
        #expect(done.tokenFiles == 1)
        #expect(done.entriesLeft == 3)
        #expect(!exists(wide) && !exists(stateFile))
        #expect(text(root.appendingPathComponent("logs")) == "mine")
        #expect(isLink(root.appendingPathComponent("backups")))
        #expect(!exists(root.appendingPathComponent("config.json")))
    }

    @Test func entriesTheToolDidNotMakeInTheTokenAndLaunchFoldersStay() throws {
        let (t, launch) = try setUp()
        let outside = t.home.appendingPathComponent("outside.json")
        try "outside".write(to: outside, atomically: true, encoding: .utf8)
        let tokenFolder = try tokenFile(t).deletingLastPathComponent()
        let labelFolder = launch.deletingLastPathComponent()
        let tokenLink = tokenFolder.appendingPathComponent("pool-b.json")
        let launchLink = labelFolder.appendingPathComponent("l-1a1b1c1d.json")
        for link in [tokenLink, launchLink] {
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        }
        let tokenNote = tokenFolder.appendingPathComponent("notes.txt")
        let launchNote = labelFolder.appendingPathComponent("notes.txt")
        for note in [tokenNote, launchNote] {
            try "mine".write(to: note, atomically: true, encoding: .utf8)
        }
        let done = try run(t)
        #expect(done.tokenFiles == 1 && done.launchFiles == 1)
        #expect(done.entriesLeft == 4)
        #expect(isLink(tokenLink) && isLink(launchLink))
        #expect(text(tokenNote) == "mine" && text(launchNote) == "mine")
        #expect(text(outside) == "outside")
        #expect(!exists(try tokenFile(t)) && !exists(launch))
    }

    // MARK: The lease file

    @Test func aLeaseFileThatDoesNotDecodeKeepsEveryLaunchFileAsATombstone() throws {
        for body in ["not json", #"{"schemaVersion":2,"leases":[]}"#, #"{"leases":7}"#] {
            let (t, first) = try setUp()
            let second = try launchFile(t, "l-1a1b1c1d")
            _ = try plant(t, ["state"], "leases.json", body)
            #expect(try !Uninstall.plan(context: t.context, leaseMinutes: 30).leasesReadable)
            let done = try run(t)
            #expect(done.launchFiles == 0 && done.launchFilesKept == 2, "\(body)")
            for file in [first, second] { #expect(try isTombstone(file), "\(body)") }
            #expect(try done.tokenFiles == 1 && !exists(tokenFile(t)))
        }
        // A lease file that decodes, with no open lease, lets the old file go.
        let (t, launch) = try setUp()
        try LeaseStore(context: t.context).save([
            Lease(
                id: "l-0a0b0c0d", label: "pool-a", model: "default",
                at: Date(timeIntervalSince1970: 0))
        ])
        #expect(try Uninstall.plan(context: t.context, leaseMinutes: 30).leasesReadable)
        let done = try run(t)
        #expect(done.launchFiles == 1 && done.launchFilesKept == 0 && !exists(launch))
    }

    // MARK: The read-back

    @Test func theReadBackStopsBeforeAnyTokenFileWhenALaunchFileStillHoldsAToken() throws {
        let (t, launch) = try setUp()
        let folder = launch.deletingLastPathComponent()
        chmod(folder.path, 0o500)
        defer { chmod(folder.path, 0o700) }
        try #require(access(folder.path, W_OK) != 0)
        do {
            _ = try run(t)
            Issue.record("uninstall did not stop")
        } catch let error as ToolError {
            #expect(error.message.contains("A launch file could not be cleared"))
        }
        chmod(folder.path, 0o700)
        #expect(try exists(launch) && !isTombstone(launch))
        #expect(exists(try tokenFile(t)))
        #expect(exists(t.context.dataRoot.appendingPathComponent("config.json")))
    }

    // MARK: The link record

    @Test func afterUninstallKeepsAListedPathTheLinkRecordListsNoLinks() throws {
        let (t, _) = try setUp()
        let links = try listedLinks(t)
        let manifest = t.context.dataRoot.appendingPathComponent("links.json")
        #expect(HookRecord(context: t.context).listedLinks().count == 2)
        #expect(throws: Stop.self) {
            _ = try run(t) { step in if step == .links { throw Stop() } }
        }
        let hooks = HookRecord(context: t.context)
        #expect(exists(manifest))
        #expect(hooks.listedLinks().isEmpty && !hooks.isLinked("spare"))
        let saved = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        #expect((saved["links"] as? [Any])?.isEmpty == true)
        #expect((saved["linkedLabels"] as? [Any])?.isEmpty == true)
        #expect(!exists(links.link) && text(links.kept) == "mine")
        // A rerun finishes, and no record is left.
        let done = try run(t)
        #expect(done.linksRemoved == 0 && !exists(manifest))
        // `accounts/` keeps the data folder, and it is not an entry the tool left.
        #expect(done.entriesLeft == 0 && !done.dataFolderRemoved)
        #expect(text(links.kept) == "mine")
    }

    @Test func aListedPathWithAnEmptyDotOrDotDotSegmentNamesNoLink() throws {
        let (t, _) = try setUp()
        let links = try listedLinks(t)
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: links.link.path)
        let folder = links.link.deletingLastPathComponent().path
        let spellings = [
            folder + "/./CLAUDE.md", folder + "//CLAUDE.md", folder + "/x/../CLAUDE.md",
            folder + "/CLAUDE.md/x/..",
        ]
        let record: [String: Any] = [
            "schemaVersion": 1,
            "links": spellings.map { ["path": $0, "target": target] },
            "linkedLabels": ["spare"],
        ]
        _ = try plant(
            t, [], "links.json",
            String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self))
        let hooks = HookRecord(context: t.context)
        #expect(hooks.entries(for: "spare").isEmpty)
        for entry in hooks.listedLinks() { #expect(!hooks.isIntact(entry), "\(entry.path)") }
        let done = try run(t)
        #expect(done.linksRemoved == 0 && done.linksKept == spellings.count)
        #expect(isLink(links.link))
    }
}
