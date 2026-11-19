import Foundation
import Testing

@testable import Core

/// The command a refusal of the `claude` binary names is typed as a person types it: a path in
/// the home folder after `~/`, any other path whole, quoted where a shell needs it, with `sudo`
/// first for an entry root owns and the `chflags` that a lock needs first; a lookup that stops
/// names where, and a command only when it lets the lookup through.
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
            flags: NoFollowWriter.FileFlags(flags), isRegularFile: true, isExecutable: true)
    }

    @Test func theFixClearsALockFirstAndNamesNoneForASystemFlag() throws {
        let t = try TestHome()
        let runner = t.runner
        let mine = t.home.path + "/.local/bin/claude"
        let root = "/usr/local/bin/claude"
        #expect(
            runner.clearFix(facts(mine, ownerIsUser: true))
                == "Run `chmod -N ~/.local/bin/claude` in Terminal.")
        #expect(
            runner.clearFix(facts(root, ownerIsUser: false))
                == "Run `sudo chmod -N /usr/local/bin/claude` in Terminal.")
        #expect(
            runner.clearFix(facts(mine, ownerIsUser: true, flags: UInt32(UF_IMMUTABLE)))
                == "Run `chflags nouchg ~/.local/bin/claude`, then `chmod -N ~/.local/bin/claude` in Terminal."
        )
        #expect(
            runner.clearFix(
                facts(root, ownerIsUser: false, flags: UInt32(UF_IMMUTABLE | UF_APPEND)))
                == "Run `sudo chflags nouchg,nouappnd /usr/local/bin/claude`, then `sudo chmod -N /usr/local/bin/claude` in Terminal."
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
        #expect(
            text(.unsearchable(path: home + "/.local/bin", clearedBy: .user, unlocking: []))
                == "Refused ~/.local/bin/claude: it cannot be checked, because you cannot search the folder `~/.local/bin`. Run `chmod -N ~/.local/bin` in Terminal."
        )
        #expect(
            text(
                .unsearchable(
                    path: home + "/.local/bin", clearedBy: .user, unlocking: ["uchg", "uappnd"]))
                == "Refused ~/.local/bin/claude: it cannot be checked, because you cannot search the folder `~/.local/bin`. Run `chflags nouchg,nouappnd ~/.local/bin`, then `chmod -N ~/.local/bin` in Terminal."
        )
        #expect(
            text(.unsearchable(path: "/opt/vault", clearedBy: nil, unlocking: []), folder: true)
                == "Refused ~/.local/bin/claude: its folder cannot be checked, because you cannot search the folder `/opt/vault`."
        )
        #expect(
            text(.unreadable(path: "/usr/local/bin/claude", isLink: false, clearedBy: .root))
                == "Refused ~/.local/bin/claude: it cannot be checked, because you cannot read the attributes of `/usr/local/bin/claude`. Run `sudo chmod -N /usr/local/bin/claude` in Terminal."
        )
        #expect(
            text(.unreadable(path: home + "/.local/bin/claude", isLink: true, clearedBy: nil))
                == "Refused ~/.local/bin/claude: it cannot be checked, because you cannot read the link `~/.local/bin/claude`."
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
        func stop(_ st: stat?, error: Int32 = EACCES) -> FileFacts.Stop {
            FileFacts.unsearchable(path, error: error, st: st)
        }
        func cleared(_ unlocking: [String]) -> FileFacts.Stop {
            .unsearchable(path: path, clearedBy: .user, unlocking: unlocking)
        }
        let none = FileFacts.Stop.unsearchable(path: path, clearedBy: nil, unlocking: [])
        #expect(stop(folder()) == cleared([]))
        #expect(stop(folder(flags: UF_IMMUTABLE)) == cleared(["uchg"]))
        #expect(stop(folder(flags: UF_APPEND)) == cleared(["uappnd"]))
        #expect(stop(folder(flags: UF_IMMUTABLE | UF_APPEND)) == cleared(["uchg", "uappnd"]))
        // Only an administrator can clear a system flag, so none is named, a user lock or not.
        for flags in [SF_IMMUTABLE, SF_APPEND, SF_NOUNLINK, SF_IMMUTABLE | UF_IMMUTABLE] {
            #expect(stop(folder(flags: flags)) == none, "\(flags)")
        }
        // Flags that cannot be read, an owner but the user, a mode that keeps the owner out, and
        // a refusal that is not a list's name none either.
        #expect(stop(nil) == none)
        #expect(stop(folder(uid: 0)) == none)
        #expect(stop(folder(uid: getuid() + 1)) == none)
        #expect(stop(folder(mode: S_IFDIR | 0o600)) == none)
        #expect(stop(folder(), error: EPERM) == none)
    }
}
