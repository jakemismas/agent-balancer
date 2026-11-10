import Foundation

@testable import Core

/// A temporary home folder with an optional fake `claude`, one per test.
final class TestHome {
    let home: URL
    let fixtures: URL

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ab-core-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }

    deinit { try? FileManager.default.removeItem(at: home) }

    var context: ToolContext { ToolContext(home: home, ambient: [:]) }

    func context(ambient: [String: String]) -> ToolContext {
        ToolContext(home: home, ambient: ambient)
    }

    var fakePath: URL { home.appendingPathComponent(".local/bin/claude") }

    /// Copies the fake `claude` to `.local/bin/claude`, the first entry of the runner's list.
    func installFake() throws {
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(
            at: bin, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try? FileManager.default.removeItem(at: fakePath)
        try FileManager.default.copyItem(
            at: fixtures.appendingPathComponent("bin/claude"), to: fakePath)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fakePath.path)
    }

    private var fakeDir: URL { home.appendingPathComponent(".ab-fake") }

    func fake(_ name: String, _ text: String) throws {
        try FileManager.default.createDirectory(at: fakeDir, withIntermediateDirectories: true)
        try text.write(to: fakeDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func fakeFixture(auth fixture: String, exit: Int = 0) throws {
        let text = try String(
            contentsOf: fixtures.appendingPathComponent("auth/\(fixture).json"), encoding: .utf8)
        try fake("auth.json", text)
        try fake("auth.exit", "\(exit)")
    }

    func fakeRecord(_ name: String) -> String {
        (try? String(contentsOf: fakeDir.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }

    var runner: ClaudeRunner { ClaudeRunner(context: context) }
}

/// Canaries are built at runtime from split strings so no whole token or email is stored.
enum Canaries {
    static func tail(_ n: Int = 40) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<n).map { _ in alphabet.randomElement()! })
    }

    static func oauth() -> String { "sk-" + "ant-" + "oat01-" + tail() }
    static func apiKey() -> String { "sk-" + "ant-" + "api03-" + tail() }
    static func email() -> String { "pat." + tail(6).lowercased() + "@" + "contoso" + ".test" }
    static func orgId() -> String { UUID().uuidString.lowercased() }
    static func homePath() -> String { "/Users/" + "pat" + tail(4).lowercased() + "/work" }
}
