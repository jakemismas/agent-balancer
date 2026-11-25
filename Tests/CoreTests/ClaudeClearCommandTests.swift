import Foundation
import Testing

@testable import Core

/// The command a refusal of the `claude` binary names is typed as a person types it: a path in
/// the home folder after `~/`, any other path whole, quoted where a shell needs it, with `sudo`
/// first for an entry root owns and the `chflags` that a lock needs first; a lookup that stops
/// names where, and a command only when it lets the lookup through, or what keeps it.
@Suite struct ClaudeClearCommandTests {
    @Test func theCommandNamesThePathAsAPersonTypesIt() throws {
        let t = try TestHome()
        let runner = t.runner
        let home = t.home.path
        #expect(
            runner.clearCommand(home + "/bin/claude", ownerIsUser: true) == "chmod -N ~/bin/claude")
        #expect(
            runner.clearCommand(home + "/it's here/claude", ownerIsUser: true)
                == "chmod -N ~/'it'\\''s here/claude'")
        #expect(
            runner.clearCommand("/opt/my tools/claude", ownerIsUser: true)
                == "chmod -N '/opt/my tools/claude'")
        #expect(
            runner.clearCommand("/usr/local/bin/claude", ownerIsUser: false)
                == "sudo chmod -N /usr/local/bin/claude")
        // A path that only starts with the home's name is not in it.
        #expect(
            runner.clearCommand(home + "x/bin/claude", ownerIsUser: true)
                == "chmod -N \(home)x/bin/claude")
    }

    @Test func aRootOwnedFileIsNotTheUsers() throws {
        let facts = try #require(FileFacts.inspect(URL(fileURLWithPath: "/bin/ls")))
        #expect(facts.ownerIsUserOrRoot)
        #expect(!facts.ownerIsUser)
    }

    func facts(_ path: String, ownerIsUser: Bool, flags: UInt32 = 0) -> FileFacts {
        FileFacts(
            realPath: path, ownerIsUserOrRoot: true, ownerIsUser: ownerIsUser,
            writableByOthers: false, listLetsOthersChange: true,
            flags: NoFollowWriter.FileFlags(flags), isRegularFile: true, isExecutable: true,
            isSticky: false, identity: .notAFolder)
    }

    @Test func theFixClearsALockFirstAndNamesNoneForASystemFlag() throws {
        let t = try TestHome()
        let runner = t.runner
        let mine = t.home.path + "/.local/bin/claude"
        let root = "/usr/local/bin/claude"
        #expect(
            runner.clearFix(facts(mine, ownerIsUser: true))
                == "Run `chmod -N ~/.local/bin/claude` in Terminal to drop every entry of its access list."
        )
        #expect(
            runner.clearFix(facts(root, ownerIsUser: false))
                == "Run `sudo chmod -N /usr/local/bin/claude` in Terminal to drop every entry of its access list."
        )
        #expect(
            runner.clearFix(facts(mine, ownerIsUser: true, flags: UInt32(UF_IMMUTABLE)))
                == "Run `chflags nouchg ~/.local/bin/claude`, then `chmod -N ~/.local/bin/claude` in Terminal to drop every entry of its access list."
        )
        #expect(
            runner.clearFix(
                facts(root, ownerIsUser: false, flags: UInt32(UF_IMMUTABLE | UF_APPEND)))
                == "Run `sudo chflags nouchg,nouappnd /usr/local/bin/claude`, then `sudo chmod -N /usr/local/bin/claude` in Terminal to drop every entry of its access list."
        )
        #expect(
            runner.clearFix(facts(mine, ownerIsUser: true, flags: UInt32(SF_IMMUTABLE)))
                == "A system flag keeps that list from being cleared, and only an administrator can clear that flag."
        )
    }

    @Test func aStopNamesWhereTheLookupStopsAndOnlyACommandThatLetsItThrough() throws {
        let t = try TestHome()
        let runner = t.runner
        let home = t.home.path
        let shown = "~/.local/bin/claude"
        func text(_ stop: FileFacts.Stop, folder: Bool = false) -> String {
            runner.uncheckedText(shown, stop, ofFolder: folder)
        }
        // A folder that is not the home, which only a stop that knows so gets a command for.
        let other = FileFacts.Identity.folder(device: 0, inode: 0)
        #expect(
            text(
                .unsearchable(
                    path: home + "/.local/bin", clearedBy: .user, unlocking: [], identity: other))
                == "Refused ~/.local/bin/claude: it cannot be checked, because you cannot search the folder `~/.local/bin`. Run `chmod -N ~/.local/bin` in Terminal to drop every entry of its access list."
        )
        #expect(
            text(
                .unsearchable(
                    path: home + "/.local/bin", clearedBy: .user, unlocking: ["uchg", "uappnd"],
                    identity: other))
                == "Refused ~/.local/bin/claude: it cannot be checked, because you cannot search the folder `~/.local/bin`. Run `chflags nouchg,nouappnd ~/.local/bin`, then `chmod -N ~/.local/bin` in Terminal to drop every entry of its access list."
        )
        #expect(
            text(.unsearchable(path: "/opt/vault", clearedBy: nil, unlocking: []), folder: true)
                == "Refused ~/.local/bin/claude: its folder cannot be checked, because you cannot search the folder `/opt/vault`."
        )
        // Where no command of the user's clears a stop, the text says what keeps it.
        #expect(
            text(
                .unsearchable(path: "/opt/vault", clearedBy: nil, unlocking: [], heldBy: .owner),
                folder: true)
                == "Refused ~/.local/bin/claude: its folder cannot be checked, because you cannot search the folder `/opt/vault`. Only its owner or an administrator can change it."
        )
        #expect(
            text(
                .unsearchable(
                    path: home + "/vault", clearedBy: nil, unlocking: [], heldBy: .systemFlag))
                == "Refused ~/.local/bin/claude: it cannot be checked, because you cannot search the folder `~/vault`. A system flag on it may keep it from being changed, and only an administrator can clear that flag."
        )
        #expect(
            text(
                .unreadable(
                    path: home + "/vault", isLink: false, clearedBy: nil, heldBy: .unreadLock))
                == "Refused ~/.local/bin/claude: it cannot be checked, because you cannot read the attributes of `~/vault`. A flag on it may keep its list from being changed, and the chflags command cannot read it to clear that flag."
        )
        #expect(
            text(.unreadable(path: "/opt/vault", isLink: false, clearedBy: nil, heldBy: .owner))
                == "Refused ~/.local/bin/claude: it cannot be checked, because you cannot read the attributes of `/opt/vault`. Only its owner or an administrator can change it."
        )
        #expect(
            text(
                .unreadable(
                    path: "/usr/local/bin/claude", isLink: false, clearedBy: .root,
                    identity: .notAFolder))
                == "Refused ~/.local/bin/claude: it cannot be checked, because you cannot read the attributes of `/usr/local/bin/claude`. Run `sudo chmod -N /usr/local/bin/claude` in Terminal to drop every entry of its access list."
        )
        #expect(
            text(.unreadable(path: home + "/.local/bin/claude", isLink: true, clearedBy: nil))
                == "Refused ~/.local/bin/claude: it cannot be checked, because you cannot read the link `~/.local/bin/claude`. No chmod can clear the access list of a link you cannot read."
        )
        #expect(
            text(.unknown(path: home + "/.local/bin/claude"))
                == "Refused ~/.local/bin/claude: it cannot be checked.")
    }

    @Test func aFolderTheUserCannotSearchGetsACommandOnlyWhenTheUserCanClearItsListAndLock() {
        /// What `stat` gives for a folder, the user's and open to its owner unless said.
        func folder(uid: uid_t = getuid(), mode: mode_t = S_IFDIR | 0o700, flags: Int32 = 0)
            -> stat
        {
            var st = stat()
            st.st_uid = uid
            st.st_mode = mode
            st.st_flags = UInt32(flags)
            return st
        }
        let path = "/scratch/folder"
        func stop(_ st: stat?, error: Int32 = EACCES, listed: Bool = true) -> FileFacts.Stop {
            FileFacts.unsearchable(path, error: error, st: st, listed: listed)
        }
        func cleared(_ unlocking: [String]) -> FileFacts.Stop {
            .unsearchable(path: path, clearedBy: .user, unlocking: unlocking)
        }
        func held(_ holder: FileFacts.Holder?) -> FileFacts.Stop {
            .unsearchable(path: path, clearedBy: nil, unlocking: [], heldBy: holder)
        }
        #expect(stop(folder()) == cleared([]))
        #expect(stop(folder(flags: UF_IMMUTABLE)) == cleared(["uchg"]))
        #expect(stop(folder(flags: UF_APPEND)) == cleared(["uappnd"]))
        #expect(stop(folder(flags: UF_IMMUTABLE | UF_APPEND)) == cleared(["uchg", "uappnd"]))
        // Only an administrator can clear a system flag, so none is named, a user lock or not.
        for flags in [SF_IMMUTABLE, SF_APPEND, SF_NOUNLINK, SF_IMMUTABLE | UF_IMMUTABLE] {
            #expect(stop(folder(flags: flags)) == held(.systemFlag), "\(flags)")
        }
        // Flags that cannot be read and an owner but the user name none either.
        #expect(stop(nil) == held(nil))
        #expect(stop(folder(uid: 0)) == held(.owner))
        #expect(stop(folder(uid: getuid() + 1)) == held(.owner))
        #expect(stop(folder(uid: 0, flags: SF_IMMUTABLE)) == held(.owner))
        // A mode that keeps the owner out gets `chmod u+x`, after the `chflags` a lock needs.
        let closed = FileFacts.Stop.closedByMode(path: path, unlocking: [])
        #expect(stop(folder(mode: S_IFDIR | 0o600)) == closed)
        #expect(stop(folder(mode: S_IFDIR | 0o600), listed: false) == closed)
        #expect(
            stop(folder(mode: S_IFDIR | 0o600, flags: UF_IMMUTABLE))
                == .closedByMode(path: path, unlocking: ["uchg"]))
        // A denial with no list and a mode that lets the owner in, and EPERM, are a policy's.
        #expect(stop(folder(), listed: false) == .policy(path: path))
        #expect(stop(folder(), error: EPERM) == .policy(path: path))
        #expect(stop(folder(mode: S_IFDIR | 0o600), error: EPERM) == .policy(path: path))
    }

    @Test func anEntryWhoseAttributesTheUserCannotReadGetsACommandOnlyWhenItsOwnerAndFlagsLetIt() {
        /// What the `fstat` of an events-only open gives for a file, the user's unless said.
        func entry(uid: uid_t = getuid(), flags: Int32 = 0) -> stat {
            var st = stat()
            st.st_uid = uid
            st.st_mode = S_IFREG | 0o755
            st.st_flags = UInt32(flags)
            return st
        }
        let path = "/scratch/claude"
        func wanted(_ clearer: FileFacts.Clearer?, _ holder: FileFacts.Holder? = nil)
            -> FileFacts.Stop
        {
            .unreadable(
                path: path, isLink: false, clearedBy: clearer, heldBy: holder,
                identity: .notAFolder)
        }
        #expect(FileFacts.unreadable(path, st: entry()) == wanted(.user))
        #expect(FileFacts.unreadable(path, st: entry(uid: 0)) == wanted(.root))
        #expect(FileFacts.unreadable(path, st: entry(uid: getuid() + 1)) == wanted(nil, .owner))
        // A flag the chflags command cannot read to clear names none, whoever owns the entry.
        for flags in [UF_IMMUTABLE, UF_APPEND, SF_IMMUTABLE, SF_NOUNLINK] {
            for uid in [getuid(), 0, getuid() + 1] {
                #expect(
                    FileFacts.unreadable(path, st: entry(uid: uid, flags: flags))
                        == wanted(nil, .unreadLock), "\(flags) \(uid)")
            }
        }
        // A folder is known by its device and inode, which tell it from the home folder.
        var folder = entry()
        folder.st_mode = S_IFDIR | 0o700
        folder.st_dev = 7
        folder.st_ino = 9
        #expect(
            FileFacts.unreadable(path, st: folder)
                == .unreadable(
                    path: path, isLink: false, clearedBy: .user,
                    identity: .folder(device: 7, inode: 9)))
    }
}
