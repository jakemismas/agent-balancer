import Foundation
import Testing

/// Through the built app, both render flags either refuse with nothing made and nothing written,
/// or render with nothing in the home's tool folders, whatever state HOME's `.claude` or
/// `.agent-balancer` is in, a link to nothing included.
extension AppSurfaceTests {
    /// The states of the tool folder a case varies, and whether the app renders with it.
    /// `homeThroughMissingFolder` and `homeThroughDanglingLink` spell HOME through the folder the
    /// run would make. The two `dotDot` states spell HOME `<root>/real/lnk/../h` with `lnk` a link
    /// to `<root>/other/inner`: the system reads it as `<root>/other/h`, a join of the path as
    /// `<root>/real/h`. `emptyHome` sets HOME but leaves it empty, and `homeAtMode0600` is a home
    /// whose tool folder cannot be looked up. The three `relative` states spell HOME without a
    /// leading `/`, each naming a folder with no tool folders: `lnk/../h` from a current folder
    /// inside `<root>/X/h`'s tool folder, with `lnk` a link to `<root>/X/inner`, which the system
    /// reads as `<root>/X/h` and a join with the current folder as `<cwd>/h`; `../hh`; and `hh`.
    /// `emptyHomeNoToolFolder` leaves HOME empty with no tool folder in the current folder.
    static let toolFolderStates: [(String, Bool)] = [
        ("missing", true), ("folder", true), ("linkToFolder", true), ("chainToFolder", true),
        ("linkToOutput", false), ("danglingAbsolute", false), ("danglingRelative", false),
        ("danglingChain", false), ("linkToFile", false), ("file", false), ("loop", false),
        ("homeThroughMissingFolder", false), ("homeThroughDanglingLink", false),
        ("dotDotHomeAboveCurrentFolder", false), ("dotDotHomeDangling", false),
        ("emptyHome", false), ("homeAtMode0600", false),
        ("relativeDotDotHomeAboveCurrentFolder", false), ("relativeDotDotHome", false),
        ("relativeHome", false), ("emptyHomeNoToolFolder", false),
    ]

    /// What a case runs: the HOME value, the current folder, and a home kept at mode 0600 while
    /// the app runs.
    struct HomeCase {
        let home: String
        let cwd: URL
        let locked: URL?
    }

    /// Sets up `name` for `output` under `<root>`, with `<root>/home` as the home and
    /// `<root>/repo` as the current folder unless the state says otherwise.
    static func arrangeHome(_ state: String, name: String, output: String, root: URL) throws
        -> HomeCase
    {
        let fm = FileManager.default
        let home = root.appendingPathComponent("home")
        let cwd = root.appendingPathComponent("repo")
        let spot = home.appendingPathComponent(name)
        let target = cwd.appendingPathComponent(output)
        let elsewhere = root.appendingPathComponent("elsewhere")
        let hop = root.appendingPathComponent("hop")
        func link(_ at: URL, _ to: String) throws {
            try fm.createSymbolicLink(atPath: at.path, withDestinationPath: to)
        }
        switch state {
        case "folder": try fm.createDirectory(at: spot, withIntermediateDirectories: false)
        case "linkToFolder": try link(spot, elsewhere.path)
        case "chainToFolder":
            try link(hop, elsewhere.path)
            try link(spot, hop.path)
        case "linkToOutput":
            try fm.createDirectory(
                at: target, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            try link(spot, target.path)
        case "danglingAbsolute": try link(spot, target.path)
        case "danglingRelative": try link(spot, "../repo/" + output)
        case "danglingChain":
            try link(hop, target.path)
            try link(spot, hop.path)
        case "linkToFile": try link(spot, root.appendingPathComponent("afile").path)
        case "file": fm.createFile(atPath: spot.path, contents: Data())
        case "loop": try link(spot, spot.path)
        case "homeThroughMissingFolder", "homeThroughDanglingLink":
            let beside = target.deletingLastPathComponent().appendingPathComponent("hh")
            try fm.createDirectory(at: beside, withIntermediateDirectories: false)
            try link(beside.appendingPathComponent(name), target.path)
            if state == "homeThroughMissingFolder" {
                return HomeCase(home: target.path + "/../hh", cwd: cwd, locked: nil)
            }
            try link(root.appendingPathComponent("hl"), target.path + "/..")
            return HomeCase(home: root.path + "/hl/hh", cwd: cwd, locked: nil)
        case "dotDotHomeAboveCurrentFolder", "dotDotHomeDangling":
            let joined = root.appendingPathComponent("real/h")
            for folder in ["real/h", "other/inner", "other/h"] {
                try fm.createDirectory(
                    at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
            }
            try link(
                root.appendingPathComponent("real/lnk"),
                root.appendingPathComponent("other/inner").path)
            let spelled = root.path + "/real/lnk/../h"
            guard state == "dotDotHomeAboveCurrentFolder" else {
                try link(joined.appendingPathComponent(name), target.path)
                return HomeCase(home: spelled, cwd: cwd, locked: nil)
            }
            let inside = joined.appendingPathComponent(name + "/repo")
            try fm.createDirectory(
                at: inside.appendingPathComponent("build/x"), withIntermediateDirectories: true)
            return HomeCase(home: spelled, cwd: inside, locked: nil)
        case "emptyHome":
            try link(cwd.appendingPathComponent(name), target.path)
            return HomeCase(home: "", cwd: cwd, locked: nil)
        case "homeAtMode0600":
            try link(spot, target.path)
            return HomeCase(home: home.path, cwd: cwd, locked: home)
        case "relativeDotDotHomeAboveCurrentFolder":
            let inside = root.appendingPathComponent("X/h/" + name + "/repo")
            for folder in ["build/x", "h"] {
                try fm.createDirectory(
                    at: inside.appendingPathComponent(folder), withIntermediateDirectories: true)
            }
            let inner = root.appendingPathComponent("X/inner")
            try fm.createDirectory(at: inner, withIntermediateDirectories: true)
            try link(inside.appendingPathComponent("lnk"), inner.path)
            return HomeCase(home: "lnk/../h", cwd: inside, locked: nil)
        case "relativeDotDotHome":
            try fm.createDirectory(
                at: root.appendingPathComponent("hh"), withIntermediateDirectories: false)
            return HomeCase(home: "../hh", cwd: cwd, locked: nil)
        case "relativeHome":
            try fm.createDirectory(
                at: cwd.appendingPathComponent("hh"), withIntermediateDirectories: false)
            return HomeCase(home: "hh", cwd: cwd, locked: nil)
        case "emptyHomeNoToolFolder":
            return HomeCase(home: "", cwd: cwd, locked: nil)
        default: break
        }
        return HomeCase(home: home.path, cwd: cwd, locked: nil)
    }

    /// Runs `body` with `home` at mode 0600, so no name inside it can be looked up, and gives it
    /// 0700 back afterwards, pass or fail.
    static func whileLocked<T>(_ home: URL?, name: String, _ body: () throws -> T) throws -> T {
        guard let home else { return try body() }
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: home.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path) }
        var st = stat()
        let failed = lstat(home.path + "/" + name, &st) != 0
        let code = errno
        try #require(failed && code == EACCES, "the tool folder can still be looked up")
        return try body()
    }

    @Test func bothFlagsRefuseWithNothingMadeOrRenderOutsideTheHomesToolFoldersInEveryState()
        throws
    {
        let fm = FileManager.default
        var refused = 0
        var rendered = 0
        for (state, renders) in Self.toolFolderStates {
            for name in [".claude", ".agent-balancer"] {
                for output in ["build/t", "build/x/t"] {
                    for flag in ["--render", "--iconset"] {
                        let made = fm.temporaryDirectory
                            .appendingPathComponent("ab-app-link-\(UUID().uuidString)")
                        try fm.createDirectory(at: made, withIntermediateDirectories: true)
                        defer { try? fm.removeItem(at: made) }
                        let real = try #require(realpath(made.path, nil))
                        let root = URL(fileURLWithPath: String(cString: real))
                        free(real)
                        for folder in ["repo/build/x", "home", "elsewhere"] {
                            try fm.createDirectory(
                                at: root.appendingPathComponent(folder),
                                withIntermediateDirectories: true)
                        }
                        fm.createFile(
                            atPath: root.appendingPathComponent("afile").path, contents: Data())
                        let arranged = try Self.arrangeHome(
                            state, name: name, output: output, root: root)
                        let label = "\(state) \(name) \(output) \(flag)"
                        let before = (fm.subpaths(atPath: root.path) ?? []).sorted()
                        let (status, printed) = try Self.whileLocked(arranged.locked, name: name) {
                            try Self.renderFlag(
                                [flag, output], cwd: arranged.cwd, homeVariable: arranged.home)
                        }
                        guard renders else {
                            #expect(status == 1, "\(label)")
                            #expect(printed.contains("Nothing was written."), "\(label)")
                            #expect((fm.subpaths(atPath: root.path) ?? []).sorted() == before)
                            refused += 1
                            continue
                        }
                        #expect(status == 0, "\(label)")
                        let files = try fm.contentsOfDirectory(
                            atPath: root.appendingPathComponent("repo/" + output).path)
                        #expect(files.count == (flag == "--render" ? 42 : 10), "\(label)")
                        if flag == "--render" {
                            // The README pictures scripts/render-views.sh copies, by these names.
                            let readme = LeakShapes.picturePaths.map {
                                "readme-" + $0.dropFirst("docs/media/".count)
                            }
                            #expect(Set(files).isSuperset(of: readme), "\(label)")
                        }
                        // Read through HOME's own spelling, links followed.
                        for tool in [".claude", ".agent-balancer"] {
                            let listed = try? fm.contentsOfDirectory(
                                atPath: arranged.home + "/" + tool)
                            #expect((listed ?? []).isEmpty, "\(label): \(tool)")
                        }
                        rendered += 1
                    }
                }
            }
        }
        #expect(refused == 136)
        #expect(rendered == 32)
    }
}
