import Foundation
import Testing

@testable import Core

/// The checks read an inherited allow entry, by path and by handle, as one that lets others in;
/// a list the user cannot read counts as one that lets others in, wherever a check meets it, and
/// `doctor` names it; and a save never starts a write it cannot finish.
@Suite struct AccessListReadTests {
    func account() -> Account { Account(label: "pool-a", kind: Kind.token, role: Role.pool) }

    /// A home with one token account whose token file `login`'s code saved, and a launch file.
    func setUp() throws -> TestHome {
        let t = try TestHome()
        try ConfigStore(context: t.context).save(Config(accounts: [account()]))
        _ = try TokenAccounts.install(context: t.context, label: "pool-a", token: Canaries.oauth())
        _ = try LaunchFiles.create(
            context: t.context, account: account(), leaseId: "l-0a0b0c0d", caller: .none)
        return t
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

    /// Adds `entry` to `url`'s list, as an inherited entry when `inherited` is true.
    func add(_ entry: String, _ url: URL, inherited: Bool = false) throws {
        let flag = inherited ? "+ai" : "+a"
        #expect(try chmodRun([flag, entry, url.path]) == 0, "\(entry) \(url.lastPathComponent)")
    }

    func clear(_ t: TestHome) {
        _ = try? chmodRun(["-R", "-N", t.home.path])
    }

    var me: String { NSUserName() }

    func tokenFile(_ t: TestHome) throws -> URL {
        try TokenPaths.fileURL(context: t.context, label: "pool-a")
    }

    func usable(_ t: TestHome) -> Bool { TokenStore.isUsable(context: t.context, label: "pool-a") }

    /// What every command says when a folder's access list lets others in or cannot be read.
    func folderText(_ place: String) -> String {
        "Refused `\(place)`: its access list lets another user or group in, or cannot be read. Run `chflags nouchg,nouappnd \(place)` first if it is locked, then `chmod -N \(place)` in Terminal."
    }

    var tokensPlace: String { "~/.agent-balancer/" + TokenPaths.folderName }

    @Test func anInheritedAllowEntryOnATokenFileMakesItNotPrivateByPath() throws {
        let t = try setUp()
        defer { clear(t) }
        let file = try tokenFile(t)
        try add("everyone allow read", file, inherited: true)
        let facts = try TokenPaths.facts(context: t.context, label: "pool-a")
        #expect(facts.sharedByAccessList && !facts.isPrivate)
        #expect(!usable(t))
        #expect(
            TokenStore.blockedText(context: t.context, label: "pool-a")
                == "The token file of 'pool-a' may be readable by others, so its token is not used. Run `agent-balancer doctor` in Terminal."
        )
        #expect(try chmodRun(["-N", file.path]) == 0)
        #expect(usable(t))
    }

    @Test func anInheritedAllowEntryOnATokenFolderIsRefusedByHandleAndByPlace() throws {
        let t = try setUp()
        defer { clear(t) }
        let folder = try tokenFile(t).deletingLastPathComponent()
        try add("everyone allow list,search", folder, inherited: true)
        #expect(throws: ToolError(folderText(tokensPlace))) {
            _ = try TokenPaths.facts(context: t.context, label: "pool-a")
        }
        #expect(!usable(t))
        let writer = NoFollowWriter(root: t.context.dataRoot)
        #expect(
            writer.placeEntry(parent: [], name: TokenPaths.folderName)
                == .problem(.sharedByAccessList))
        #expect(
            TokenStore.blockedText(context: t.context, label: "pool-a") == folderText(tokensPlace))
        #expect(try chmodRun(["-N", folder.path]) == 0)
        #expect(usable(t))
        #expect(writer.placeEntry(parent: [], name: TokenPaths.folderName) == .folder)
    }

    @Test func aTokenFolderWhoseListTheUserCannotReadIsRefusedAndNamedWithItsFix() throws {
        for entry in ["\(me) deny readsecurity", "\(me) deny readattr"] {
            let t = try setUp()
            defer { clear(t) }
            let folder = try tokenFile(t).deletingLastPathComponent()
            try add(entry, folder)
            #expect(!usable(t), "\(entry)")
            #expect(throws: ToolError(folderText(tokensPlace))) {
                _ = try TokenPaths.facts(context: t.context, label: "pool-a")
            }
            let writer = NoFollowWriter(root: t.context.dataRoot)
            #expect(
                writer.placeEntryOpening(parent: [], name: TokenPaths.folderName)
                    == .problem(.sharedByAccessList), "\(entry)")
            let said = DoctorChecks.accessListProblems(context: t.context)
            #expect(
                said == [
                    "`\(tokensPlace)` has an access list that lets another user or group in, or that cannot be read, so the tool refuses it. Run `chmod -N \(tokensPlace)` in Terminal, then run `agent-balancer doctor` again."
                ], "\(entry)")
            #expect(try chmodRun(["-N", folder.path]) == 0)
            #expect(usable(t), "\(entry)")
            #expect(DoctorChecks.accessListProblems(context: t.context).isEmpty, "\(entry)")
        }
    }

    @Test func aTokenFileWhoseListTheUserCannotReadIsNotUsedAndDoctorNamesIt() throws {
        let t = try setUp()
        defer { clear(t) }
        let file = try tokenFile(t)
        try add("everyone allow read", file)
        try add("\(me) deny readsecurity", file)
        let facts = try TokenPaths.facts(context: t.context, label: "pool-a")
        #expect(facts.unchecked && !facts.isPrivate)
        #expect(!usable(t))
        let place = tokensPlace + "/pool-a.json"
        #expect(
            DoctorChecks.accessListProblems(context: t.context) == [
                "`\(place)` cannot be checked, so its token is not used, and another user may have read it. Run `chmod -h -N \(place)`, or `chmod -N \(place)` if that says Permission denied, to use it again."
            ])
        #expect(try chmodRun(["-N", file.path]) == 0)
        #expect(usable(t))
    }

    @Test func aFolderAccountsRefusedFolderIsNamedWithItsCommandAndThenPasses() throws {
        let t = try TestHome()
        defer { clear(t) }
        let config = Config(accounts: [Account(label: "spare", kind: Kind.folder, role: Role.pool)])
        try ConfigStore(context: t.context).save(config)
        let inner = FolderPaths.folders(label: "spare")
        try NoFollowWriter(root: t.context.dataRoot).prepare(folders: inner)
        let cases: [(path: [String], entry: String)] = [
            (Array(inner.dropLast()), "everyone allow list"), (inner, "\(me) deny readsecurity"),
        ]
        for item in cases {
            let url = item.path.reduce(t.context.dataRoot) { $0.appendingPathComponent($1) }
            try add(item.entry, url)
            let place = (["~/.agent-balancer"] + item.path).joined(separator: "/")
            let said =
                "Account 'spare': its folder `\(place)` has an access list that lets another user or group in, or that cannot be read. Run `chmod -N \(place)`, or run `agent-balancer remove spare`."
            #expect(throws: ToolError(said)) {
                try ConfigValidator.validate(config, context: t.context)
            }
            #expect(try chmodRun(["-N", url.path]) == 0)
            try ConfigValidator.validate(config, context: t.context)
        }
    }

    @Test func aFolderAccountsFolderThatIsALinkIsNamedWithNoChmod() throws {
        let t = try TestHome()
        defer { clear(t) }
        let config = Config(accounts: [Account(label: "spare", kind: Kind.folder, role: Role.pool)])
        try ConfigStore(context: t.context).save(config)
        let elsewhere = t.home.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(
            at: elsewhere.appendingPathComponent(".claude"), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try NoFollowWriter(root: t.context.dataRoot).prepare(folders: [
            FolderPaths.accountsFolderName
        ])
        let link = t.context.dataRoot.appendingPathComponent(FolderPaths.accountsFolderName)
            .appendingPathComponent("spare")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)
        let place = "~/.agent-balancer/" + FolderPaths.accountsFolderName + "/spare"
        // A list command on a link would act on the folder it points to.
        let said =
            "Account 'spare': its folder `\(place)` is a link, which the tool never follows. Move the folder it points to back in its place, or run `agent-balancer remove spare`."
        #expect(throws: ToolError(said)) {
            try ConfigValidator.validate(config, context: t.context)
        }
    }

    @Test func aReadWithNoListOnAVolumeWithoutListsIsClosedAndAnyOtherErrorIsUnreadable() {
        for error in [ENOENT, ENOTSUP, EOPNOTSUPP] {
            #expect(AccessList.verdictWithoutList(error) == .closed, "\(error)")
        }
        for error in [EACCES, EIO, EINVAL, EBADF, ENOMEM, ENAMETOOLONG, 0] {
            #expect(AccessList.verdictWithoutList(error) == .unreadable, "\(error)")
        }
    }

    @Test func aSaveRefusedAtItsLaunchFolderChangesNoFileBeforeItStops() throws {
        let t = try setUp()
        defer { clear(t) }
        let reading = try ReadingStoreFixture.save(t, label: "pool-a")
        let file = try tokenFile(t)
        let before = try Data(contentsOf: file)
        let folder = LaunchFiles.rootURL(context: t.context).appendingPathComponent("pool-a")
        let launches = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        try add("everyone allow read", folder)
        let place = "~/.agent-balancer/" + LaunchFiles.folder + "/pool-a"
        #expect(throws: ToolError(folderText(place))) {
            _ = try TokenAccounts.install(
                context: t.context, label: "pool-a", token: Canaries.oauth(),
                requireAccount: true)
        }
        #expect(try Data(contentsOf: file) == before)
        #expect(FileManager.default.fileExists(atPath: reading.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == launches)
    }
}

/// A stored reading for a label, written through the tool's writer as a probe would.
enum ReadingStoreFixture {
    static func save(_ t: TestHome, label: String) throws -> URL {
        let now = Date()
        let window = WindowReading(
            usedPercent: 10, resetsAt: now.addingTimeInterval(86_400), readAt: now)
        let reading = Reading(readAt: now, windows: [WindowName.sevenDay: window])
        try ReadingStore(context: t.context).save(reading, label: label)
        return Layout.readingsFolders.reduce(t.context.dataRoot) { $0.appendingPathComponent($1) }
            .appendingPathComponent(Layout.readingName(label))
    }
}
