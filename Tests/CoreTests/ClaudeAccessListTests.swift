import Darwin.membership
import Foundation
import Testing

@testable import Core

/// The runner refuses a `claude` whose real target, or `~/.local/bin` when the binary sits there,
/// has an access list entry that gives another user or group any right but reading, running,
/// listing, searching and reading its attributes or list, inherited or not, or a list the user
/// cannot read, as it refuses one that group or others can write; an entry that only lets others
/// read or run it, one for the user alone and one that only denies change nothing. A lookup that
/// stops is refused, naming where it stops and only a command that lets it through.
@Suite struct ClaudeAccessListTests {
    func runTool(_ tool: String, _ arguments: [String]) throws -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = arguments
        task.standardError = Pipe()
        try task.run()
        task.waitUntilExit()
        return task.terminationStatus
    }

    func chmodRun(_ arguments: [String]) throws -> Int32 { try runTool("/bin/chmod", arguments) }

    func chflagsRun(_ arguments: [String]) throws -> Int32 {
        try runTool("/usr/bin/chflags", arguments)
    }

    /// Adds `entry` to `url`'s list, as an inherited entry when `inherited` is true.
    func add(_ entry: String, _ url: URL, inherited: Bool = false) throws {
        let flag = inherited ? "+ai" : "+a"
        #expect(try chmodRun([flag, entry, url.path]) == 0, "\(entry) \(url.lastPathComponent)")
    }

    /// Sets `url`'s list to one entry for `everyone` of `kind`, an allow entry unless said, with
    /// the raw `rights` bits, written through libc's external form, which takes what `chmod`
    /// cannot name.
    func addRaw(_ rights: UInt32, _ url: URL, kind: Int32 = KAUTH_ACE_PERMIT) throws {
        let aclStart = try #require(MemoryLayout<kauth_filesec>.offset(of: \.fsec_acl))
        let aceStart = try #require(MemoryLayout<kauth_acl>.offset(of: \.acl_ace))
        let flagsAt = try #require(MemoryLayout<kauth_ace>.offset(of: \.ace_flags))
        let rightsAt = try #require(MemoryLayout<kauth_ace>.offset(of: \.ace_rights))
        var everyone = [UInt8](repeating: 0, count: 16)
        #expect(mbr_gid_to_uuid(12, &everyone) == 0)
        var form = [UInt8](
            repeating: 0, count: aclStart + aceStart + MemoryLayout<kauth_ace>.stride)
        form.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: UInt32(KAUTH_FILESEC_MAGIC), toByteOffset: 0, as: UInt32.self)
            raw.storeBytes(of: UInt32(1), toByteOffset: aclStart, as: UInt32.self)
            let ace = aclStart + aceStart
            for (index, byte) in everyone.enumerated() { raw[ace + index] = byte }
            raw.storeBytes(
                of: UInt32(kind), toByteOffset: ace + flagsAt, as: UInt32.self)
            raw.storeBytes(of: rights, toByteOffset: ace + rightsAt, as: UInt32.self)
        }
        let list = try #require(form.withUnsafeBytes { acl_copy_int_native($0.baseAddress) })
        defer { acl_free(UnsafeMutableRawPointer(list)) }
        #expect(acl_set_link_np(url.path, ACL_TYPE_EXTENDED, list) == 0, "\(rights)")
    }

    /// Clears the list of the link at `url` itself, which `chmod -h -N` cannot open when the list
    /// denies the user `read`.
    func clearLinkList(_ url: URL) {
        let fd = open(url.path, O_SYMLINK | O_WRONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return }
        defer { close(fd) }
        if let empty = acl_init(0) {
            _ = acl_set_fd_np(fd, empty, ACL_TYPE_EXTENDED)
            acl_free(UnsafeMutableRawPointer(empty))
        }
    }

    /// Clears every lock flag, then every list, under the home and on the home itself.
    func clear(_ t: TestHome) {
        _ = try? chflagsRun(["-R", "nouchg,nouappnd", t.home.path])
        _ = try? chmodRun(["-R", "-N", t.home.path])
    }

    var me: String { NSUserName() }

    func localBin(_ t: TestHome) -> URL { t.fakePath.deletingLastPathComponent() }

    /// Moves the fake to `relative` under the home and links `.local/bin/claude` to it, by its
    /// absolute path or by `linkText`.
    func linkInstall(_ t: TestHome, _ relative: String, linkText: String? = nil) throws -> URL {
        try t.installFake()
        let real = t.home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: t.fakePath, to: real)
        try FileManager.default.createSymbolicLink(
            atPath: t.fakePath.path, withDestinationPath: linkText ?? real.path)
        return real
    }

    /// Each right that changes a file, and each that changes a folder.
    let fileRights = [
        "write", "append", "delete", "writeattr", "writeextattr", "writesecurity", "chown",
    ]
    let folderRights = [
        "add_file", "add_subdirectory", "delete_child", "delete", "writeattr", "writeextattr",
        "writesecurity", "chown",
    ]

    /// Who an entry can name besides the user: every user, a group, and another user.
    let others = ["everyone", "group:staff", "user:nobody"]

    func binaryText(_ target: String, fix: String? = nil) -> String {
        "Refused ~/.local/bin/claude: its real target's access list lets another user or group change it, or cannot be read. "
            + (fix ?? "Run `chmod -N \(target)` in Terminal.")
    }

    func folderText(_ folder: String = "~/.local/bin", fix: String? = nil) -> String {
        "Refused ~/.local/bin/claude: its folder's access list lets another user or group change it, or cannot be read. "
            + (fix ?? "Run `chmod -N \(folder)` in Terminal.")
    }

    /// What a refusal says when the lookup stops, of the binary or of its folder.
    func stopText(_ because: String, fix: String?, folder: Bool = false, shown: String? = nil)
        -> String
    {
        "Refused \(shown ?? "~/.local/bin/claude"): \(folder ? "its folder" : "it") cannot be checked, because \(because)."
            + (fix.map { " Run `\($0)` in Terminal." } ?? "")
    }

    /// What `locate` refuses the binary with, or nil when it finds it.
    func refusal(_ runner: ClaudeRunner) -> String? {
        do {
            _ = try runner.locate()
            return nil
        } catch let error as ToolError {
            #expect(error.code == .checkFailed, "\(error.message)")
            return error.message
        } catch {
            return "\(error)"
        }
    }

    func refusal(_ t: TestHome) -> String? { refusal(t.runner) }

    @Test func aRightThatChangesTheBinaryRefusesItForAnyoneButTheUserInheritedOrNot() throws {
        for right in fileRights {
            for who in others {
                for inherited in [false, true] {
                    let t = try TestHome()
                    defer { clear(t) }
                    try t.installFake()
                    let entry = "\(who) allow \(right)"
                    let name = "\(entry) inherited \(inherited)"
                    try add(entry, t.fakePath, inherited: inherited)
                    #expect(refusal(t) == binaryText("~/.local/bin/claude"), "\(name)")
                    #expect(try chmodRun(["-N", t.fakePath.path]) == 0, "\(name)")
                    #expect(refusal(t) == nil, "\(name)")
                }
            }
        }
    }

    @Test func aRightThatChangesLocalBinRefusesTheBinaryInItForAnyoneButTheUserInheritedOrNot()
        throws
    {
        for right in folderRights {
            for who in others {
                for inherited in [false, true] {
                    let t = try TestHome()
                    defer { clear(t) }
                    try t.installFake()
                    let entry = "\(who) allow \(right)"
                    let name = "\(entry) inherited \(inherited)"
                    try add(entry, localBin(t), inherited: inherited)
                    #expect(refusal(t) == folderText(), "\(name)")
                    #expect(try chmodRun(["-N", localBin(t).path]) == 0, "\(name)")
                    #expect(refusal(t) == nil, "\(name)")
                }
            }
        }
        let t = try TestHome()
        defer { clear(t) }
        try t.installFake()
        // An entry that only passes on hands its right to each file made in the folder later.
        try add("everyone allow add_file,file_inherit,only_inherit", localBin(t))
        #expect(refusal(t) == folderText())
        // Only `~/.local/bin` gets the folder test: Homebrew's folders are group-writable.
        let other = t.home.appendingPathComponent("brew/bin")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: t.fakePath, to: other.appendingPathComponent("claude"))
        try add("everyone allow add_file,delete_child", other)
        #expect(chmod(other.path, 0o775) == 0)
        let runner = ClaudeRunner(
            context: t.context, candidates: [other.appendingPathComponent("claude")])
        #expect(try runner.locate().path == other.appendingPathComponent("claude").path)
    }

    @Test func aLinkedLocalBinIsNamedByItsRealFolder() throws {
        for entry in ["everyone allow add_file", "user:\(me) deny readattr"] {
            let t = try TestHome()
            defer { clear(t) }
            try t.installFake()
            let real = t.home.appendingPathComponent("dot bin")
            try FileManager.default.moveItem(at: localBin(t), to: real)
            try FileManager.default.createSymbolicLink(
                atPath: localBin(t).path, withDestinationPath: real.path)
            #expect(refusal(t) == nil, "\(entry)")
            try add(entry, real)
            let wanted =
                entry.contains("deny")
                ? stopText(
                    "you cannot read the attributes of `~/'dot bin'`", fix: "chmod -N ~/'dot bin'",
                    folder: true)
                : folderText("~/'dot bin'")
            #expect(refusal(t) == wanted, "\(entry)")
            #expect(try chmodRun(["-N", real.path]) == 0, "\(entry)")
            #expect(refusal(t) == nil, "\(entry)")
        }
    }

    @Test func entriesThatOnlyLetOthersReadOrRunOnlyAllowTheUserOrOnlyDenyChangeNothing() throws {
        let t = try TestHome()
        defer { clear(t) }
        try t.installFake()
        // `synchronize` changes nothing, and only libc's external form can write it.
        try addRaw(ACL_READ_DATA.rawValue | ACL_SYNCHRONIZE.rawValue, t.fakePath)
        let readOrRun = "read,execute,readattr,readextattr,readsecurity"
        let fileChanges = fileRights.joined(separator: ",")
        try add("everyone allow \(readOrRun)", t.fakePath)
        try add("group:staff allow \(readOrRun)", t.fakePath, inherited: true)
        try add("user:\(me) allow \(fileChanges)", t.fakePath)
        try add("user:nobody deny \(fileChanges)", t.fakePath)
        let looks = "list,search,readattr,readextattr,readsecurity,file_inherit,directory_inherit"
        let folderChanges = folderRights.joined(separator: ",")
        try add("everyone allow \(looks)", localBin(t))
        try add("user:nobody allow \(looks)", localBin(t), inherited: true)
        try add("user:\(me) allow \(folderChanges)", localBin(t))
        try add("user:daemon deny \(folderChanges)", localBin(t))
        #expect(refusal(t) == nil)
        #expect(try t.runner.run(arguments: ["--version"]).status == 0)
        // One right that changes the binary, for one group, is enough.
        try add("group:admin allow writeextattr", t.fakePath)
        #expect(refusal(t) == binaryText("~/.local/bin/claude"))
    }

    @Test func anyRightButReadingAndRunningCountsTheGenericOnesAndUnnamedBitsIncluded() throws {
        let generic = [
            ("read and generic write", ACL_READ_DATA.rawValue | UInt32(KAUTH_ACE_GENERIC_WRITE)),
            ("generic all", UInt32(KAUTH_ACE_GENERIC_ALL)),
            ("generic read", UInt32(KAUTH_ACE_GENERIC_READ)),
            ("generic execute", UInt32(KAUTH_ACE_GENERIC_EXECUTE)),
            ("delete_child on a file", ACL_DELETE_CHILD.rawValue),
            ("bit 0", UInt32(1)), ("bit 14", UInt32(1 << 14)), ("bit 30", UInt32(1 << 30)),
        ]
        let harmless =
            ACL_READ_DATA.rawValue | ACL_EXECUTE.rawValue | ACL_READ_ATTRIBUTES.rawValue
            | ACL_READ_EXTATTRIBUTES.rawValue | ACL_READ_SECURITY.rawValue
            | ACL_SYNCHRONIZE.rawValue
        for (name, rights) in generic {
            let t = try TestHome()
            defer { clear(t) }
            try t.installFake()
            #expect(chmod(t.fakePath.path, 0o555) == 0)
            try addRaw(rights, t.fakePath)
            #expect(refusal(t) == binaryText("~/.local/bin/claude"), "\(name)")
            #expect(try chmodRun(["-N", t.fakePath.path]) == 0, "\(name)")
            try addRaw(harmless, t.fakePath)
            #expect(refusal(t) == nil, "\(name)")
            // The privacy checks still count any right of an entry for others.
            #expect(AccessList.letsOthersIn(path: t.fakePath.path), "\(name)")
        }
        // An entry of a kind other than allow or deny counts, whatever it gives.
        for kind in [KAUTH_ACE_AUDIT, KAUTH_ACE_ALARM, 0] {
            let t = try TestHome()
            defer { clear(t) }
            try t.installFake()
            try addRaw(ACL_READ_DATA.rawValue, t.fakePath, kind: kind)
            #expect(refusal(t) == binaryText("~/.local/bin/claude"), "kind \(kind)")
        }
        let folderGeneric = [
            (
                "list, search and generic write",
                ACL_LIST_DIRECTORY.rawValue | ACL_SEARCH.rawValue
                    | UInt32(KAUTH_ACE_GENERIC_WRITE)
            ),
            ("generic all", UInt32(KAUTH_ACE_GENERIC_ALL)),
        ]
        for (name, rights) in folderGeneric {
            let t = try TestHome()
            defer {
                _ = chmod(localBin(t).path, 0o700)
                clear(t)
            }
            try t.installFake()
            #expect(chmod(localBin(t).path, 0o555) == 0)
            try addRaw(rights, localBin(t))
            #expect(refusal(t) == folderText(), "\(name)")
            try addRaw(harmless, localBin(t))
            #expect(refusal(t) == nil, "\(name)")
        }
    }

    @Test func aPathWithNothingThatCanRunIsSkippedAndOneThatCannotBeCheckedIsRefused() throws {
        let t = try TestHome()
        defer { clear(t) }
        try t.installFake()
        // Each names nothing that can run, so the lookup goes on to the next path.
        let loop = t.home.appendingPathComponent("loop")
        try FileManager.default.createSymbolicLink(
            atPath: loop.path, withDestinationPath: loop.path)
        let tool = t.home.appendingPathComponent("tool")
        try Data().write(to: tool)
        #expect(chmod(tool.path, 0o755) == 0)
        let empty = t.home.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let skipped = [
            loop, tool.appendingPathComponent("claude"), empty.appendingPathComponent("claude"),
        ]
        for path in skipped {
            let runner = ClaudeRunner(context: t.context, candidates: [path, t.fakePath])
            #expect(try runner.locate().path == t.fakePath.path, "\(path.path)")
        }
        // The user's own entry keeps this one from being looked up, so it fails closed.
        let hidden = t.home.appendingPathComponent("hidden/claude")
        try FileManager.default.createDirectory(
            at: hidden.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: t.fakePath, to: hidden)
        try add("user:\(me) deny readattr", hidden)
        let runner = ClaudeRunner(context: t.context, candidates: [hidden, t.fakePath])
        #expect(
            refusal(runner)
                == stopText(
                    "you cannot read the attributes of `~/hidden/claude`",
                    fix: "chmod -N ~/hidden/claude", shown: "~/hidden/claude"))
    }

    @Test func aFolderTheUserCannotSearchStopsTheLookupAndIsNamed() throws {
        // `~/.local/bin` itself, with and without an entry that lets others in as well.
        for open in [false, true] {
            let t = try TestHome()
            defer { clear(t) }
            try t.installFake()
            try add("user:\(me) deny search", localBin(t))
            if open { try add("everyone allow add_file", localBin(t)) }
            let wanted =
                open
                ? folderText()
                : stopText(
                    "you cannot search the folder `~/.local/bin`", fix: "chmod -N ~/.local/bin")
            #expect(refusal(t) == wanted, "open \(open)")
            #expect(try chmodRun(["-N", localBin(t).path]) == 0, "open \(open)")
            #expect(refusal(t) == nil, "open \(open)")
        }
        // The real target's folder, by its access list and by its mode.
        let t = try TestHome()
        let versions = t.home.appendingPathComponent(".local/share/claude/versions")
        defer {
            _ = chmod(versions.path, 0o700)
            clear(t)
        }
        _ = try linkInstall(t, ".local/share/claude/versions/2.1.0")
        try add("user:\(me) deny search", versions)
        let place = "~/.local/share/claude/versions"
        #expect(
            refusal(t)
                == stopText("you cannot search the folder `\(place)`", fix: "chmod -N \(place)"))
        #expect(try chmodRun(["-N", versions.path]) == 0)
        #expect(refusal(t) == nil)
        #expect(chmod(versions.path, 0o600) == 0)
        #expect(refusal(t) == stopText("you cannot search the folder `\(place)`", fix: nil))
        // The same file named directly gets the same answer.
        let direct = ClaudeRunner(
            context: t.context, candidates: [versions.appendingPathComponent("2.1.0")])
        #expect(
            refusal(direct)
                == stopText(
                    "you cannot search the folder `\(place)`", fix: nil,
                    shown: "\(place)/2.1.0"))
    }

    @Test func aListTheUserCannotReadOnTheBinaryOrLocalBinRefusesTheBinary() throws {
        for denied in ["readsecurity", "readattr"] {
            for onFolder in [false, true] {
                let t = try TestHome()
                defer { clear(t) }
                try t.installFake()
                let url = onFolder ? localBin(t) : t.fakePath
                let name = "\(denied) denied on \(url.lastPathComponent)"
                try add("user:\(me) deny \(denied)", url)
                let place = onFolder ? "~/.local/bin" : "~/.local/bin/claude"
                let wanted = stopText(
                    "you cannot read the attributes of `\(place)`", fix: "chmod -N \(place)",
                    folder: onFolder)
                #expect(refusal(t) == wanted, "\(name)")
                #expect(try chmodRun(["-N", url.path]) == 0, "\(name)")
                #expect(refusal(t) == nil, "\(name)")
            }
        }
    }

    @Test func aLinkedBinaryIsJudgedByItsRealTargetWhichTheRefusalNames() throws {
        let cases: [(relative: String, linkText: String?, typed: String)] = [
            (".local/share/claude/versions/2.1.0", nil, "~/.local/share/claude/versions/2.1.0"),
            (
                ".local/share/claude/versions/2.1.0", "../share/./claude/versions/2.1.0",
                "~/.local/share/claude/versions/2.1.0"
            ),
            ("my tools/claude", nil, "~/'my tools/claude'"),
        ]
        for item in cases {
            let entries = [
                "everyone allow write", "user:\(me) deny readsecurity", "user:\(me) deny readattr",
            ]
            for entry in entries {
                let name = "\(item.relative) \(item.linkText ?? "") \(entry)"
                let t = try TestHome()
                defer { clear(t) }
                let real = try linkInstall(t, item.relative, linkText: item.linkText)
                #expect(refusal(t) == nil, "\(name)")
                try add(entry, real)
                let wanted =
                    entry.contains("allow")
                    ? binaryText(item.typed)
                    : stopText(
                        "you cannot read the attributes of `\(item.typed)`",
                        fix: "chmod -N \(item.typed)")
                #expect(refusal(t) == wanted, "\(name)")
                #expect(try chmodRun(["-N", real.path]) == 0, "\(name)")
                #expect(refusal(t) == nil, "\(name)")
                #expect(try t.runner.locate().path == t.fakePath.path, "\(name)")
            }
        }
    }

    @Test func aLookupThatStopsOnTheWayNamesWhereAndOnlyACommandThatClearsIt() throws {
        let target = ".local/share/claude/versions/2.1.0"
        // A folder on the way that the user cannot read: its own `chmod -N` lets the lookup on.
        do {
            let t = try TestHome()
            defer { clear(t) }
            _ = try linkInstall(t, target)
            let share = t.home.appendingPathComponent(".local/share/claude")
            try add("user:\(me) deny readattr", share)
            let place = "~/.local/share/claude"
            #expect(
                refusal(t)
                    == stopText(
                        "you cannot read the attributes of `\(place)`", fix: "chmod -N \(place)"))
            #expect(try chmodRun(["-N", share.path]) == 0)
            #expect(refusal(t) == nil)
        }
        // A target the user cannot open either: its owner is unknown, so no command is named.
        do {
            let t = try TestHome()
            defer { clear(t) }
            let real = try linkInstall(t, target)
            try add("user:\(me) deny read,readattr", real)
            #expect(
                refusal(t)
                    == stopText("you cannot read the attributes of `~/\(target)`", fix: nil))
            #expect(try chmodRun(["-N", real.path]) == 0)
            #expect(refusal(t) == nil)
        }
        // The link's own list: no `chmod` clears it, so none is named.
        for denied in ["read,readattr,readsecurity", "read"] {
            let t = try TestHome()
            defer {
                clearLinkList(t.fakePath)
                clear(t)
            }
            _ = try linkInstall(t, target)
            #expect(try chmodRun(["-h", "+a", "user:\(me) deny \(denied)", t.fakePath.path]) == 0)
            #expect(
                refusal(t) == stopText("you cannot read the link `~/.local/bin/claude`", fix: nil),
                "\(denied)")
            clearLinkList(t.fakePath)
            #expect(refusal(t) == nil, "\(denied)")
        }
    }

    @Test func aLockedBinaryOrFolderNamesTheFlagToClearFirst() throws {
        for flag in ["uchg", "uappnd"] {
            for onFolder in [false, true] {
                let name = "\(flag) on folder \(onFolder)"
                let t = try TestHome()
                defer { clear(t) }
                try t.installFake()
                let url = onFolder ? localBin(t) : t.fakePath
                let place = onFolder ? "~/.local/bin" : "~/.local/bin/claude"
                try add(onFolder ? "everyone allow add_file" : "everyone allow write", url)
                #expect(try chflagsRun([flag, url.path]) == 0, "\(name)")
                let fix = "Run `chflags no\(flag) \(place)`, then `chmod -N \(place)` in Terminal."
                let wanted = onFolder ? folderText(fix: fix) : binaryText(place, fix: fix)
                #expect(refusal(t) == wanted, "\(name)")
                #expect(try chmodRun(["-N", url.path]) != 0, "\(name)")
                #expect(try chflagsRun(["no" + flag, url.path]) == 0, "\(name)")
                #expect(try chmodRun(["-N", url.path]) == 0, "\(name)")
                #expect(refusal(t) == nil, "\(name)")
            }
        }
    }

    @Test func aLockedFolderTheUserCannotSearchNamesTheFlagsToClearFirst() throws {
        // `~/.local/bin` itself, then the real target's folder.
        let cases = [("uchg", false), ("uappnd", false), ("uchg,uappnd", false), ("uchg", true)]
        for (flags, onTarget) in cases {
            let name = "\(flags) on the target's folder \(onTarget)"
            let t = try TestHome()
            defer { clear(t) }
            let folder: URL
            if onTarget {
                _ = try linkInstall(t, ".local/share/claude/versions/2.1.0")
                folder = t.home.appendingPathComponent(".local/share/claude/versions")
            } else {
                try t.installFake()
                folder = localBin(t)
            }
            let place = onTarget ? "~/.local/share/claude/versions" : "~/.local/bin"
            try add("user:\(me) deny search", folder)
            #expect(try chflagsRun([flags, folder.path]) == 0, "\(name)")
            let unlock = flags.split(separator: ",").map { "no" + $0 }.joined(separator: ",")
            let wanted =
                stopText("you cannot search the folder `\(place)`", fix: nil)
                + " Run `chflags \(unlock) \(place)`, then `chmod -N \(place)` in Terminal."
            #expect(refusal(t) == wanted, "\(name)")
            // The lock keeps `chmod -N` alone from clearing the list.
            #expect(try chmodRun(["-N", folder.path]) != 0, "\(name)")
            #expect(refusal(t) == wanted, "\(name)")
            #expect(try chflagsRun([unlock, folder.path]) == 0, "\(name)")
            #expect(try chmodRun(["-N", folder.path]) == 0, "\(name)")
            #expect(refusal(t) == nil, "\(name)")
        }
    }
}
