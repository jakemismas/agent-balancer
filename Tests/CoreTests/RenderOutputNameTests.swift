import Foundation
import Testing

@testable import Core

/// A home given through a link names its tool folders by another spelling, and one not made yet
/// has no identity to compare, so the render rule refuses those names anywhere below the current
/// folder.
extension RenderOutputTests {
    @Test func aToolFolderNameBelowTheCurrentFolderIsRefusedInAnySpellingOfTheHome() throws {
        let place = try Place()
        // The home lies under the current build folder and has no tool folder yet; HOME names
        // it through a link to the current folder.
        let home = place.cwd.appendingPathComponent("build/h")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        try place.link("linked-repo", to: place.cwd)
        let spelled = place.root.appendingPathComponent("linked-repo/build/h")
        let before = place.entries()
        for argument in [
            "build/h/.claude", "build/h/.agent-balancer", "build/h/.CLAUDE",
            "build/h/.Agent-Balancer", "build/h/.claude/renders", "build/other/.claude",
            "build/.agent-balancer/x", place.cwd.path + "/build/h/.claude",
        ] {
            #expect(throws: ToolError.self, "\(argument)") {
                try RenderOutput.folder(
                    argument, currentDirectoryPath: place.cwd.path, homes: [spelled])
            }
            #expect(throws: ToolError.self, "\(argument)") {
                _ = try RenderOutput.hold(
                    argument, currentDirectoryPath: place.cwd.path, homes: [spelled])
            }
        }
        #expect(place.entries() == before)
        // Names that only look alike still pass.
        let build = place.cwd.appendingPathComponent("build").path
        #expect(try place.check("build/h/.claude-renders").path == build + "/h/.claude-renders")
        #expect(try place.check("build/claude").path == build + "/claude")
    }
}
