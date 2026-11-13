import Foundation
import Testing

@testable import Core

/// The menu controller against a fake agent-balancer: launch refresh, timers, errors.
@Suite(.serialized) struct MenuControllerTests {
    /// A temporary home with a fake tool that logs each call and obeys a few files.
    final class Fake {
        let home: URL
        let tool: URL
        let log: URL

        init(refreshExit: Int = 0, refreshError: String? = nil, mode: Int = 0o755) throws {
            home = FileManager.default.temporaryDirectory
                .appendingPathComponent("ab-menu-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            tool = home.appendingPathComponent("bin/agent-balancer")
            log = home.appendingPathComponent("calls.log")
            try FileManager.default.createDirectory(
                at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
            let err = refreshError.map { "echo '\($0)' >&2" } ?? ""
            let script = """
                #!/bin/sh
                echo "$*" >> "\(log.path)"
                env | cut -d= -f1 | sort > "\(home.path)/env-names.txt"
                if [ "$1" = "refresh" ]; then
                  \(err)
                  exit \(refreshExit)
                fi
                exit 0
                """
            try script.write(to: tool, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: mode], ofItemAtPath: tool.path)
        }

        deinit { try? FileManager.default.removeItem(at: home) }

        var context: ToolContext { ToolContext(home: home, ambient: ["SECRET_KEY": "x"]) }
        var runner: CLIRunner { CLIRunner(context: context, candidates: [tool]) }

        func calls() -> [String] {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }

        func writeConfig() throws {
            let writer = NoFollowWriter(root: context.dataRoot)
            let data = try JSONEncoder().encode(Config())
            try writer.put(data, folders: [], name: "config.json")
        }

        func writeStatus(generatedAt: Date) throws {
            let writer = NoFollowWriter(root: context.dataRoot)
            let stamp = ISO8601DateFormatter().string(from: generatedAt)
            let text = """
                { "schemaVersion": 1, "generatedAt": "\(stamp)", "banner": null,
                  "next": { "all": { "label": null, "reason": "r" }, "fable": { "label": null, "reason": "r" } },
                  "accounts": [ { "label": "main", "role": "main", "state": "ok",
                    "weekly": { "usedPercent": 10, "resetsAt": "2030-01-01T00:00:00Z", "source": "probe" } } ] }
                """
            try writer.put(Data(text.utf8), folders: ["state"], name: "status.json")
        }
    }

    @MainActor static func waitFor(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    @Test @MainActor func firstRefreshRunsWithinFiveSecondsOfLaunchWhenStatusIsMissing()
        async throws
    {
        let fake = try Fake()
        try fake.writeConfig()
        let controller = MenuController(context: fake.context, runner: fake.runner)
        let started = Date()
        controller.start()
        let saw = await Self.waitFor(5) { fake.calls().contains("refresh") }
        controller.stop()
        #expect(saw)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test @MainActor func launchRefreshRunsWhenStatusIsOld() async throws {
        let fake = try Fake()
        try fake.writeConfig()
        try fake.writeStatus(generatedAt: Date().addingTimeInterval(-3 * 3600))
        let controller = MenuController(context: fake.context, runner: fake.runner)
        controller.start()
        let saw = await Self.waitFor(5) { fake.calls().contains("refresh") }
        controller.stop()
        #expect(saw)
    }

    @Test @MainActor func launchRefreshIsSkippedWhenStatusIsFresh() async throws {
        let fake = try Fake()
        try fake.writeConfig()
        try fake.writeStatus(generatedAt: Date())
        var timing = MenuTiming()
        timing.refreshSecondsOverride = 3600
        let controller = MenuController(context: fake.context, runner: fake.runner, timing: timing)
        controller.start()
        try await Task.sleep(for: .seconds(1))
        controller.stop()
        #expect(!fake.calls().contains("refresh"))
    }

    @Test @MainActor func refreshRepeatsOnTheTimerAndStatusCachedRunsOnItsPoll() async throws {
        let fake = try Fake()
        try fake.writeConfig()
        var timing = MenuTiming()
        timing.refreshSecondsOverride = 0.3
        timing.statusPollSeconds = 0.3
        let controller = MenuController(context: fake.context, runner: fake.runner, timing: timing)
        controller.start()
        let saw = await Self.waitFor(8) {
            fake.calls().filter { $0 == "refresh" }.count >= 2
                && fake.calls().contains("status --cached")
        }
        controller.stop()
        #expect(saw)
    }

    @Test @MainActor func refreshNowShowsProgressThenTheRebuiltStatus() async throws {
        let fake = try Fake()
        try fake.writeConfig()
        let controller = MenuController(context: fake.context, runner: fake.runner)
        try fake.writeStatus(generatedAt: Date())
        let task = Task { await controller.refreshNow() }
        _ = await Self.waitFor(2) { controller.refreshState == .running }
        await task.value
        #expect(controller.refreshState == .idle)
        if case .accounts(let a) = controller.screen {
            #expect(a.rows.count == 1)
        } else {
            Issue.record("expected the rebuilt status")
        }
    }

    @Test @MainActor func refreshNowShowsTheToolsErrorText() async throws {
        let fake = try Fake(refreshExit: 1, refreshError: "refresh failed: probe timed out")
        try fake.writeConfig()
        let controller = MenuController(context: fake.context, runner: fake.runner)
        await controller.refreshNow()
        #expect(controller.refreshState == .failed("refresh failed: probe timed out"))
    }

    @Test @MainActor func refreshNowWithNoToolReportsItAndTheScreenIsACard() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ab-menu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let context = ToolContext(home: home, ambient: [:])
        let runner = CLIRunner(
            context: context, candidates: [home.appendingPathComponent("nope")])
        let controller = MenuController(context: context, runner: runner)
        await controller.refreshNow()
        #expect(controller.refreshState == .failed("agent-balancer was not found."))
        if case .card(let c) = controller.screen {
            #expect(c.title == "agent-balancer not found")
        } else {
            Issue.record("expected a card")
        }
    }

    @Test func toolIsRefusedWhenWritableByOthers() throws {
        let fake = try Fake(mode: 0o777)
        #expect(throws: ToolError.self) { try fake.runner.locate() }
    }

    @Test func toolIsFoundOnlyAtTheTwoFixedPaths() {
        #expect(
            CLIRunner.fixedPaths == [
                "/opt/homebrew/bin/agent-balancer", "/usr/local/bin/agent-balancer",
            ])
        let context = ToolContext(home: URL(fileURLWithPath: "/tmp/ab-none"), ambient: [:])
        #expect(CLIRunner(context: context).triedPaths == CLIRunner.fixedPaths)
    }

    @Test func childEnvironmentIsTheAllowlist() throws {
        let fake = try Fake()
        let out = try fake.runner.run(["status", "--cached"], timeout: 10)
        #expect(out.status == 0)
        let names = Set(
            ((try? String(
                contentsOf: fake.home.appendingPathComponent("env-names.txt"), encoding: .utf8))
                ?? "").split(separator: "\n").map(String.init))
        #expect(names.contains("HOME"))
        #expect(!names.contains("SECRET_KEY"))
        #expect(!names.contains("CLAUDE_CONFIG_DIR"))
    }

    @Test func statusReaderRefusesALinkedStatusFile() throws {
        let fake = try Fake()
        let state = fake.context.dataRoot.appendingPathComponent("state")
        try FileManager.default.createDirectory(
            at: state, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: fake.context.dataRoot.path)
        try FileManager.default.createSymbolicLink(
            atPath: state.appendingPathComponent("status.json").path,
            withDestinationPath: "/etc/hosts")
        let load = StatusReader(context: fake.context).load()
        if case .unreadable = load {} else { Issue.record("a linked status file must be refused") }
    }

    @Test func theAppSourcesNeverStartClaudeOrKeepPreferences() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AgentBalancerBar")
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".swift") }
        #expect(!names.isEmpty)
        for name in names {
            let text = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            for banned in [
                "ClaudeRunner", "TokenStore", "UserDefaults", "AppStorage", "token" + "s/",
            ] {
                #expect(!text.contains(banned), "\(name) mentions \(banned)")
            }
        }
    }
}
