import Foundation
import Testing

@testable import Core

/// The menu app's developer render flags accept an output folder only under the current folder's
/// `build` folder, with no `..`, no link on the way, and outside the home's tool folders.
@Suite struct RenderOutputTests {
    /// A temporary place by its real path: a current folder with a `build` folder, and a home.
    final class Place {
        let root: URL
        var cwd: URL { root.appendingPathComponent("repo") }
        var home: URL { root.appendingPathComponent("home") }

        init() throws {
            let made = FileManager.default.temporaryDirectory
                .appendingPathComponent("ab-render-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
            let real = try #require(realpath(made.path, nil))
            root = URL(fileURLWithPath: String(cString: real))
            free(real)
            for folder in [
                "repo/build/icons", "home/.claude/proj/build", "home/.agent-balancer/x/build",
            ] {
                try FileManager.default.createDirectory(
                    at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
            }
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func check(_ argument: String, from cwd: URL? = nil) throws -> URL {
            try RenderOutput.folder(
                argument, currentDirectoryPath: (cwd ?? self.cwd).path, homes: [home])
        }

        func link(_ path: String, to target: URL) throws {
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent(path), withDestinationURL: target)
        }

        /// Every entry under the place, so a refusal can be seen to create nothing.
        func entries() -> [String] {
            (FileManager.default.subpaths(atPath: root.path) ?? []).sorted()
        }
    }

    @Test func aFolderUnderTheCurrentBuildFolderIsAccepted() throws {
        let place = try Place()
        let before = place.entries()
        let build = place.cwd.appendingPathComponent("build").path
        #expect(try place.check("build/renders").path == build + "/renders")
        #expect(try place.check("build/./renders/").path == build + "/renders")
        #expect(try place.check(build + "/AppIcon.iconset").path == build + "/AppIcon.iconset")
        #expect(try place.check("build/icons").path == build + "/icons")
        #expect(try place.check("build/icons/new").path == build + "/icons/new")
        #expect(place.entries() == before)
    }

    @Test func pathsOutsideTheCurrentBuildFolderOrWithDotDotAreRefused() throws {
        let place = try Place()
        let before = place.entries()
        let refused = [
            "", "build", "build/", "renders", "/tmp/build/renders", "elsewhere/build/renders",
            "build/../renders", "build/icons/../../renders", "../repo/build/renders",
            "build/..", place.cwd.path + "/build-other/renders", place.cwd.path + "/buildx",
            place.root.path + "/build/renders",
        ]
        for argument in refused {
            #expect(throws: ToolError.self, "\(argument)") { try place.check(argument) }
        }
        #expect(place.entries() == before)
    }

    @Test func aLinkAnywhereOnThePathIsRefused() throws {
        let place = try Place()
        let elsewhere = place.root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        // The output folder itself, a folder on the way, and the build folder of another tree.
        try place.link("repo/build/out", to: elsewhere)
        try place.link("repo/build/hop", to: elsewhere)
        let other = place.root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try place.link("other/build", to: elsewhere)
        let before = place.entries()
        #expect(throws: ToolError.self) { try place.check("build/out") }
        #expect(throws: ToolError.self) { try place.check("build/hop/renders") }
        #expect(throws: ToolError.self) { try place.check("build/renders", from: other) }
        // A file where a folder belongs is refused too.
        FileManager.default.createFile(
            atPath: place.cwd.appendingPathComponent("build/file").path, contents: Data())
        #expect(throws: ToolError.self) { try place.check("build/file") }
        #expect(throws: ToolError.self) { try place.check("build/file/renders") }
        #expect(place.entries() == (before + ["repo/build/file"]).sorted())
    }

    @Test func aBuildFolderInsideTheHomesToolFoldersIsRefused() throws {
        let place = try Place()
        let claude = place.home.appendingPathComponent(".claude/proj")
        let data = place.home.appendingPathComponent(".agent-balancer/x")
        #expect(throws: ToolError.self) { try place.check("build/renders", from: claude) }
        #expect(throws: ToolError.self) { try place.check("build/renders", from: data) }
        // Another spelling of the same folder.
        let upper = place.home.appendingPathComponent(".CLAUDE/proj")
        #expect(throws: ToolError.self) { try place.check("build/renders", from: upper) }
    }

    @Test func aHomeToolFolderThatIsALinkIsRefusedByWhatItPointsTo() throws {
        let place = try Place()
        // The home's .claude is a link to a real folder, and the current folder is inside that.
        let real = place.root.appendingPathComponent("dotfiles/claude")
        try FileManager.default.createDirectory(
            at: real.appendingPathComponent("proj/build"), withIntermediateDirectories: true)
        let home = place.root.appendingPathComponent("home2")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try place.link("home2/.claude", to: real)
        #expect(throws: ToolError.self) {
            try RenderOutput.folder(
                "build/renders", currentDirectoryPath: real.appendingPathComponent("proj").path,
                homes: [home])
        }
        // The same tree with no link from a home is accepted.
        let accepted = try RenderOutput.folder(
            "build/renders", currentDirectoryPath: real.appendingPathComponent("proj").path,
            homes: [place.home])
        #expect(accepted.lastPathComponent == "renders")
    }
}

/// The output folder is opened once, one name at a time, and every file is written relative to
/// that handle, so a folder swapped for a link part way sends nothing through the link.
extension RenderOutputTests {
    @Test func aBuildFolderSwappedForALinkAfterTheFirstFileStopsTheRunAndLandsNothingOutside()
        throws
    {
        let place = try Place()
        let target = place.home.appendingPathComponent(".claude/proj")
        try FileManager.default.createDirectory(
            at: target.appendingPathComponent("renders"), withIntermediateDirectories: true)
        let held = try RenderOutput.hold(
            "build/renders", currentDirectoryPath: place.cwd.path, homes: [place.home])
        try held.put(Data("one".utf8), name: "one.png")
        let build = place.cwd.appendingPathComponent("build")
        #expect(
            FileManager.default.fileExists(
                atPath: build.appendingPathComponent("renders/one.png").path))
        // Another process swaps `build` for a link into the home's .claude folder, which holds
        // a `renders` folder a path walk would write into.
        let inside = (FileManager.default.subpaths(atPath: target.path) ?? []).sorted()
        try FileManager.default.moveItem(at: build, to: place.cwd.appendingPathComponent("moved"))
        try place.link("repo/build", to: target)
        #expect(throws: ToolError.self) { try held.put(Data("two".utf8), name: "two.png") }
        #expect((FileManager.default.subpaths(atPath: target.path) ?? []).sorted() == inside)
        #expect(
            !FileManager.default.fileExists(
                atPath: target.appendingPathComponent("renders/two.png").path))
        #expect(
            !FileManager.default.fileExists(
                atPath: place.cwd.appendingPathComponent("moved/renders/two.png").path))
    }

    @Test func aLinkOnTheWayWhenTheFolderIsOpenedIsRefusedAndNothingIsMade() throws {
        let place = try Place()
        let elsewhere = place.root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try place.link("repo/build/hop", to: elsewhere)
        let before = place.entries()
        // Opened directly, as if the path check had passed just before the link appeared.
        #expect(throws: ToolError.self) {
            _ = try NoFollowWriter.holdFolder(
                start: place.cwd.path, checked: place.cwd.path, names: ["build", "hop", "renders"],
                refused: [])
        }
        #expect(throws: ToolError.self) {
            _ = try NoFollowWriter.holdFolder(
                start: place.cwd.path, checked: place.cwd.path, names: ["build", "hop"],
                refused: [])
        }
        #expect(place.entries() == before)
        #expect((FileManager.default.subpaths(atPath: elsewhere.path) ?? []).isEmpty)
    }

    @Test func aProtectedFolderReachedByItsIdentityIsRefusedWhenOpened() throws {
        let place = try Place()
        let protected = try #require(
            FileIdentity.of(path: place.cwd.appendingPathComponent("build/icons").path))
        #expect(throws: ToolError.self) {
            _ = try NoFollowWriter.holdFolder(
                start: place.cwd.path, checked: place.cwd.path, names: ["build", "icons", "new"],
                refused: [protected])
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: place.cwd.appendingPathComponent("build/icons/new").path))
        let held = try RenderOutput.hold(
            "build/renders", currentDirectoryPath: place.cwd.path, homes: [place.home])
        try held.put(Data("x".utf8), name: "x.png")
        let made = place.cwd.appendingPathComponent("build/renders")
        let mode = try FileManager.default.attributesOfItem(atPath: made.path)[.posixPermissions]
        #expect((mode as? Int) == 0o700)
    }
}

/// The folder checked and the folder written are one folder: a current folder no path names, a
/// start that is not the checked folder, and a start or held folder inside a protected folder by
/// any path are all refused, with nothing made.
extension RenderOutputTests {
    @Test func anEmptyOrRelativeCurrentFolderPathIsRefusedBeforeAnythingIsOpened() throws {
        let place = try Place()
        let before = place.entries()
        for cwd in ["", ".", "repo", "build"] {
            #expect(throws: ToolError.self, "\(cwd)") {
                try RenderOutput.folder(
                    "build/renders", currentDirectoryPath: cwd, homes: [place.home])
            }
            // Started from the place, so a write that got past the rule would show there.
            #expect(throws: ToolError.self, "\(cwd)") {
                _ = try RenderOutput.hold(
                    "build/renders", currentDirectoryPath: cwd, homes: [place.home],
                    start: place.cwd.path)
            }
        }
        #expect(place.entries() == before)
        // The production start, the process's own current folder, with a name nothing makes.
        let unseen = "build/ab-never-made-\(UUID().uuidString)"
        #expect(throws: ToolError.self) {
            _ = try RenderOutput.hold(
                unseen, currentDirectoryPath: "", homes: [place.home], start: ".")
        }
        #expect(!FileManager.default.fileExists(atPath: unseen))
    }

    @Test func aStartInsideAProtectedFolderIsRefusedWhenOpenedAndNothingIsMade() throws {
        let place = try Place()
        let refused = try #require(RenderOutput.protectedIdentities([place.home]))
        let before = place.entries()
        // A child of each protected folder, as the current folder would be when started there.
        for start in [".claude/proj", ".agent-balancer/x"] {
            let path = place.home.appendingPathComponent(start).path
            #expect(throws: ToolError.self, "\(start)") {
                _ = try NoFollowWriter.holdFolder(
                    start: path, checked: path, names: ["build", "renders"], refused: refused)
            }
        }
        #expect(place.entries() == before)
    }

    @Test func aStartThatIsNotTheCheckedFolderIsRefusedAndNothingIsMade() throws {
        let place = try Place()
        // Another folder with a build folder, where the files would land if the start were trusted.
        let other = place.root.appendingPathComponent("other")
        try FileManager.default.createDirectory(
            at: other.appendingPathComponent("build"), withIntermediateDirectories: true)
        let before = place.entries()
        #expect(throws: ToolError.self) {
            _ = try RenderOutput.hold(
                "build/renders", currentDirectoryPath: place.cwd.path, homes: [place.home],
                start: other.path)
        }
        #expect(place.entries() == before)
    }

    @Test func aFolderMovedIntoAProtectedFolderAfterTheHoldStopsTheRunAtTheNextFile() throws {
        let place = try Place()
        let held = try RenderOutput.hold(
            "build/renders", currentDirectoryPath: place.cwd.path, homes: [place.home])
        try held.put(Data("one".utf8), name: "one.png")
        // Another process moves the whole working folder into the home's .claude folder; the held
        // handles follow it there.
        let moved = place.home.appendingPathComponent(".claude/repo")
        try FileManager.default.moveItem(at: place.cwd, to: moved)
        let renders = moved.appendingPathComponent("build/renders")
        #expect(throws: ToolError.self) { try held.put(Data("two".utf8), name: "two.png") }
        #expect(try FileManager.default.contentsOfDirectory(atPath: renders.path) == ["one.png"])
    }
}

/// The held folder's identity, the output folder's own mode, and a protected folder that is not
/// made yet each stop a run on their own.
extension RenderOutputTests {
    @Test func aRealFolderLeftWhereTheHeldFolderWasStopsTheRunAtTheNextFile() throws {
        let place = try Place()
        let renders = place.cwd.appendingPathComponent("build/renders")
        // Moved into the home's .claude folder, and moved to a place no other check refuses.
        let moves = [
            place.home.appendingPathComponent(".claude/renders"),
            place.root.appendingPathComponent("away"),
        ]
        for away in moves {
            let held = try RenderOutput.hold(
                "build/renders", currentDirectoryPath: place.cwd.path, homes: [place.home])
            try held.put(Data("one".utf8), name: "one.png")
            try FileManager.default.moveItem(at: renders, to: away)
            try FileManager.default.createDirectory(at: renders, withIntermediateDirectories: false)
            #expect(throws: ToolError.self, "\(away.lastPathComponent)") {
                try held.put(Data("two".utf8), name: "two.png")
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: away.path) == ["one.png"])
            #expect(try FileManager.default.contentsOfDirectory(atPath: renders.path).isEmpty)
            try FileManager.default.removeItem(at: renders)
        }
    }

    @Test func anOutputFolderWiderThanPrivateIsRefusedAndGetsNothing() throws {
        let place = try Place()
        let renders = place.cwd.appendingPathComponent("build/renders")
        try FileManager.default.createDirectory(at: renders, withIntermediateDirectories: false)
        for mode in [0o755, 0o770, 0o701] {
            try FileManager.default.setAttributes(
                [.posixPermissions: mode], ofItemAtPath: renders.path)
            #expect(throws: ToolError.self, "\(String(mode, radix: 8))") {
                _ = try RenderOutput.hold(
                    "build/renders", currentDirectoryPath: place.cwd.path, homes: [place.home])
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: renders.path).isEmpty)
        }
        // The same folder made private is accepted.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: renders.path)
        let held = try RenderOutput.hold(
            "build/renders", currentDirectoryPath: place.cwd.path, homes: [place.home])
        try held.put(Data("x".utf8), name: "x.png")
        #expect(try FileManager.default.contentsOfDirectory(atPath: renders.path) == ["x.png"])
    }

    @Test func aHomeToolFolderThatIsNotMadeYetIsRefusedByItsNameAndStaysUnmade() throws {
        let place = try Place()
        // A home under the current build folder with no .claude or .agent-balancer yet, so only
        // the name tells them apart from any other new folder.
        let home = place.cwd.appendingPathComponent("build/h")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        let before = place.entries()
        for argument in ["build/h/.claude", "build/h/.agent-balancer", "build/h/.Claude"] {
            #expect(throws: ToolError.self, "\(argument)") {
                try RenderOutput.folder(
                    argument, currentDirectoryPath: place.cwd.path, homes: [home])
            }
            #expect(throws: ToolError.self, "\(argument)") {
                _ = try RenderOutput.hold(
                    argument, currentDirectoryPath: place.cwd.path, homes: [home])
            }
        }
        #expect(place.entries() == before)
    }
}

/// The walk up from an opened folder must reach the root. A folder on the way that can be passed
/// through but not opened ends the walk, and the run is refused, since a protected folder could
/// sit above it unseen.
extension RenderOutputTests {
    /// A current folder `locked/repo` with a `build` folder, under the place's root.
    static func lockedTree(_ place: Place) throws -> (locked: URL, cwd: URL, build: URL) {
        let locked = place.root.appendingPathComponent("locked")
        let cwd = locked.appendingPathComponent("repo")
        let build = cwd.appendingPathComponent("build")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        return (locked, cwd, build)
    }

    /// Runs `body` while `folder` can be passed through but not opened, and gives the folder its
    /// mode back afterwards, whether `body` passed or not.
    static func whileUnreadable(_ folder: URL, _ body: () throws -> Void) throws {
        let manager = FileManager.default
        let mode = try #require(
            try manager.attributesOfItem(atPath: folder.path)[.posixPermissions])
        try manager.setAttributes([.posixPermissions: 0o100], ofItemAtPath: folder.path)
        defer { try? manager.setAttributes([.posixPermissions: mode], ofItemAtPath: folder.path) }
        let fd = open(folder.path, O_RDONLY | O_DIRECTORY)
        if fd >= 0 { close(fd) }
        try #require(fd < 0, "the folder can still be opened, so nothing here is tested")
        try body()
    }

    @Test func aCurrentFolderUnderAFolderThatCannotBeOpenedIsRefusedAndGetsNothing() throws {
        let place = try Place()
        let tree = try Self.lockedTree(place)
        let renders = tree.build.appendingPathComponent("renders")
        try Self.whileUnreadable(tree.locked) {
            // The path rules pass, so only the walk up from the opened folder can refuse.
            _ = try RenderOutput.folder(
                "build/renders", currentDirectoryPath: tree.cwd.path, homes: [place.home])
            #expect(throws: ToolError.self) {
                let held = try RenderOutput.hold(
                    "build/renders", currentDirectoryPath: tree.cwd.path, homes: [place.home],
                    start: tree.cwd.path)
                try held.put(Data("x".utf8), name: "x.png")
            }
            #expect(!FileManager.default.fileExists(atPath: renders.path))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: tree.build.path).isEmpty)
    }

    @Test func aFolderAboveTheHeldFolderThatCannotBeOpenedStopsTheRunAtTheNextFile() throws {
        let place = try Place()
        let tree = try Self.lockedTree(place)
        let renders = tree.build.appendingPathComponent("renders")
        let held = try RenderOutput.hold(
            "build/renders", currentDirectoryPath: tree.cwd.path, homes: [place.home],
            start: tree.cwd.path)
        try held.put(Data("one".utf8), name: "one.png")
        try Self.whileUnreadable(tree.locked) {
            #expect(throws: ToolError.self) { try held.put(Data("two".utf8), name: "two.png") }
            #expect(
                !FileManager.default.fileExists(
                    atPath: renders.appendingPathComponent("two.png").path))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: renders.path) == ["one.png"])
    }
}
