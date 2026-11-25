import Darwin.membership
import Foundation
import Testing

@testable import Core

/// The runner refuses a `claude` whose real target, or `~/.local/bin` when the binary sits there,
/// has an access list entry that gives another user or group any right but reading, running,
/// listing, searching, reading its attributes or list and `synchronize`, inherited or not, or a
/// list the user cannot read, as it refuses one that group or others can write; an entry that
/// only lets others read or run it, one for the user alone and one that only denies change
/// nothing. A lookup that stops is refused, naming where it stops and only a command that lets it
/// through, or why none does.
@Suite struct ClaudeAccessListTests {
    func runTool(_ tool: String, _ arguments: [String]) throws -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
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
            + (fix ?? "Run `chmod -N \(target)` in Terminal to drop every entry of its access list.")
    }

    func folderText(_ folder: String = "~/.local/bin", fix: String? = nil) -> String {
        "Refused ~/.local/bin/claude: its folder's access list lets another user or group change it, or cannot be read. "
            + (fix ?? "Run `chmod -N \(folder)` in Terminal to drop every entry of its access list.")
    }

    /// What a refusal says when the lookup stops, of the binary or of its folder.
    func stopText(_ because: String, fix: String?, folder: Bool = false, shown: String? = nil)
        -> String
    {
        "Refused \(shown ?? "~/.local/bin/claude"): \(folder ? "its folder" : "it") cannot be checked, because \(because)."
            + (fix.map {
                " Run `\($0)` in Terminal"
                    + ($0.contains("chmod -N") ? " to drop every entry of its access list." : ".")
            } ?? "")
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
        // Denying `readsecurity` too stops the lookup at the folder itself; `chmod -N` clears it.
        try add("user:\(me) deny search,readsecurity", versions)
        #expect(
            refusal(t)
                == stopText(
                    "you cannot read the attributes of `\(place)`", fix: "chmod -N \(place)"))
        #expect(try chmodRun(["-N", versions.path]) == 0)
        #expect(refusal(t) == nil)
        // A mode that keeps its owner out gets `chmod u+x`, which run as printed lets it through.
        #expect(chmod(versions.path, 0o600) == 0)
        let closed = stopText("you cannot search the folder `\(place)`", fix: "chmod u+x \(place)")
        #expect(refusal(t) == closed)
        // The same file named directly gets the same answer.
        let direct = ClaudeRunner(
            context: t.context, candidates: [versions.appendingPathComponent("2.1.0")])
        #expect(
            refusal(direct)
                == stopText(
                    "you cannot search the folder `\(place)`", fix: "chmod u+x \(place)",
                    shown: "\(place)/2.1.0"))
        #expect(try chmodRun(["u+x", versions.path]) == 0)
        #expect(refusal(t) == nil)
        // `~/.local/bin` itself, locked too, gets the `chflags` first.
        #expect(chmod(localBin(t).path, 0o600) == 0)
        #expect(try chflagsRun(["uchg", localBin(t).path]) == 0)
        #expect(
            refusal(t)
                == stopText("you cannot search the folder `~/.local/bin`", fix: nil)
                + " Run `chflags nouchg ~/.local/bin`, then `chmod u+x ~/.local/bin` in Terminal.")
        #expect(try chflagsRun(["nouchg", localBin(t).path]) == 0)
        #expect(try chmodRun(["u+x", localBin(t).path]) == 0)
        #expect(refusal(t) == nil)
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
        // A target the user cannot open either: its owner is unread, so the user's own command
        // is named for when it is the user's.
        do {
            let t = try TestHome()
            defer { clear(t) }
            let real = try linkInstall(t, target)
            try add("user:\(me) deny read,readattr", real)
            #expect(
                refusal(t)
                    == stopText("you cannot read the attributes of `~/\(target)`", fix: nil)
                    + " If you own it, run `chmod -N ~/\(target)` in Terminal to drop every entry of its access list."
            )
            #expect(try chmodRun(["-N", real.path]) == 0)
            #expect(refusal(t) == nil)
        }
        // `chmod -h -N` clears the link's own list and keeps its target's, unlike `chmod -N`.
        do {
            let t = try TestHome()
            defer {
                clearLinkList(t.fakePath)
                clear(t)
            }
            let real = try linkInstall(t, target)
            try add("everyone deny delete", real)
            #expect(try chmodRun(["-h", "+a", "user:\(me) deny readattr", t.fakePath.path]) == 0)
            #expect(
                refusal(t)
                    == stopText(
                        "you cannot read the attributes of the link `~/.local/bin/claude`",
                        fix: nil)
                    + " If you own it, run `chmod -h -N ~/.local/bin/claude` in Terminal to drop every entry of its access list."
            )
            #expect(try chmodRun(["-h", "-N", t.fakePath.path]) == 0)
            #expect(refusal(t) == nil)
            #expect(AccessList.hasList(path: real.path))
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
                refusal(t)
                    == stopText("you cannot read the link `~/.local/bin/claude`", fix: nil)
                    + " No chmod can clear the access list of a link you cannot read.",
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
                let fix =
                    "Run `chflags no\(flag) \(place)`, then `chmod -N \(place)` in Terminal to drop every entry of its access list."
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
                + " Run `chflags \(unlock) \(place)`, then `chmod -N \(place)` in Terminal to drop every entry of its access list."
            #expect(refusal(t) == wanted, "\(name)")
            // The lock keeps `chmod -N` alone from clearing the list.
            #expect(try chmodRun(["-N", folder.path]) != 0, "\(name)")
            #expect(refusal(t) == wanted, "\(name)")
            #expect(try chflagsRun([unlock, folder.path]) == 0, "\(name)")
            #expect(try chmodRun(["-N", folder.path]) == 0, "\(name)")
            #expect(refusal(t) == nil, "\(name)")
        }
    }

    /// The rights bits that change nothing, by number: `read` (`list`), `execute` (`search`),
    /// `readattr`, `readextattr`, `readsecurity` and `synchronize`.
    static let passingBits: Set<Int> = [1, 3, 7, 9, 11, 20]

    @Test func eachRightsBitAloneOnTheBinaryOrLocalBinGetsTheChecksAnswer() throws {
        for onFolder in [false, true] {
            for bit in 0..<32 {
                let name = "bit \(bit) on folder \(onFolder)"
                let t = try TestHome()
                defer { clear(t) }
                try t.installFake()
                try addRaw(UInt32(1) << UInt32(bit), onFolder ? localBin(t) : t.fakePath)
                let refused = onFolder ? folderText() : binaryText("~/.local/bin/claude")
                #expect(refusal(t) == (Self.passingBits.contains(bit) ? nil : refused), "\(name)")
            }
        }
    }

    @Test func aLockedEntryWhoseAttributesTheUserCannotReadNamesNoCommand() throws {
        for onFolder in [false, true] {
            let t = try TestHome()
            let url = onFolder ? localBin(t) : t.fakePath
            defer {
                // The `chflags` command cannot read such an entry, so the call clears its lock.
                _ = chflags(url.path, 0)
                clear(t)
            }
            try t.installFake()
            try add("user:\(me) deny readattr", url)
            #expect(chflags(url.path, UInt32(UF_IMMUTABLE)) == 0, "folder \(onFolder)")
            let place = onFolder ? "~/.local/bin" : "~/.local/bin/claude"
            #expect(
                refusal(t)
                    == stopText(
                        "you cannot read the attributes of `\(place)`", fix: nil, folder: onFolder)
                    + " A flag on it may keep its list from being changed, and the chflags command cannot read it to clear that flag.",
                "folder \(onFolder)")
            #expect(try chflagsRun(["nouchg", url.path]) != 0, "folder \(onFolder)")
        }
    }

    @Test func aStopThatNoListOrModeMakesNamesNoChmod() throws {
        let t = try TestHome()
        defer { clear(t) }
        try t.installFake()
        let path = t.fakePath.path
        // EPERM is a system policy's, such as a sandbox profile's, which no `chmod` clears.
        #expect(FileFacts.unreadable(path, error: EPERM) == .policy(path: path))
        #expect(
            FileFacts.unreadable(path, error: EACCES)
                == .unreadable(path: path, isLink: false, clearedBy: .user, identity: .notAFolder))
        let text = t.runner.uncheckedText(
            "~/.local/bin/claude", .policy(path: path), ofFolder: false)
        #expect(
            text
                == "Refused ~/.local/bin/claude: it cannot be checked, because a system policy, such as a sandbox profile, keeps you from `~/.local/bin/claude`, and no chmod clears that."
        )
        #expect(!text.contains("chmod -N"))
    }

    @Test func aHomeFolderIsNeverOfferedChmodNButWhatToCheck() throws {
        let check =
            "Check its access list with `ls -led ~`: clearing the whole list would also drop the entry macOS keeps on a home folder."
        // A home the user cannot search.
        do {
            let t = try TestHome()
            defer { clear(t) }
            try t.installFake()
            try add("user:\(me) deny search", t.home)
            #expect(
                refusal(t)
                    == stopText("you cannot search the folder `~`", fix: nil, folder: true) + " "
                    + check)
        }
        // A home that holds the real target, whose list lets others change it.
        let t = try TestHome()
        defer { clear(t) }
        _ = try linkInstall(t, "claude")
        try add("everyone allow add_file", t.home)
        #expect(
            refusal(t)
                == "Refused ~/.local/bin/claude: the access list of its real target's folder `~` lets another user or group change it, or cannot be read. "
                + check)
        let home = FileFacts.identity(t.home.path, options: O_DIRECTORY)
        #expect(
            t.runner.clearSentence(t.home.path, home, ownerIsUser: true, unlocking: []) == check)
    }

    /// Makes `real/home` in a fresh folder spelled by its real path, so no link is above it, and
    /// a home that spells it as `layout` says: directly, through a link to the folder that holds
    /// it, or as a link to it, each link naming `real` as `folder` spells it, with the fake
    /// `claude` at its `.local/bin/claude`.
    func makeHome(_ base: TestHome, _ layout: String, folder: String = "real") throws -> (
        home: TestHome, real: URL
    ) {
        let root = URL(fileURLWithPath: try #require(FileFacts.resolve(base.home.path)))
        let real = root.appendingPathComponent("real/home")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        var spelled = real
        if layout == "linked folder" {
            let link = root.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(
                atPath: link.path, withDestinationPath: folder)
            spelled = link.appendingPathComponent("home")
        } else if layout == "linked home" {
            spelled = root.appendingPathComponent("homelink")
            try FileManager.default.createSymbolicLink(
                atPath: spelled.path, withDestinationPath: folder + "/home")
        }
        let home = TestHome.wrapping(spelled, fixtures: base.fixtures)
        try home.installFake()
        return (home, real)
    }

    @Test func aHomeWhoseAttributesCannotBeReadGetsNoCommandThroughItsLinksOrNot() throws {
        let unread =
            "Reading its list needs that right too, so `ls -led ~` fails, and `chmod -a` cannot remove one entry: it fails, and empties the list when you own it. Clearing the whole list would also drop the entry macOS keeps on a home folder."
        for layout in ["direct", "linked folder", "linked home"] {
            for denied in ["readattr", "read,readattr"] {
                let name = "\(layout), \(denied) denied"
                let base = try TestHome()
                let (t, real) = try makeHome(base, layout)
                defer {
                    _ = try? chmodRun(["-N", real.path])
                    clear(base)
                }
                // An entry like the one macOS keeps on a home folder, then the user's own.
                try add("everyone deny delete", real)
                try add("user:\(me) deny \(denied)", real)
                let text = refusal(t)
                #expect(
                    text
                        == stopText(
                            "you cannot read the attributes of `~`", fix: nil, folder: true,
                            shown: t.context.display(t.fakePath)) + " " + unread, "\(name)")
                #expect(text?.contains("chmod -N") == false, "\(name)")
                // As the text says, `chmod -a` fails and empties the list.
                #expect(
                    try chmodRun(["-a", "user:\(me) deny \(denied)", real.path]) != 0, "\(name)")
                #expect(!AccessList.hasList(path: real.path), "\(name)")
                #expect(refusal(t) == nil, "\(name)")
            }
        }
    }

    @Test func aListThatDeniesReadingItStillCountsAsAList() throws {
        let t = try TestHome()
        defer { clear(t) }
        let folder = t.home.appendingPathComponent("vault")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(!AccessList.hasList(path: folder.path))
        try add("user:\(me) deny readsecurity", folder)
        #expect(AccessList.hasList(path: folder.path))
        #expect(try chmodRun(["-N", folder.path]) == 0)
        #expect(!AccessList.hasList(path: folder.path))
    }

    @Test func aHomeSpelledInOtherLetterCaseIsKnownByItsDeviceAndInode() throws {
        for layout in ["linked folder", "linked home"] {
            for denied in ["readattr", "search", "read,readattr"] {
                let name = "\(layout), \(denied) denied"
                let base = try TestHome()
                let (t, real) = try makeHome(base, layout, folder: "REAL")
                defer {
                    _ = try? chmodRun(["-N", real.path])
                    clear(base)
                }
                let spelled = real.deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent("REAL/home").path
                // The volume ignores letter case, so the lookup reaches the home as `REAL/home`.
                try #require(FileManager.default.fileExists(atPath: spelled))
                try add("everyone deny delete", real)
                try add("user:\(me) deny \(denied)", real)
                let place = PickService.shellQuote(spelled)
                let drop =
                    "clearing the whole list would also drop the entry macOS keeps on a home folder."
                let because: String
                let check: String
                if denied == "search" {
                    because = "you cannot search the folder `\(place)`"
                    check = "Check its access list with `ls -led \(place)`: " + drop
                } else {
                    because = "you cannot read the attributes of `\(place)`"
                    // With listing denied too, neither it nor the home can be opened.
                    let reason =
                        denied == "readattr"
                        ? "C" + drop.dropFirst()
                        : "Whether it is your home folder cannot be checked, and " + drop
                    check =
                        "Reading its list needs that right too, so `ls -led \(place)` fails, and `chmod -a` cannot remove one entry: it fails, and empties the list when you own it. "
                        + reason
                }
                let text = refusal(t)
                #expect(
                    text
                        == stopText(
                            because, fix: nil, folder: true,
                            shown: t.context.display(t.fakePath)) + " " + check, "\(name)")
                #expect(text?.contains("chmod -N") == false, "\(name)")
                #expect(
                    (try runTool("/bin/ls", ["-led", spelled]) == 0) == (denied == "search"),
                    "\(name)")
                #expect(AccessList.hasList(path: real.path), "\(name)")
            }
        }
    }

    @Test func aLinkThatLeadsToTheHomeGetsNoCommandHoweverItIsSpelled() throws {
        let leads =
            "It leads to your home folder, so no command is named for it: one that follows the link acts on the home folder itself."
        // The home a link that denies reading its attributes, written with a slash after it.
        do {
            let base = try TestHome()
            let (linked, real) = try makeHome(base, "linked home")
            let t = TestHome.wrapping(
                URL(fileURLWithPath: linked.home.path + "/", isDirectory: true),
                fixtures: base.fixtures)
            defer {
                clearLinkList(linked.home)
                _ = try? chmodRun(["-N", real.path])
                clear(base)
            }
            try add("everyone deny delete", real)
            #expect(
                try chmodRun(["-h", "+a", "user:\(me) deny readattr", linked.home.path]) == 0)
            let text = refusal(t)
            #expect(
                text
                    == stopText(
                        "you cannot read the attributes of the link `~`", fix: nil, folder: true,
                        shown: t.context.display(t.fakePath)) + " " + leads)
            #expect(text?.contains("chmod") == false)
        }
        // Another link to the home, its target in other letter case, on the way to the binary.
        do {
            let base = try TestHome()
            let (t, real) = try makeHome(base, "direct")
            let alias = real.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("alias")
            defer {
                clearLinkList(alias)
                _ = try? chmodRun(["-N", real.path])
                clear(base)
            }
            try FileManager.default.createSymbolicLink(
                atPath: alias.path, withDestinationPath: "REAL/home")
            try FileManager.default.moveItem(
                at: t.fakePath, to: real.appendingPathComponent("claude-2.1.0"))
            try FileManager.default.createSymbolicLink(
                atPath: t.fakePath.path,
                withDestinationPath: alias.appendingPathComponent("claude-2.1.0").path)
            #expect(refusal(t) == nil)
            try add("everyone deny delete", real)
            #expect(try chmodRun(["-h", "+a", "user:\(me) deny readattr", alias.path]) == 0)
            let text = refusal(t)
            #expect(
                text
                    == stopText(
                        "you cannot read the attributes of the link `\(PickService.shellQuote(alias.path))`",
                        fix: nil, shown: t.context.display(t.fakePath)) + " " + leads)
            #expect(text?.contains("chmod") == false)
        }
        // A link in the home keeps its `chmod -h -N`, which acts on it alone, slash or not.
        do {
            let base = try TestHome()
            let (linked, real) = try makeHome(base, "linked home")
            let written = linked.home.path + "/"
            let t = TestHome.wrapping(
                URL(fileURLWithPath: written, isDirectory: true), fixtures: base.fixtures)
            defer {
                clearLinkList(t.fakePath)
                _ = try? chmodRun(["-N", real.path])
                clear(base)
            }
            _ = try linkInstall(t, ".local/share/claude/versions/2.1.0")
            try add("everyone deny delete", real)
            #expect(try chmodRun(["-h", "+a", "user:\(me) deny readattr", t.fakePath.path]) == 0)
            #expect(
                refusal(t)
                    == stopText(
                        "you cannot read the attributes of the link `~/.local/bin/claude`",
                        fix: nil, shown: t.context.display(t.fakePath))
                    + " If you own it, run `chmod -h -N ~/.local/bin/claude` in Terminal to drop every entry of its access list."
            )
            // Run as a shell expands it, with the slash the home is written with.
            #expect(try chmodRun(["-h", "-N", written + "/.local/bin/claude"]) == 0)
            #expect(refusal(t) == nil)
            #expect(AccessList.hasList(path: real.path))
        }
    }

    @Test func aHomeSpelledThroughTheDataVolumeIsKnownWhenItsListIsJudged() throws {
        let base = try TestHome()
        defer { clear(base) }
        let root = try #require(FileFacts.resolve(base.home.path))
        // macOS reaches each folder of its data volume through `/System/Volumes/Data` too.
        let data = "/System/Volumes/Data" + root
        let identity = FileFacts.identity(root, options: O_DIRECTORY)
        try #require(identity != nil && FileFacts.identity(data, options: O_DIRECTORY) == identity)
        let real = URL(fileURLWithPath: root).appendingPathComponent("home")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let t = TestHome.wrapping(
            URL(fileURLWithPath: data).appendingPathComponent("home"), fixtures: base.fixtures)
        // The link names the home by the shorter path, which its real path keeps.
        _ = try linkInstall(t, "claude", linkText: real.appendingPathComponent("claude").path)
        #expect(refusal(t) == nil)
        try add("everyone allow add_file", real)
        let place = PickService.shellQuote(real.path)
        let text = refusal(t)
        #expect(
            text
                == "Refused \(t.context.display(t.fakePath)): the access list of its real target's folder `\(place)` lets another user or group change it, or cannot be read. Check its access list with `ls -led \(place)`: clearing the whole list would also drop the entry macOS keeps on a home folder."
        )
        #expect(text?.contains("chmod -N") == false)
    }

    @Test func noFolderGetsChmodNWhileTheHomeCannotBeOpened() throws {
        let base = try TestHome()
        defer { clear(base) }
        let root = URL(fileURLWithPath: try #require(FileFacts.resolve(base.home.path)))
        let above = root.appendingPathComponent("above")
        let t = TestHome.wrapping(above.appendingPathComponent("home"), fixtures: base.fixtures)
        try t.installFake()
        // A folder above the home that the user cannot search keeps the home from being opened.
        try add("user:\(me) deny search", above)
        #expect(t.runner.homeIdentity == nil)
        #expect(FileFacts.resolve(t.home.path) == nil)
        let maybe =
            "hether it is your home folder cannot be checked, and clearing the whole list would also drop the entry macOS keeps on a home folder."
        let place = PickService.shellQuote(above.path)
        #expect(
            refusal(t)
                == stopText(
                    "you cannot search the folder `\(place)`", fix: nil, folder: true,
                    shown: t.context.display(t.fakePath))
                + " Check its access list with `ls -led \(place)`: w" + maybe
        )
        func text(_ stop: FileFacts.Stop) -> String {
            t.runner.uncheckedText("~/.local/bin/claude", stop, ofFolder: false)
        }
        let refused = "Refused ~/.local/bin/claude: it cannot be checked, because "
        // A folder whose attributes cannot be read cannot be told from the home either.
        let folder = PickService.shellQuote(root.path)
        let home = FileFacts.identity(root.path, options: O_DIRECTORY)
        #expect(
            text(
                .unreadable(
                    path: root.path, isLink: false, clearedBy: .unreadOwner, identity: home))
                == refused
                + "you cannot read the attributes of `\(folder)`. Reading its list needs that right too, so `ls -led \(folder)` fails, and `chmod -a` cannot remove one entry: it fails, and empties the list when you own it. W"
                + maybe)
        // A file, or a link that leads to one, is never the home folder and keeps its command.
        let file = root.appendingPathComponent("claude").path
        let typed = PickService.shellQuote(file)
        #expect(
            text(.unreadable(path: file, isLink: false, clearedBy: .user, identity: .notAFolder))
                == refused
                + "you cannot read the attributes of `\(typed)`. Run `chmod -N \(typed)` in Terminal to drop every entry of its access list."
        )
        let facts = FileFacts(
            realPath: file, ownerIsUserOrRoot: true, ownerIsUser: true, writableByOthers: false,
            listLetsOthersChange: true, flags: nil, isRegularFile: true, isExecutable: true,
            isSticky: false, identity: .notAFolder)
        #expect(
            t.runner.clearFix(facts)
                == "Run `chmod -N \(typed)` in Terminal to drop every entry of its access list.")
        #expect(
            text(
                .unreadable(
                    path: file, isLink: true, clearedBy: .unreadOwner, identity: .notAFolder))
                == refused
                + "you cannot read the attributes of the link `\(typed)`. If you own it, run `chmod -h -N \(typed)` in Terminal to drop every entry of its access list."
        )
        #expect(
            text(.unreadable(path: file, isLink: true, clearedBy: .unreadOwner, identity: home))
                == refused
                + "you cannot read the attributes of the link `\(typed)`. Whether it leads to your home folder cannot be checked, so no command is named for it."
        )
        #expect(try chmodRun(["-N", above.path]) == 0)
        #expect(refusal(t) == nil)
    }
}
