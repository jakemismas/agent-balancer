import Foundation
import Testing

/// Through the built app, both render flags either refuse with nothing made and nothing written,
/// or render with nothing in the home's tool folders, whatever state HOME's `.claude` or
/// `.agent-balancer` is in, a link to nothing included.
extension AppSurfaceTests {
    /// The states of the tool folder a case varies, and whether the app renders with it. The
    /// last two spell HOME through the folder the run would make.
    static let toolFolderStates: [(String, Bool)] = [
        ("missing", true), ("folder", true), ("linkToFolder", true), ("chainToFolder", true),
        ("linkToOutput", false), ("danglingAbsolute", false), ("danglingRelative", false),
        ("danglingChain", false), ("linkToFile", false), ("file", false), ("loop", false),
        ("homeThroughMissingFolder", false), ("homeThroughDanglingLink", false),
    ]

    /// Sets up `name` in `<root>/home` for `output` under `<root>/repo` and returns HOME.
    static func arrangeHome(_ state: String, name: String, output: String, root: URL) throws
        -> URL
    {
        let fm = FileManager.default
        let home = root.appendingPathComponent("home")
        let spot = home.appendingPathComponent(name)
        let target = root.appendingPathComponent("repo/" + output)
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
                return URL(fileURLWithPath: target.path + "/../hh")
            }
            try link(root.appendingPathComponent("hl"), target.path + "/..")
            return root.appendingPathComponent("hl/hh")
        default: break
        }
        return home
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
                        let home = try Self.arrangeHome(
                            state, name: name, output: output, root: root)
                        let label = "\(state) \(name) \(output) \(flag)"
                        let before = (fm.subpaths(atPath: root.path) ?? []).sorted()
                        let (status, printed) = try Self.renderFlag(
                            [flag, output], cwd: root.appendingPathComponent("repo"), home: home)
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
                        #expect(files.count == (flag == "--render" ? 32 : 10), "\(label)")
                        // Read through HOME's own spelling, links followed.
                        for tool in [".claude", ".agent-balancer"] {
                            let listed = try? fm.contentsOfDirectory(
                                atPath: home.appendingPathComponent(tool).path)
                            #expect((listed ?? []).isEmpty, "\(label): \(tool)")
                        }
                        rendered += 1
                    }
                }
            }
        }
        #expect(refused == 72)
        #expect(rendered == 32)
    }
}
