import Foundation
import Testing

@testable import Core

/// The status example in the README's quick start is what the tool prints for the accounts of
/// the README's first picture: the main login account, with one session, and two token
/// accounts, each with a fresh reading. It is read with `status --cached`, which starts no child
/// process, so no `claude` is installed here. The days a window resets on depend on the day the
/// test runs, so both sides read each reset time as one placeholder; the order of the resets,
/// which decides the next launch, is the picture's.
@Suite struct ReadmeStatusExampleTests {
    /// The example's lines after its prompt line, as the README shows them.
    static func example() throws -> [String] {
        let readme = try ReadmeTests.read("README.md")
        let quick = try ReadmeTests.section("Quick start", of: readme)
        let block = try #require(quick.firstMatch(of: /```text\n([\s\S]*?)\n *```/))
        let lines = block.output.1.split(separator: "\n").map {
            String($0.drop { $0 == " " })
        }
        #expect(lines.first == "$ agent-balancer status --cached")
        return Array(lines.dropFirst())
    }

    static func timeless(_ lines: [String]) -> [String] {
        lines.map {
            $0.replacing(/resets [A-Z][a-z]{2} [0-9]{1,2}:[0-9]{2} [AP]M/, with: "resets <time>")
        }
    }

    @Test func theReadmeStatusExampleIsWhatTheToolPrints() throws {
        let shown = try Self.example()
        let cli = try CLIHome(installFake: false)
        defer { cli.cleanup() }
        let context = ToolContext(home: cli.home, ambient: [:])
        let now = Date()
        let iso = ISO8601DateFormatter()
        try ConfigStore(context: context).save(
            Config(accounts: [
                Account(
                    label: "main", kind: Kind.login, role: Role.main, email: "main@example.com",
                    expectedPlanTier: "max_20x"),
                Account(
                    label: "personal", kind: Kind.token, role: Role.pool,
                    email: "personal@example.com",
                    tokenCreatedAt: iso.string(from: now.addingTimeInterval(-14 * 86_400))),
                Account(
                    label: "lab", kind: Kind.token, role: Role.pool, email: "lab@example.com",
                    tokenCreatedAt: iso.string(from: now.addingTimeInterval(-7 * 86_400))),
            ]))
        for label in ["personal", "lab"] {
            try TokenStore.save(context: context, label: label, token: "made-up-\(label)")
        }
        // Weekly use, 5-hour use and Fable use, and the days to the weekly reset: personal resets
        // first, then lab, then main, as Tue, Wed and Fri do in the picture.
        let read = now.addingTimeInterval(-300)
        let store = ReadingStore(context: context)
        for (label, week, five, fable, days) in [
            ("main", 41.0, 18.0, 12.0, 4.0), ("personal", 47.0, 9.0, 93.0, 1.0),
            ("lab", 22.0, 4.0, 8.0, 2.0),
        ] {
            let reset = now.addingTimeInterval(days * 86_400)
            try store.save(
                Reading(
                    readAt: read,
                    windows: [
                        WindowName.sevenDay: WindowReading(
                            usedPercent: week, resetsAt: reset, readAt: read),
                        WindowName.fiveHour: WindowReading(
                            usedPercent: five, resetsAt: now.addingTimeInterval(3 * 3_600),
                            readAt: read),
                    ],
                    fable: FableReading(
                        source: ReadingSource.probe, usedPercent: fable, resetsAt: reset,
                        readAt: read),
                    fableProbedAt: read),
                label: label)
        }
        // One live session in the default folder, which counts toward the login account. The
        // first process is always alive.
        let sessions = cli.home.appendingPathComponent(".claude/sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try Data(#"{"sessionId": "example-session", "pid": 1}"#.utf8)
            .write(to: sessions.appendingPathComponent("example.json"))

        let out = try cli.run(["status", "--cached"], env: ["TZ": "America/Los_Angeles"])
        #expect(out.status == 0, "\(ReadmeTests.masked(out.stderr))")
        let printed = String(decoding: out.stdout, as: UTF8.self).split(separator: "\n")
            .map(String.init)
        #expect(Self.timeless(printed) == Self.timeless(shown))
        // No reset time is left out of the comparison: the example shows one on each row.
        #expect(shown.filter { $0.contains(" resets ") }.count == 3)
    }

    /// Each value the example shows, printed above from the test's own accounts, is the hero's.
    @Test func theReadmeStatusExampleIsTheFirstPicturesAccounts() throws {
        let hero = try #require(try ReadmeTests.fixture().first { $0.name == "hero" })
        let document = try ReadmeTests.object(hero.text)
        let rows = try #require(document["accounts"] as? [[String: Any]])
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX")
        time.timeZone = TimeZone(identifier: "America/Los_Angeles")
        time.dateFormat = "EEE h:mm a"
        let iso = ISO8601DateFormatter()
        var pictured: [String] = []
        for row in rows {
            let label = try #require(row["label"] as? String)
            let kind = try #require(row["kind"] as? String)
            let role = try #require(row["role"] as? String)
            let state = try #require(row["state"] as? String)
            let weekly = try #require(row["weekly"] as? [String: Any])
            let used = try #require(weekly["usedPercent"] as? Double)
            let stamp = try #require(weekly["resetsAt"] as? String)
            let reset = try #require(iso.date(from: stamp))
            let inUse = try #require((row["inUse"] as? [String: Any])?["count"] as? Int)
            // The menu draws no five-hour use, so the example's comes from the readings above.
            #expect(row["fiveHour"] == nil, "\(label)")
            pictured.append(
                "\(label) [\(kind), \(role)] \(state) week \(String(format: "%.1f", used))% "
                    + "resets \(time.string(from: reset)) in use \(inUse)")
        }
        let next = try #require(document["next"] as? [String: Any])
        for (key, line) in [("all", "next"), ("fable", "next for fable")] {
            let label = try #require((next[key] as? [String: Any])?["label"] as? String)
            pictured.append("\(line): \(label)")
        }
        let shown = try Self.example().map { $0.replacing(/[ ]5h [0-9.]+%[ ]/, with: " ") }
        #expect(pictured.count == 5)
        #expect(shown == pictured)
    }
}
