import Foundation
import Testing

/// Render rules the link tables do not reach: an output folder below a folder that is missing,
/// and the words the app prints for a home tool folder that is a link to nothing.
extension AppSurfaceTests {
    static let toolFolderRefusalText =
        "The home must be a folder, and its .claude and .agent-balancer must each be missing or a folder: a link to nothing or to a file stops every render. A HOME that is set but empty, is not an absolute path, or has a .. segment stops every render too. Nothing was written."

    /// A temporary root by its real path, with `repo/build` and `home`.
    static func withRenderRoot(_ body: (URL) throws -> Void) throws {
        let fm = FileManager.default
        let made = fm.temporaryDirectory.appendingPathComponent("ab-app-rule-\(UUID().uuidString)")
        try fm.createDirectory(at: made, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: made) }
        let real = try #require(realpath(made.path, nil))
        let root = URL(fileURLWithPath: String(cString: real))
        free(real)
        for folder in ["repo/build", "home"] {
            try fm.createDirectory(
                at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try body(root)
    }

    @Test func anOutputFolderBelowAMissingFolderIsRefusedWithNothingMade() throws {
        try Self.withRenderRoot { root in
            let fm = FileManager.default
            let before = (fm.subpaths(atPath: root.path) ?? []).sorted()
            for flag in ["--render", "--iconset"] {
                let (status, printed) = try Self.renderFlag(
                    [flag, "build/a/b"], cwd: root.appendingPathComponent("repo"),
                    home: root.appendingPathComponent("home"))
                #expect(status == 1, "\(flag)")
                #expect(
                    printed.contains("The output folder must be a folder under build/"), "\(flag)")
                #expect((fm.subpaths(atPath: root.path) ?? []).sorted() == before, "\(flag)")
            }
        }
    }

    @Test func aHomeToolFolderThatLinksToNothingPrintsTheWholeRefusal() throws {
        for name in [".claude", ".agent-balancer"] {
            try Self.withRenderRoot { root in
                let fm = FileManager.default
                let home = root.appendingPathComponent("home")
                try fm.createSymbolicLink(
                    atPath: home.appendingPathComponent(name).path,
                    withDestinationPath: root.appendingPathComponent("repo/build/t").path)
                let before = (fm.subpaths(atPath: root.path) ?? []).sorted()
                for flag in ["--render", "--iconset"] {
                    let (status, printed) = try Self.renderFlag(
                        [flag, "build/t"], cwd: root.appendingPathComponent("repo"), home: home)
                    #expect(status == 1, "\(name) \(flag)")
                    #expect(printed == Self.toolFolderRefusalText + "\n", "\(name) \(flag)")
                    #expect((fm.subpaths(atPath: root.path) ?? []).sorted() == before)
                }
            }
        }
    }
}
