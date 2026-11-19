import Foundation
import Testing

@testable import Core

/// A folder of the tool's, a token file or a launch file counts as private only when its access
/// list lets no other user or group in. A file the writer makes takes no such entry from its
/// folder, and an entry that only denies, or only allows the user, changes nothing.
@Suite struct AccessListPrivacyTests {
    func account() -> Account { Account(label: "pool-a", kind: Kind.token, role: Role.pool) }

    /// A home with one token account whose token file `login`'s code saved.
    func setUp() throws -> TestHome {
        let t = try TestHome()
        try ConfigStore(context: t.context).save(Config(accounts: [account()]))
        try save(t)
        return t
    }

    func save(_ t: TestHome) throws {
        _ = try TokenAccounts.install(context: t.context, label: "pool-a", token: Canaries.oauth())
    }

    func tokenFile(_ t: TestHome) throws -> URL {
        try TokenPaths.fileURL(context: t.context, label: "pool-a")
    }

    func chmodRun(_ arguments: [String]) throws -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/chmod")
        task.arguments = arguments
        task.standardError = Pipe()
        try task.run()
        task.waitUntilExit()
        return task.terminationStatus
    }

    func add(_ entry: String, _ url: URL) throws {
        #expect(try chmodRun(["+a", entry, url.path]) == 0, "\(entry) \(url.lastPathComponent)")
    }

    /// Clears every access list under the test's home, so nothing it set outlives it.
    func clear(_ t: TestHome) {
        _ = try? chmodRun(["-R", "-N", t.home.path])
    }

    /// The entries of `url`'s access list, a link not followed, that allow anyone but the user,
    /// read from the text `acl_to_text` writes, one entry a line.
    func entriesLettingOthersIn(_ url: URL) -> [String] {
        guard let list = acl_get_link_np(url.path, ACL_TYPE_EXTENDED) else {
            return errno == ENOENT ? [] : ["unreadable"]
        }
        defer { acl_free(UnsafeMutableRawPointer(list)) }
        var length = 0
        guard let text = acl_to_text(list, &length) else { return ["unreadable"] }
        defer { acl_free(UnsafeMutableRawPointer(text)) }
        return String(cString: text).split(separator: "\n").map(String.init).filter { line in
            let fields = line.split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count >= 6, fields[4].hasPrefix("allow") else { return false }
            return !(fields[0] == "user" && fields[3] == "\(getuid())")
        }
    }

    /// The data folder and everything under it that an access list opens to others.
    func sharedEntries(_ t: TestHome) -> [String] {
        let root = t.context.dataRoot
        var found = entriesLettingOthersIn(root).isEmpty ? [] : [root.lastPathComponent]
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            if !entriesLettingOthersIn(url).isEmpty { found.append(url.lastPathComponent) }
        }
        return found
    }

    func names(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
            .map { folder.appendingPathComponent($0) }
    }

    func usable(_ t: TestHome) -> Bool {
        TokenStore.isUsable(context: t.context, label: "pool-a")
    }

    /// What `uninstall` refuses with before it removes anything, or nil when it would go ahead.
    func refusal(_ t: TestHome) -> String? {
        do {
            _ = try Uninstall.plan(context: t.context, leaseMinutes: 30)
            return nil
        } catch let error as ToolError {
            return error.message
        } catch {
            return "\(error)"
        }
    }

    /// What every command says when a folder's access list lets another user or group in.
    func folderText(_ place: String) -> String {
        "Refused `\(place)`: its access list lets another user or group in, or cannot be read. Run `chmod -N \(place)` in Terminal."
    }

    func sharedFolderText(_ subject: String, _ place: String) -> String {
        "\(subject) `\(place)` has an access list that lets another user or group in, or that cannot be read, so `uninstall` cannot check what the tool made in it. Nothing was removed. Run `chmod -N \(place)`, then run `agent-balancer uninstall` again."
    }

    /// The `chmod` commands a text names in backticks, as arguments, with `~` as `home`.
    func chmodCommands(_ text: String, home: URL) -> [[String]] {
        text.split(separator: "`", omittingEmptySubsequences: false)
            .enumerated().filter { $0.offset % 2 == 1 }.map { String($0.element) }
            .filter { $0.hasPrefix("chmod ") }
            .map { command in
                command.split(separator: " ").dropFirst().map { word in
                    word.hasPrefix("~") ? home.path + String(word.dropFirst()) : String(word)
                }
            }
    }

    @Test func aTokenSaveIntoATokenFolderThatPassesOnAnAllowEntryIsRefusedAndNoFileTakesIt()
        throws
    {
        let t = try setUp()
        defer { clear(t) }
        let folder = try tokenFile(t).deletingLastPathComponent()
        try add("everyone allow read,file_inherit", folder)
        #expect(throws: ToolError(folderText("~/.agent-balancer/" + TokenPaths.folderName))) {
            try save(t)
        }
        for entry in names(in: folder) {
            #expect(entriesLettingOthersIn(entry).isEmpty, "\(entry.lastPathComponent)")
        }
        // The token the first save wrote is not used while its folder is open to others.
        #expect(!usable(t))
        #expect(throws: ToolError.self) {
            _ = try TokenKind.probeContext(account: account(), context: t.context)
        }
        #expect(try chmodRun(["-N", folder.path]) == 0)
        #expect(usable(t))
        try save(t)
        #expect(sharedEntries(t).isEmpty)
    }

    @Test func whatTheWriterMakesUnderAHomeThatPassesOnAnAllowEntryTakesNoneOfIt() throws {
        let t = try TestHome()
        defer { clear(t) }
        try add("everyone allow read,search,file_inherit,directory_inherit", t.home)
        try ConfigStore(context: t.context).save(Config(accounts: [account()]))
        try save(t)
        let launch = try LaunchFiles.create(
            context: t.context, account: account(), leaseId: "l-0a0b0c0d", caller: .none)
        #expect(FileManager.default.fileExists(atPath: launch.path))
        let writer = NoFollowWriter(root: t.context.dataRoot)
        try writer.append(Data("line\n".utf8), folders: Layout.logsFolders, name: Layout.logName)
        let lock = try writer.acquireLock(
            folders: Layout.locksFolders, name: Layout.pickLockName, wait: 1)
        lock?.release()
        #expect(sharedEntries(t) == [])
        #expect(usable(t))
    }

    @Test func aLaunchFileIntoALaunchFolderThatPassesOnAnAllowEntryIsRefusedAndNoFileTakesIt()
        throws
    {
        let t = try setUp()
        defer { clear(t) }
        let first = try LaunchFiles.create(
            context: t.context, account: account(), leaseId: "l-0a0b0c0d", caller: .none)
        let folder = first.deletingLastPathComponent()
        try add("everyone allow read,file_inherit", folder)
        let place = "~/.agent-balancer/" + LaunchFiles.folder + "/pool-a"
        #expect(throws: ToolError(folderText(place))) {
            _ = try LaunchFiles.create(
                context: t.context, account: account(), leaseId: "l-0e0e0e0e", caller: .none)
        }
        for entry in names(in: folder) {
            #expect(entriesLettingOthersIn(entry).isEmpty, "\(entry.lastPathComponent)")
        }
        #expect(try chmodRun(["-N", folder.path]) == 0)
        let next = try LaunchFiles.create(
            context: t.context, account: account(), leaseId: "l-0e0e0e0e", caller: .none)
        #expect(entriesLettingOthersIn(next).isEmpty)
    }

    @Test func aFolderOfTheToolsWithAnAllowEntryForAnotherIsRefusedWithTheCommandThatClearsIt()
        throws
    {
        let entries = [
            "everyone allow read", "nobody allow list", "staff allow add_file",
            "everyone allow read,file_inherit,only_inherit",
        ]
        for entry in entries {
            let t = try setUp()
            defer { clear(t) }
            let launch = try LaunchFiles.create(
                context: t.context, account: account(), leaseId: "l-0a0b0c0d", caller: .none)
            let typed = "~/.agent-balancer"
            let places: [(folder: URL, subject: String, place: String, holdsToken: Bool)] = [
                (t.context.dataRoot, "The data folder", typed, true),
                (
                    try tokenFile(t).deletingLastPathComponent(), "The token folder",
                    typed + "/" + TokenPaths.folderName, true
                ),
                (
                    LaunchFiles.rootURL(context: t.context), "The launch folder",
                    typed + "/" + LaunchFiles.folder, false
                ),
                (
                    launch.deletingLastPathComponent(), "The launch folder",
                    typed + "/" + LaunchFiles.folder + "/pool-a", false
                ),
            ]
            for item in places {
                let name = "\(entry) on \(item.place)"
                try add(entry, item.folder)
                if item.holdsToken { #expect(!usable(t), "\(name)") }
                let said = try #require(refusal(t), "\(name)")
                #expect(said == sharedFolderText(item.subject, item.place), "\(name)")
                // The command the text names clears the list, and the rerun goes ahead.
                for command in chmodCommands(said, home: t.home) {
                    #expect(try chmodRun(command) == 0, "\(name): \(command)")
                }
                #expect(refusal(t) == nil, "\(name)")
                #expect(usable(t), "\(name)")
            }
            // A folder no refusal text names refuses every write with its own command.
            let writer = NoFollowWriter(root: t.context.dataRoot)
            try writer.prepare(folders: Layout.stateFolders)
            let state = t.context.dataRoot.appendingPathComponent(Layout.stateFolders[0])
            try add(entry, state)
            do {
                try writer.put(Data("{}".utf8), folders: Layout.stateFolders, name: "probe.json")
                Issue.record("a write into a shared state folder went ahead: \(entry)")
            } catch let error as ToolError {
                #expect(error.message.contains("`chmod -N \(typed)/state`"), "\(entry)")
            }
        }
    }

    @Test func aTokenFileWithAnAllowEntryForAnotherIsNotPrivateUsableOrProbed() throws {
        let t = try setUp()
        defer { clear(t) }
        let file = try tokenFile(t)
        for entry in ["everyone allow read", "staff allow read", "nobody allow readattr"] {
            try add(entry, file)
            let facts = try TokenPaths.facts(context: t.context, label: "pool-a")
            #expect(!facts.isPrivate, "\(entry)")
            #expect(!usable(t), "\(entry)")
            #expect(throws: ToolError.self) {
                _ = try TokenKind.probeContext(account: account(), context: t.context)
            }
            #expect(throws: ToolError.self) {
                _ = try LaunchFiles.create(
                    context: t.context, account: account(), leaseId: "l-0a0b0c0d", caller: .none)
            }
            #expect(try chmodRun(["-N", file.path]) == 0)
            #expect(try TokenPaths.facts(context: t.context, label: "pool-a").isPrivate)
            #expect(usable(t), "\(entry)")
        }
    }

    @Test func anEntryThatOnlyDeniesOrOnlyAllowsTheUserChangesNothing() throws {
        let me = NSUserName()
        let onFolders = [
            "nobody deny list,search,file_inherit", "\(me) allow list,search,file_inherit",
            "daemon deny add_file,delete_child", "\(me) allow read,file_inherit,only_inherit",
        ]
        let onFiles = ["nobody deny read", "\(me) allow read", "daemon deny write,readattr"]
        for entry in onFolders {
            let t = try setUp()
            defer { clear(t) }
            let launch = try LaunchFiles.create(
                context: t.context, account: account(), leaseId: "l-0a0b0c0d", caller: .none)
            let folders = [
                t.context.dataRoot, try tokenFile(t).deletingLastPathComponent(),
                LaunchFiles.rootURL(context: t.context), launch.deletingLastPathComponent(),
            ]
            for folder in folders { try add(entry, folder) }
            #expect(refusal(t) == nil, "\(entry)")
            try save(t)
            let next = try LaunchFiles.create(
                context: t.context, account: account(), leaseId: "l-0e0e0e0e", caller: .none)
            #expect(usable(t), "\(entry)")
            #expect(try TokenPaths.facts(context: t.context, label: "pool-a").isPrivate)
            #expect(entriesLettingOthersIn(try tokenFile(t)).isEmpty, "\(entry)")
            #expect(entriesLettingOthersIn(next).isEmpty, "\(entry)")
            let writer = NoFollowWriter(root: t.context.dataRoot)
            #expect(writer.placeEntry(parent: [], name: TokenPaths.folderName) == .folder)
        }
        for entry in onFiles {
            let t = try setUp()
            defer { clear(t) }
            try add(entry, try tokenFile(t))
            #expect(try TokenPaths.facts(context: t.context, label: "pool-a").isPrivate)
            #expect(usable(t), "\(entry)")
            _ = try TokenKind.probeContext(account: account(), context: t.context)
        }
    }

    @Test func theWriterClearsAnAllowEntryForAnotherOnALockFileOrALogItOpensAgain() throws {
        let t = try setUp()
        defer { clear(t) }
        let writer = NoFollowWriter(root: t.context.dataRoot)
        try writer.append(Data("one\n".utf8), folders: Layout.logsFolders, name: Layout.logName)
        let log = t.context.dataRoot.appendingPathComponent(Layout.logsFolders[0])
            .appendingPathComponent(Layout.logName)
        let lock = t.context.dataRoot.appendingPathComponent(Layout.locksFolders[0])
            .appendingPathComponent(Layout.pickLockName)
        #expect(FileManager.default.fileExists(atPath: lock.path))
        try add("everyone allow read", log)
        try add("staff allow read,write", lock)
        try writer.append(Data("two\n".utf8), folders: Layout.logsFolders, name: Layout.logName)
        let held = try writer.acquireLock(
            folders: Layout.locksFolders, name: Layout.pickLockName, wait: 1)
        held?.release()
        #expect(entriesLettingOthersIn(log).isEmpty)
        #expect(entriesLettingOthersIn(lock).isEmpty)
        #expect(try String(contentsOf: log, encoding: .utf8).hasSuffix("one\ntwo\n"))
    }
}
