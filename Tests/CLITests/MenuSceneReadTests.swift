import Foundation
import Testing

/// On macOS 14 the open panel stayed stale for a scene body read, so view bodies read the state.
@Suite struct MenuSceneReadTests {
    /// A scene body may read these two, since neither changes after launch.
    static let fixedMembers: Set<String> = ["manage", "copy"]

    /// Every scene body in the app's sources, with the file it is in.
    static func sceneBodies() throws -> [(String, String)] {
        let marker = "var body: some Scene"
        var out: [(String, String)] = []
        for (path, text) in try AppSurfaceTests.appSources() {
            var rest = text[...]
            while let found = rest.range(of: marker) {
                let scene = try #require(
                    AppSurfaceTests.block(after: marker, in: String(rest[found.lowerBound...])))
                out.append((path, scene))
                rest = rest[found.upperBound...]
            }
        }
        return out
    }

    @Test func aSceneBodyReadsOnlyModelMembersThatNeverChange() throws {
        let scenes = try Self.sceneBodies()
        #expect(!scenes.isEmpty)
        for (path, scene) in scenes {
            for match in scene.matches(of: /\bmodel\.(\w+)/) {
                let member = String(match.output.1)
                #expect(Self.fixedMembers.contains(member), "\(path): model.\(member)")
            }
        }
        // The list holds only while they stay a constant and a method.
        let app = try AppSurfaceTests.source("AppModel.swift")
        #expect(app.contains("    let manage: ManageViewModel\n"))
        #expect(app.contains("    func copy(_ text: String) {\n"))
    }

    @Test func theMenuPanelReadsTheControllerAndTheLoginItemInItsOwnBody() throws {
        let app = try AppSurfaceTests.source("AppModel.swift")
        let scene = try #require(AppSurfaceTests.block(after: "var body: some Scene", in: app))
        let content = try #require(AppSurfaceTests.block(after: "MenuBarExtra", in: scene))
        #expect(content.contains("MenuPanel(model: model)"))
        let panel = try #require(AppSurfaceTests.block(after: "struct MenuPanel: View", in: app))
        let body = try #require(AppSurfaceTests.block(after: "var body: some View", in: panel))
        for read in [
            "screen: model.controller.screen", "refreshState: model.controller.refreshState",
            "loginItemOn: model.loginItemOn", "loginItemError: model.loginItemError",
            "actions: model.actions",
        ] {
            #expect(body.contains(read), "\(read)")
        }
    }

    /// Without it the panel's body would not redraw for a change of Open at login.
    @Test func theAppModelStaysAMainActorObservableClass() throws {
        let app = try AppSurfaceTests.source("AppModel.swift")
        #expect(app.contains("@MainActor @Observable\nfinal class AppModel {"))
    }
}
