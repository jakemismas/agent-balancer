import Foundation
import Testing

@testable import Core

/// A home's `.claude` or `.agent-balancer` that is a link to nothing has no identity to compare,
/// and a render could make the folder it names. Every state a tool folder of either home can be
/// in either refuses with nothing made and nothing written, or renders with nothing in any tool
/// folder.
extension RenderOutputTests {
    /// How the tool folder a case varies is set up. The last two spell the home through a folder
    /// the run would make, so the tool folder names the output only once the run has made it.
    enum ToolFolderState: String, CaseIterable, Sendable {
        case missing, folder, linkToFolder, linkToOutput, danglingAbsolute, danglingRelative
        case danglingChain, chainToFolder, linkToFile, file, loop
        case homeThroughMissingFolder, homeThroughDanglingLink

        /// Whether a render goes ahead with the tool folder in this state.
        var renders: Bool {
            switch self {
            case .missing, .folder, .linkToFolder, .chainToFolder: return true
            default: return false
            }
        }
    }

    /// A temporary place by its real path: the current folder `repo` with `build/x`, two homes
    /// with no tool folders, an empty folder and a file elsewhere for links to name.
    final class LinkPlace {
        let root: URL
        var cwd: URL { root.appendingPathComponent("repo") }
        var homes: [URL] { [0, 1].map { root.appendingPathComponent("home\($0)") } }
        var elsewhere: URL { root.appendingPathComponent("elsewhere") }

        init() throws {
            let manager = FileManager.default
            let made = manager.temporaryDirectory
                .appendingPathComponent("ab-render-link-\(UUID().uuidString)")
            try manager.createDirectory(at: made, withIntermediateDirectories: true)
            let real = try #require(realpath(made.path, nil))
            root = URL(fileURLWithPath: String(cString: real))
            free(real)
            for folder in ["repo/build/x", "home0", "home1", "elsewhere"] {
                try manager.createDirectory(
                    at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
            }
            manager.createFile(atPath: root.appendingPathComponent("afile").path, contents: Data())
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func link(_ at: URL, to target: String) throws {
            try FileManager.default.createSymbolicLink(atPath: at.path, withDestinationPath: target)
        }

        /// Sets up `name` in home `index` for `output`, and returns the homes the rule is given.
        func arrange(_ state: ToolFolderState, home index: Int, name: String, output: String)
            throws -> [URL]
        {
            let manager = FileManager.default
            var homes = self.homes
            let spot = homes[index].appendingPathComponent(name)
            let target = cwd.appendingPathComponent(output)
            let hop = root.appendingPathComponent("hop")
            switch state {
            case .missing:
                break
            case .folder:
                try manager.createDirectory(at: spot, withIntermediateDirectories: false)
            case .linkToFolder:
                try link(spot, to: elsewhere.path)
            case .linkToOutput:
                try manager.createDirectory(
                    at: target, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700])
                try link(spot, to: target.path)
            case .danglingAbsolute:
                try link(spot, to: target.path)
            case .danglingRelative:
                try link(spot, to: "../repo/" + output)
            case .danglingChain:
                try link(hop, to: target.path)
                try link(spot, to: hop.path)
            case .chainToFolder:
                try link(hop, to: elsewhere.path)
                try link(spot, to: hop.path)
            case .linkToFile:
                try link(spot, to: root.appendingPathComponent("afile").path)
            case .file:
                manager.createFile(atPath: spot.path, contents: Data())
            case .loop:
                try link(spot, to: spot.path)
            case .homeThroughMissingFolder, .homeThroughDanglingLink:
                // The folder beside the output holds the tool folder, a link to the output.
                let beside = target.deletingLastPathComponent().appendingPathComponent("hh")
                try manager.createDirectory(at: beside, withIntermediateDirectories: false)
                try link(beside.appendingPathComponent(name), to: target.path)
                if state == .homeThroughMissingFolder {
                    homes[index] = URL(fileURLWithPath: target.path + "/../hh")
                } else {
                    try link(root.appendingPathComponent("hl"), to: target.path + "/..")
                    homes[index] = root.appendingPathComponent("hl/hh")
                }
            }
            return homes
        }

        /// Every entry under the place, so a refusal can be seen to make nothing.
        func entries() -> [String] {
            (FileManager.default.subpaths(atPath: root.path) ?? []).sorted()
        }
    }

    @Test func everyStateOfEachHomesToolFoldersRefusesWithNothingMadeOrRendersOutsideThem() throws {
        var refused = 0
        var rendered = 0
        for index in [0, 1] {
            for name in RenderOutput.toolFolders {
                for state in ToolFolderState.allCases {
                    for output in ["build/t", "build/x/t"] {
                        let place = try LinkPlace()
                        let homes = try place.arrange(
                            state, home: index, name: name, output: output)
                        let label = "home\(index) \(name) \(state.rawValue) \(output)"
                        let cwd = place.cwd.path
                        guard state.renders else {
                            let before = place.entries()
                            #expect(throws: ToolError.self, "\(label)") {
                                try RenderOutput.folder(
                                    output, currentDirectoryPath: cwd, homes: homes)
                            }
                            #expect(throws: ToolError.self, "\(label)") {
                                let held = try RenderOutput.hold(
                                    output, currentDirectoryPath: cwd, homes: homes)
                                try held.put(Data("a".utf8), name: "a.png")
                            }
                            #expect(place.entries() == before, "\(label)")
                            refused += 1
                            continue
                        }
                        _ = try RenderOutput.folder(output, currentDirectoryPath: cwd, homes: homes)
                        let held = try RenderOutput.hold(
                            output, currentDirectoryPath: cwd, homes: homes)
                        try held.put(Data("a".utf8), name: "a.png")
                        try held.put(Data("b".utf8), name: "b.png")
                        let written = try FileManager.default.contentsOfDirectory(
                            atPath: place.cwd.appendingPathComponent(output).path)
                        #expect(written.sorted() == ["a.png", "b.png"], "\(label)")
                        // Read through the home's own spelling, links followed.
                        for home in homes {
                            for tool in RenderOutput.toolFolders {
                                let listed = try? FileManager.default.contentsOfDirectory(
                                    atPath: home.appendingPathComponent(tool).path)
                                #expect((listed ?? []).isEmpty, "\(label): \(home.path) \(tool)")
                            }
                        }
                        rendered += 1
                    }
                }
            }
        }
        #expect(refused == 72)
        #expect(rendered == 32)
    }

    @Test func aProtectedPathThatNamesTheFolderJustMadeStopsTheHoldBeforeAnyFile() throws {
        let place = try LinkPlace()
        let home = place.homes[0]
        let output = place.cwd.appendingPathComponent("build/t")
        // Opened directly, as if the path rules had passed just before the link appeared.
        try place.link(home.appendingPathComponent(".claude"), to: output.path)
        #expect(throws: ToolError.self) {
            _ = try NoFollowWriter.holdFolder(
                start: place.cwd.path, checked: place.cwd.path, names: ["build", "t"],
                refused: [], current: { RenderOutput.protectedIdentities([home]) })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
        // A protected path that cannot be compared once the folder is open stops it too.
        let other = place.homes[1]
        try place.link(other.appendingPathComponent(".agent-balancer"), to: "missing")
        #expect(throws: ToolError.self) {
            _ = try NoFollowWriter.holdFolder(
                start: place.cwd.path, checked: place.cwd.path, names: ["build", "x", "u"],
                refused: [], current: { RenderOutput.protectedIdentities([other]) })
        }
        let made = place.cwd.appendingPathComponent("build/x/u").path
        #expect(try FileManager.default.contentsOfDirectory(atPath: made).isEmpty)
    }

    @Test func aProtectedPathThatComesToNameTheHeldFolderStopsTheRunAtTheNextFile() throws {
        let place = try LinkPlace()
        let home = place.homes[0]
        let output = place.cwd.appendingPathComponent("build/t")
        let held = try RenderOutput.hold(
            "build/t", currentDirectoryPath: place.cwd.path, homes: place.homes)
        try held.put(Data("one".utf8), name: "one.png")
        // Another process points the home's .claude at the held folder part way.
        let spot = home.appendingPathComponent(".claude")
        try place.link(spot, to: output.path)
        #expect(throws: ToolError.self) { try held.put(Data("two".utf8), name: "two.png") }
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path) == ["one.png"])
        // Then at the next file's own name, which does not exist yet.
        try FileManager.default.removeItem(at: spot)
        try place.link(spot, to: output.appendingPathComponent("three.png").path)
        #expect(throws: ToolError.self) { try held.put(Data("three".utf8), name: "three.png") }
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path) == ["one.png"])
    }
}
