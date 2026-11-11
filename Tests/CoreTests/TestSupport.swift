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

    /// Makes the fake `claude` answer a probe with a recorded stream. With a `model`, only a probe
    /// run with that model gets it.
    func fakeProbe(_ fixture: String, model: String? = nil, now: Date = Date()) throws {
        let text = try probeFixture(fixture, now: now)
        try fake(model.map { "probe-\($0).jsonl" } ?? "probe.jsonl", text)
    }

    /// A probe fixture with its reset-time placeholders filled in relative to `now`, so the
    /// reset times sit inside the window bounds whatever the clock.
    func probeFixture(_ name: String, now: Date) throws -> String {
        try String(contentsOf: fixtures.appendingPathComponent("probe/\(name)"), encoding: .utf8)
            .replacingOccurrences(
                of: "@RESET_5H@", with: "\(Int(now.timeIntervalSince1970) + 10_000)"
            )
            .replacingOccurrences(
                of: "@RESET_7D@", with: "\(Int(now.timeIntervalSince1970) + 400_000)"
            )
            .replacingOccurrences(
                of: "@RESET_31D@", with: "\(Int(now.timeIntervalSince1970) + 2_000_000)")
    }

    /// Writes a hand-made token file for `label` with `secret` as its value, at mode 0600.
    func makeTokenFile(label: String, secret: String) throws -> URL {
        try FileManager.default.createDirectory(
            at: context.dataRoot, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let url = try TokenPaths.fileURL(context: context, label: label)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let body = "{\"env\":{\"\(ProtectedEnv.tokenVariable)\":\"\(secret)\"}}"
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    func fakeLines(_ name: String) -> [String] {
        fakeRecord(name).split(separator: "\n").map(String.init)
    }

    /// The text of every regular file under the home folder except `skipping`.
    func allText(skipping: URL? = nil) -> String {
        guard
            let walker = FileManager.default.enumerator(
                at: home, includingPropertiesForKeys: [.isRegularFileKey])
        else { return "" }
        var text = ""
        for case let url as URL in walker {
            if url.resolvingSymlinksInPath().path == skipping?.resolvingSymlinksInPath().path {
                continue
            }
            text += (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        return text
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

/// A clock tests can move.
final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date = Date()) { current = start }
    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }
    func advance(_ seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }
}

/// Counts calls from the reading cache's hook.
final class HookCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ label: String) {
        lock.lock()
        items.append(label)
        lock.unlock()
    }
    var labels: [String] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}
