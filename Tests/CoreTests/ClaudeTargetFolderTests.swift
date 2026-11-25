import Foundation
import Testing

@testable import Core

/// The runner refuses a `claude` whose real target sits in a folder that another user or group
/// can change, by its mode or by an access list entry, inherited or not, as it refuses
/// `~/.local/bin`, naming that folder and the command that clears it; a real target in one of
/// Homebrew's bin folders leaves that folder unjudged. The menu app's lookup of the command line
/// tool refuses a tool whose access list lets another user or group change it, or whose lookup
/// stops.
@Suite struct ClaudeTargetFolderTests {
    let base = ClaudeAccessListTests()
    let versions = ".local/share/claude/versions"
    let place = "~/.local/share/claude/versions"

    func modeText(_ place: String, fix: String?, shown: String = "~/.local/bin/claude") -> String {
        "Refused \(shown): its real target's folder `\(place)` must be owned by you or root and not writable by others."
            + (fix.map { " " + $0 } ?? "")
    }

    func listText(_ place: String, fix: String? = nil, shown: String = "~/.local/bin/claude")
        -> String
    {
        "Refused \(shown): the access list of its real target's folder `\(place)` lets another user or group change it, or cannot be read. "
            + (fix ?? "Run `chmod -N \(place)` in Terminal to drop every entry of its access list.")
    }

    func run(_ command: String) -> String {
        "Run `\(command)` in Terminal"
            + (command.contains("chmod -N") ? " to drop every entry of its access list." : ".")
    }

    /// Links `.local/bin/claude` to a copy of the fake at `relative`, and returns its folder.
    func install(_ t: TestHome, _ relative: String? = nil) throws -> URL {
        try base.linkInstall(t, relative ?? versions + "/2.1.0").deletingLastPathComponent()
    }

    @Test func aRealTargetsFolderThatGroupOrOthersCanWriteRefusesTheBinaryUntilChmodGoW() throws {
        for mode: mode_t in [0o777, 0o775, 0o757, 0o770, 0o1777] {
            let name = String(mode, radix: 8)
            let t = try TestHome()
            defer { base.clear(t) }
            let folder = try install(t)
            #expect(base.refusal(t) == nil, "\(name)")
            #expect(chmod(folder.path, mode) == 0, "\(name)")
            #expect(base.refusal(t) == modeText(place, fix: run("chmod go-w \(place)")), "\(name)")
            #expect(try base.chmodRun(["go-w", folder.path]) == 0, "\(name)")
            #expect(base.refusal(t) == nil, "\(name)")
        }
        // A folder a shell quotes, and the home itself.
        let cases: [(relative: String, typed: String)] = [
            ("my tools/claude", "~/'my tools'"), ("claude", "~"),
        ]
        for item in cases {
            let t = try TestHome()
            defer {
                _ = chmod(t.home.path, 0o755)
                base.clear(t)
            }
            let folder = try install(t, item.relative)
            #expect(chmod(folder.path, 0o777) == 0, "\(item.relative)")
            #expect(
                base.refusal(t) == modeText(item.typed, fix: run("chmod go-w \(item.typed)")),
                "\(item.relative)")
            #expect(try base.chmodRun(["go-w", folder.path]) == 0, "\(item.relative)")
            #expect(base.refusal(t) == nil, "\(item.relative)")
        }
    }

    @Test func aRightThatChangesTheRealTargetsFolderRefusesTheBinaryForAnyoneButTheUser() throws {
        for right in base.folderRights {
            for who in base.others {
                for inherited in [false, true] {
                    let entry = "\(who) allow \(right)"
                    let name = "\(entry) inherited \(inherited)"
                    let t = try TestHome()
                    defer { base.clear(t) }
                    let folder = try install(t)
                    try base.add(entry, folder, inherited: inherited)
                    #expect(base.refusal(t) == listText(place), "\(name)")
                    #expect(try base.chmodRun(["-N", folder.path]) == 0, "\(name)")
                    #expect(base.refusal(t) == nil, "\(name)")
                }
            }
        }
        let t = try TestHome()
        defer { base.clear(t) }
        let folder = try install(t)
        // An entry that only passes on hands its right to each entry made in the folder later.
        try base.add("everyone allow add_file,file_inherit,only_inherit", folder)
        #expect(base.refusal(t) == listText(place))
        #expect(try base.chmodRun(["-N", folder.path]) == 0)
        // Entries that only let others list and search it, allow only the user, or only deny.
        let looks = "list,search,readattr,readextattr,readsecurity,file_inherit,directory_inherit"
        let changes = base.folderRights.joined(separator: ",")
        try base.add("everyone allow \(looks)", folder)
        try base.add("user:nobody allow \(looks)", folder, inherited: true)
        try base.add("user:\(base.me) allow \(changes)", folder)
        try base.add("user:daemon deny \(changes)", folder)
        #expect(base.refusal(t) == nil)
        #expect(try t.runner.run(arguments: ["--version"]).status == 0)
    }

    @Test func aLockedRealTargetsFolderNamesTheFlagToClearFirst() throws {
        for flag in ["uchg", "uappnd"] {
            for byMode in [true, false] {
                let name = "\(flag) by mode \(byMode)"
                let t = try TestHome()
                defer { base.clear(t) }
                let folder = try install(t)
                if byMode {
                    #expect(chmod(folder.path, 0o777) == 0, "\(name)")
                } else {
                    try base.add("everyone allow add_file", folder)
                }
                #expect(try base.chflagsRun([flag, folder.path]) == 0, "\(name)")
                let change = byMode ? "go-w" : "-N"
                let fix =
                    "Run `chflags no\(flag) \(place)`, then `chmod \(change) \(place)` in Terminal"
                    + (byMode ? "." : " to drop every entry of its access list.")
                let wanted = byMode ? modeText(place, fix: fix) : listText(place, fix: fix)
                #expect(base.refusal(t) == wanted, "\(name)")
                // The lock keeps the `chmod` alone from clearing it.
                #expect(try base.chmodRun([change, folder.path]) != 0, "\(name)")
                #expect(base.refusal(t) == wanted, "\(name)")
                #expect(try base.chflagsRun(["no" + flag, folder.path]) == 0, "\(name)")
                #expect(try base.chmodRun([change, folder.path]) == 0, "\(name)")
                #expect(base.refusal(t) == nil, "\(name)")
            }
        }
    }

    @Test func aRealTargetsFolderWhoseListTheUserCannotReadRefusesTheBinary() throws {
        let t = try TestHome()
        defer { base.clear(t) }
        let folder = try install(t)
        try base.add("user:\(base.me) deny readsecurity", folder)
        #expect(
            base.refusal(t)
                == "Refused ~/.local/bin/claude: its real target's folder `\(place)` cannot be checked, because you cannot read the attributes of `\(place)`. "
                + run("chmod -N \(place)"))
        #expect(try base.chmodRun(["-N", folder.path]) == 0)
        #expect(base.refusal(t) == nil)
    }

    @Test func aRealTargetInAFolderOfRootsThatOthersCanWriteNamesNoCommand() throws {
        // Such a folder, like `/tmp`, is shared on purpose, so no `chmod` of it is named.
        var st = stat()
        try #require(stat("/private/tmp", &st) == 0)
        try #require(st.st_uid == 0 && st.st_mode & 0o002 != 0)
        let t = try TestHome()
        defer { base.clear(t) }
        try t.installFake()
        let real = URL(fileURLWithPath: "/private/tmp/ab-claude-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: t.fakePath, to: real)
        defer { try? FileManager.default.removeItem(at: real) }
        try FileManager.default.createSymbolicLink(at: t.fakePath, withDestinationURL: real)
        #expect(base.refusal(t) == modeText("/private/tmp", fix: nil))
    }

    @Test func homebrewsBinFoldersStayUnjudgedButARealTargetsFolderBeyondThemIsJudged() throws {
        // A real target in a Homebrew bin folder, found there or through `~/.local/bin`.
        do {
            let t = try TestHome()
            defer { base.clear(t) }
            try t.installFake()
            let brew = t.home.appendingPathComponent("brew/bin")
            try FileManager.default.createDirectory(at: brew, withIntermediateDirectories: true)
            let real = brew.appendingPathComponent("claude")
            try FileManager.default.moveItem(at: t.fakePath, to: real)
            try FileManager.default.createSymbolicLink(at: t.fakePath, withDestinationURL: real)
            #expect(chmod(brew.path, 0o775) == 0)
            try base.add("everyone allow add_file,delete_child", brew)
            for candidates in [[t.fakePath, real], [real]] {
                let runner = ClaudeRunner(context: t.context, candidates: candidates)
                #expect(try runner.locate().path == candidates[0].path)
            }
        }
        // A link in a Homebrew bin folder to a real target elsewhere, as a cask installs it.
        let t = try TestHome()
        defer { base.clear(t) }
        try t.installFake()
        let brew = t.home.appendingPathComponent("brew/bin")
        let cask = t.home.appendingPathComponent("cask/claude-code/2.1.0")
        for folder in [brew, cask] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let real = cask.appendingPathComponent("claude")
        try FileManager.default.moveItem(at: t.fakePath, to: real)
        let linked = brew.appendingPathComponent("claude")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: real)
        let runner = ClaudeRunner(context: t.context, candidates: [linked])
        let shown = "~/brew/bin/claude"
        let caskPlace = "~/cask/claude-code/2.1.0"
        #expect(base.refusal(runner) == nil)
        #expect(chmod(cask.path, 0o775) == 0)
        #expect(
            base.refusal(runner)
                == modeText(caskPlace, fix: run("chmod go-w \(caskPlace)"), shown: shown))
        #expect(try base.chmodRun(["go-w", cask.path]) == 0)
        try base.add("group:staff allow add_file", cask)
        #expect(base.refusal(runner) == listText(caskPlace, shown: shown))
        #expect(try base.chmodRun(["-N", cask.path]) == 0)
        #expect(base.refusal(runner) == nil)
    }

    @Test func theMenuAppsLookupOfTheToolRefusesAListThatLetsOthersChangeItOrALookupThatStops()
        throws
    {
        let t = try TestHome()
        defer { base.clear(t) }
        let bin = t.home.appendingPathComponent("bin")
        let cellar = t.home.appendingPathComponent("Cellar/agent-balancer/1.1.0/bin")
        for folder in [bin, cellar] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let real = cellar.appendingPathComponent("agent-balancer")
        try "#!/bin/sh\nexit 0\n".write(to: real, atomically: true, encoding: .utf8)
        #expect(chmod(real.path, 0o755) == 0)
        let tool = bin.appendingPathComponent("agent-balancer")
        try FileManager.default.createSymbolicLink(at: tool, withDestinationURL: real)
        let runner = CLIRunner(context: t.context, candidates: [tool])
        func refusal() -> String? {
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
        #expect(refusal() == nil)
        let typed = "~/Cellar/agent-balancer/1.1.0/bin/agent-balancer"
        let shared =
            "Refused ~/bin/agent-balancer: its real target's access list lets another user or group change it, or cannot be read. "
            + run("chmod -N \(typed)")
        let entries = [
            "everyone allow write", "group:staff allow append", "user:nobody allow delete",
            "everyone allow writesecurity", "everyone allow chown",
        ]
        for entry in entries {
            try base.add(entry, real)
            #expect(refusal() == shared, "\(entry)")
            #expect(!runner.isAvailable, "\(entry)")
            #expect(throws: ToolError.self, "\(entry)") { try runner.run(["status"]) }
            #expect(try base.chmodRun(["-N", real.path]) == 0, "\(entry)")
            #expect(refusal() == nil, "\(entry)")
        }
        // An entry that only lets others read and run it changes nothing, and no folder is judged.
        try base.add("everyone allow read,execute,readattr,readextattr,readsecurity", real)
        #expect(chmod(bin.path, 0o775) == 0)
        for folder in [bin, cellar] {
            try base.add("everyone allow add_file,delete_child", folder)
        }
        #expect(refusal() == nil)
        #expect(try runner.run(["status"]).status == 0)
        for url in [real, bin, cellar] {
            #expect(try base.chmodRun(["-N", url.path]) == 0, "\(url.lastPathComponent)")
        }
        // A list the user cannot read, and a lookup that stops, are refused, not skipped.
        try base.add("user:\(base.me) deny readsecurity", real)
        #expect(
            refusal()
                == "Refused ~/bin/agent-balancer: it cannot be checked, because you cannot read the attributes of `\(typed)`. "
                + run("chmod -N \(typed)"))
        #expect(try base.chmodRun(["-N", real.path]) == 0)
        try base.add("user:\(base.me) deny search", cellar)
        let folder = "~/Cellar/agent-balancer/1.1.0/bin"
        #expect(
            refusal()
                == "Refused ~/bin/agent-balancer: it cannot be checked, because you cannot search the folder `\(folder)`. "
                + run("chmod -N \(folder)"))
        #expect(try base.chmodRun(["-N", cellar.path]) == 0)
        #expect(refusal() == nil)
    }

    @Test func aFolderOfRootsThatOthersCanWriteWithoutTheStickyBitGetsSudoChmodGoW() throws {
        let t = try TestHome()
        let place = "/usr/local/lib/node_modules"
        func folder(root: Bool = true, sticky: Bool = false, flags: UInt32 = 0) -> FileFacts {
            FileFacts(
                realPath: place, ownerIsUserOrRoot: root, ownerIsUser: false,
                writableByOthers: true, listLetsOthersChange: false,
                flags: NoFollowWriter.FileFlags(flags), isRegularFile: false, isExecutable: true,
                isSticky: sticky)
        }
        #expect(t.runner.modeFix(folder()) == run("sudo chmod go-w \(place)"))
        #expect(
            t.runner.modeFix(folder(flags: UInt32(UF_IMMUTABLE)))
                == "Run `sudo chflags nouchg \(place)`, then `sudo chmod go-w \(place)` in Terminal."
        )
        // One shared on purpose, like `/tmp`, and another user's get none.
        #expect(t.runner.modeFix(folder(sticky: true)) == nil)
        #expect(t.runner.modeFix(folder(root: false)) == nil)
    }

    @Test @MainActor func theMenuCardAndTheManageWindowShowTheRefusalAndItsFix() throws {
        let t = try TestHome()
        defer { base.clear(t) }
        let bin = t.home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let tool = bin.appendingPathComponent("agent-balancer")
        try "#!/bin/sh\nexit 0\n".write(to: tool, atomically: true, encoding: .utf8)
        #expect(chmod(tool.path, 0o755) == 0)
        try base.add("everyone allow write", tool)
        let runner = CLIRunner(context: t.context, candidates: [tool])
        let refusal =
            "Refused ~/bin/agent-balancer: its real target's access list lets another user or group change it, or cannot be read. Run chmod -N ~/bin/agent-balancer in Terminal to drop every entry of its access list."
        let menu = MenuController(context: t.context, runner: runner)
        #expect(
            menu.screen
                == .card(
                    CardModel(
                        title: "agent-balancer refused", text: refusal, command: nil, lines: [])))
        let manage = ManageViewModel(context: t.context, runner: runner)
        #expect(manage.offReason == "Management is off: " + refusal)
        #expect(try base.chmodRun(["-N", tool.path]) == 0)
        menu.reload()
        if case .card(let card) = menu.screen {
            #expect(card.title == "Set up agent-balancer")
        } else {
            Issue.record("expected the setup card")
        }
        #expect(manage.offReason == nil)
    }

    /// The native installer, a Homebrew cask and an npm install, each with Homebrew's real modes
    /// set explicitly, pass the runner's tests and run.
    @Test func theThreeInstallLayoutsPassWithTheirStandardModes() throws {
        let fm = FileManager.default
        let layouts: [(name: String, link: String, real: String, text: String?, wide: [String])] = [
            (
                "native", ".local/bin/claude", ".local/share/claude/versions/2.1.0", nil, []
            ),
            (
                "cask", "brew/bin/claude", "brew/Caskroom/claude-code/2.1.0/claude", nil,
                ["brew/bin", "brew/Caskroom"]
            ),
            (
                "npm", "brew/bin/claude", "brew/lib/node_modules/@anthropic-ai/claude-code/cli.js",
                "../lib/node_modules/@anthropic-ai/claude-code/cli.js", ["brew/bin", "brew/lib"]
            ),
        ]
        for layout in layouts {
            let t = try TestHome()
            defer { base.clear(t) }
            let link = t.home.appendingPathComponent(layout.link)
            let real = t.home.appendingPathComponent(layout.real)
            for folder in [link.deletingLastPathComponent(), real.deletingLastPathComponent()] {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            try fm.copyItem(at: t.fixtures.appendingPathComponent("bin/claude"), to: real)
            #expect(chmod(real.path, 0o755) == 0, "\(layout.name)")
            try fm.createSymbolicLink(
                atPath: link.path, withDestinationPath: layout.text ?? real.path)
            // Every folder from the home down gets its mode explicitly, whatever the umask.
            var folders = [t.home]
            for path in [layout.link, layout.real] {
                var url = t.home
                for part in path.split(separator: "/").dropLast() {
                    url.appendPathComponent(String(part))
                    folders.append(url)
                }
            }
            for folder in folders {
                let wide = layout.wide.contains {
                    t.home.appendingPathComponent($0).path == folder.path
                }
                #expect(chmod(folder.path, wide ? 0o775 : 0o755) == 0, "\(layout.name)")
            }
            let runner =
                layout.name == "native"
                ? t.runner : ClaudeRunner(context: t.context, candidates: [link])
            #expect(base.refusal(runner) == nil, "\(layout.name)")
            #expect(try runner.locate().path == link.path, "\(layout.name)")
            #expect(try runner.run(arguments: ["--version"]).status == 0, "\(layout.name)")
        }
    }
}
