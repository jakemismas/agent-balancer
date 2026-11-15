import Foundation
import Testing

/// scripts/build-app.sh and scripts/render-views.sh work from the checkout's real path, so a
/// checkout opened through a link still renders: the app refuses an output path that names a link.
@Suite struct ScriptRootTests {
    static let realRoot = #"ROOT="$(cd "$(dirname "$0")/.." && pwd -P)""#

    @Test func bothScriptsTakeTheRootFromTheRealPath() throws {
        for script in ["scripts/build-app.sh", "scripts/render-views.sh"] {
            let text = try String(
                contentsOf: Support.root.appendingPathComponent(script), encoding: .utf8)
            #expect(text.contains(Self.realRoot), "\(script)")
        }
    }

    /// Runs the script from a path through a link to a copy of what it reads, with the README
    /// check's fake `swift` naming the real app and CLI, so the checkout's own pictures in
    /// docs/media are never written.
    @Test func renderViewsRunFromAPathThroughALinkExitsZero() throws {
        let fm = FileManager.default
        let app = try AppSurfaceTests.appBinary()
        let cli = try #require(Support.builtBinary())
        let place = try Support.makeTempDir()
        let temp = try Support.makeTempDir()
        let (tools, bin) = try ReadmeTests.fakeTools()
        defer { for dir in [place, temp, tools] { try? fm.removeItem(at: dir) } }
        let copy = place.appendingPathComponent("copy")
        try ReadmeTests.copyReadmeFiles(to: copy, extra: ["scripts/render-views.sh"])
        try fm.createSymbolicLink(
            at: bin.appendingPathComponent("AgentBalancerBar"), withDestinationURL: app)
        let through = place.appendingPathComponent("through")
        try fm.createSymbolicLink(at: through, withDestinationURL: copy)
        let home = place.appendingPathComponent("home")
        try fm.createDirectory(at: home, withIntermediateDirectories: false)

        let out = try Support.run(
            through.appendingPathComponent("scripts/render-views.sh"), [],
            env: [
                "HOME": home.path, "PATH": "\(tools.path):/usr/bin:/bin", "TMPDIR": temp.path,
                "FAKE_LOG": tools.appendingPathComponent("swift.log").path, "FAKE_BIN": bin.path,
                "FAKE_CLI": cli.path,
            ])
        // The app prints a refusal on standard output.
        #expect(
            out.status == 0, "\(ReadmeTests.masked(out.stdout + out.stderr).suffix(600))")
        // Drawn by this run: the copy started with no build folder.
        for picture in LeakShapes.picturePaths {
            let drawn = "build/renders/readme-" + picture.dropFirst("docs/media/".count)
            #expect(fm.fileExists(atPath: copy.appendingPathComponent(drawn).path), "\(drawn)")
        }
    }
}
