import Foundation
import Testing

/// Both render flags refuse a home's tool folder that is not made yet when HOME names the home
/// through a link, and make nothing.
extension AppSurfaceTests {
    @Test func aHomeNamedThroughALinkGetsNoRenderInItsToolFoldersFromEitherFlag() throws {
        let fm = FileManager.default
        let made = fm.temporaryDirectory.appendingPathComponent("ab-app-\(UUID().uuidString)")
        try fm.createDirectory(at: made, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: made) }
        let real = try #require(realpath(made.path, nil))
        let root = URL(fileURLWithPath: String(cString: real))
        free(real)
        // The home is <root>/realbase/build/h with no .claude yet; HOME spells it through
        // <root>/linkbase, a link to realbase; the current folder is realbase.
        let realbase = root.appendingPathComponent("realbase")
        let home = realbase.appendingPathComponent("build/h")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            at: root.appendingPathComponent("linkbase"), withDestinationURL: realbase)
        let spelled = root.appendingPathComponent("linkbase/build/h")
        let before = (fm.subpaths(atPath: root.path) ?? []).sorted()
        for flag in ["--render", "--iconset"] {
            for name in [".claude", ".agent-balancer"] {
                let (status, printed) = try Self.renderFlag(
                    [flag, "build/h/\(name)"], cwd: realbase, home: spelled)
                #expect(status == 1, "\(flag) \(name)")
                #expect(!printed.contains(".png"), "\(flag) \(name)")
                #expect(!fm.fileExists(atPath: home.appendingPathComponent(name).path))
                #expect((fm.subpaths(atPath: root.path) ?? []).sorted() == before)
            }
        }
    }
}
