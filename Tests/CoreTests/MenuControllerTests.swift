import Foundation
import Observation
import Testing

@testable import Core

/// The menu controller against a fake agent-balancer: launch refresh, timers, errors.
@Suite(.serialized) struct MenuControllerTests {
    /// A temporary home with a fake tool that logs each call and obeys a few files.
    final class Fake {
        /// What the fake's refresh does before it prints its error and exits.
        enum Step {
            case none
            /// Moves a valid config.json into place, as an `init` that ends during the run.
            case setUp
            /// Sleeps past any refresh timeout a test sets.
            case hang
            /// Once config.json is there, waits for `release()` and then succeeds.
            case holdOnceSetUp
        }

        let home: URL
        let tool: URL
        let log: URL

        init(
            refreshExit: Int = 0, refreshError: String? = nil, mode: Int = 0o755,
            first step: Step = .none
        ) throws {
            home = FileManager.default.temporaryDirectory
                .appendingPathComponent("ab-menu-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            tool = home.appendingPathComponent("bin/agent-balancer")
            log = home.appendingPathComponent("calls.log")
            try FileManager.default.createDirectory(
                at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
            let root = context.dataRoot.path
            let first: String
            switch step {
            case .none: first = ""
            case .setUp: first = "mv '\(root)/staged.json' '\(root)/config.json'"
            case .hang: first = "exec sleep 30"
            case .holdOnceSetUp:
                // Bounded, so a failed test leaves no fake behind.
                first = """
                    if [ -e '\(root)/config.json' ]; then
                      n=0
                      while [ ! -e '\(home.path)/go' ] && [ $n -lt 600 ]; do
                        sleep 0.05
                        n=$((n + 1))
                      done
                      exit 0
                    fi
                    """
            }
            let err = refreshError.map { "echo '\($0)' >&2" } ?? ""
            let script = """
                #!/bin/sh
                echo "$*" >> "\(log.path)"
                env | cut -d= -f1 | sort > "\(home.path)/env-names.txt"
                if [ "$1" = "refresh" ]; then
                  \(first)
                  \(err)
                  exit \(refreshExit)
                fi
                exit 0
                """
            try script.write(to: tool, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: mode], ofItemAtPath: tool.path)
            if step == .setUp { try writeConfig(name: "staged.json") }
        }

        deinit { try? FileManager.default.removeItem(at: home) }

        var context: ToolContext { ToolContext(home: home, ambient: ["SECRET_KEY": "x"]) }
        var runner: CLIRunner { CLIRunner(context: context, candidates: [tool]) }

        func calls() -> [String] {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }

        /// A valid config.json, or `data` in its place.
        func writeConfig(_ data: Data? = nil, name: String = "config.json") throws {
            let writer = NoFollowWriter(root: context.dataRoot)
            try writer.put(data ?? JSONEncoder().encode(Config()), folders: [], name: name)
        }

        /// The two files `init` leaves.
        func writeConfigAndStatus() throws {
            try writeConfig()
            try writeStatus(generatedAt: Date())
        }

        func release() throws {
            try Data().write(to: home.appendingPathComponent("go"))
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
        let saw = await Self.waitFor(300) { fake.calls().contains("refresh") }
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
        let saw = await Self.waitFor(300) {
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

    /// The first error line of the real tool's `refresh` before `init`.
    static let setupError = "Error: \(Messages.notSetUp)"
    static let probeError = "refresh failed: probe timed out"

    @Test @MainActor func aRefreshThatFailedBeforeSetupClearsAtTheFirstReadThatFindsTheConfig()
        async throws
    {
        let fake = try Fake(refreshExit: 1, refreshError: Self.setupError)
        let controller = MenuController(context: fake.context, runner: fake.runner)
        await controller.refreshNow()
        #expect(controller.refreshState == .failed(Self.setupError))
        try fake.writeConfig()
        try fake.writeStatus(generatedAt: Date())
        controller.reload()
        #expect(controller.refreshState == .idle)
        if case .accounts(let a) = controller.screen {
            #expect(a.rows.map(\.label) == ["main"])
        } else {
            Issue.record("expected the account")
        }
    }

    @Test @MainActor func aRefreshThatFailedWithTheConfigThereStaysFailedAfterARead()
        async throws
    {
        // The setup text alone does not clear it: config.json was there when this refresh began.
        let fake = try Fake(refreshExit: 1, refreshError: Self.setupError)
        try fake.writeConfig()
        let controller = MenuController(context: fake.context, runner: fake.runner)
        await controller.refreshNow()
        try fake.writeStatus(generatedAt: Date())
        controller.reload()
        #expect(controller.refreshState == .failed(Self.setupError))
    }

    @Test @MainActor func aRefreshThatFailedBeforeSetupStaysWhileTheConfigIsMissing()
        async throws
    {
        let fake = try Fake(refreshExit: 1, refreshError: Self.setupError)
        let controller = MenuController(context: fake.context, runner: fake.runner)
        await controller.refreshNow()
        try fake.writeStatus(generatedAt: Date())
        controller.reload()
        #expect(controller.refreshState == .failed(Self.setupError))
    }

    @Test @MainActor func aSetupFailureClearsWithOnlyTheConfigAndTheClearRunsNoTool()
        async throws
    {
        let fake = try Fake(refreshExit: 1, refreshError: Self.setupError)
        let controller = MenuController(context: fake.context, runner: fake.runner)
        await controller.refreshNow()
        #expect(controller.refreshState == .failed(Self.setupError))
        try fake.writeConfig()
        controller.reload()
        #expect(controller.refreshState == .idle)
        #expect(fake.calls() == ["refresh"])
    }

    @Test @MainActor func aSetupFailureStaysWhileTheConfigDoesNotLoad() async throws {
        let fake = try Fake(refreshExit: 1, refreshError: Self.setupError)
        let controller = MenuController(context: fake.context, runner: fake.runner)
        await controller.refreshNow()
        try fake.writeConfig(Data("{".utf8))
        controller.reload()
        #expect(controller.refreshState == .failed(Self.setupError))
        try fake.writeConfig()
        controller.reload()
        #expect(controller.refreshState == .idle)
    }

    @Test @MainActor func aToolNotFoundBeforeSetupStaysOnceAValidConfigIsThere() async throws {
        let fake = try Fake()
        let runner = CLIRunner(
            context: fake.context, candidates: [fake.home.appendingPathComponent("nope")])
        let controller = MenuController(context: fake.context, runner: runner)
        await controller.refreshNow()
        #expect(controller.refreshState == .failed("agent-balancer was not found."))
        try fake.writeConfigAndStatus()
        controller.reload()
        #expect(controller.refreshState == .failed("agent-balancer was not found."))
    }

    @Test @MainActor func aRefusedToolBeforeSetupStaysOnceAValidConfigIsThere() async throws {
        let fake = try Fake(mode: 0o777)
        let controller = MenuController(context: fake.context, runner: fake.runner)
        await controller.refreshNow()
        let refused = controller.refreshState
        if case .failed(let text) = refused {
            #expect(text.hasPrefix("Refused "))
        } else {
            Issue.record("expected the refusal")
        }
        try fake.writeConfigAndStatus()
        controller.reload()
        #expect(controller.refreshState == refused)
    }

    @Test @MainActor func aRefreshThatTimedOutBeforeSetupStaysOnceAValidConfigIsThere()
        async throws
    {
        let fake = try Fake(first: .hang)
        var timing = MenuTiming()
        timing.refreshTimeoutSeconds = 0.5
        let controller = MenuController(context: fake.context, runner: fake.runner, timing: timing)
        await controller.refreshNow()
        #expect(controller.refreshState == .failed("Refresh timed out."))
        try fake.writeConfigAndStatus()
        controller.reload()
        #expect(controller.refreshState == .failed("Refresh timed out."))
    }

    @Test @MainActor func anotherErrorBeforeSetupStaysOnceAValidConfigIsThere() async throws {
        let fake = try Fake(refreshExit: 1, refreshError: Self.probeError)
        let controller = MenuController(context: fake.context, runner: fake.runner)
        await controller.refreshNow()
        #expect(controller.refreshState == .failed(Self.probeError))
        try fake.writeConfigAndStatus()
        controller.reload()
        #expect(controller.refreshState == .failed(Self.probeError))
    }

    @Test @MainActor func aSetupMessageUnderAnotherErrorLineStaysOnceAValidConfigIsThere()
        async throws
    {
        let fake = try Fake(refreshExit: 1, refreshError: "Error: crashed\n\(Self.setupError)")
        let controller = MenuController(context: fake.context, runner: fake.runner)
        await controller.refreshNow()
        #expect(controller.refreshState == .failed("Error: crashed"))
        try fake.writeConfigAndStatus()
        controller.reload()
        #expect(controller.refreshState == .failed("Error: crashed"))
    }

    @Test @MainActor func aRefreshThatOverlappedInitAndFailedForAnotherReasonShowsItsError()
        async throws
    {
        let fake = try Fake(refreshExit: 1, refreshError: Self.probeError, first: .setUp)
        let controller = MenuController(context: fake.context, runner: fake.runner)
        await controller.refreshNow()
        #expect(StatusReader(context: fake.context).configExists())
        #expect(controller.refreshState == .failed(Self.probeError))
        controller.reload()
        #expect(controller.refreshState == .failed(Self.probeError))
    }

    @Test @MainActor func aSetupErrorFromARefreshThatOverlappedInitClearsAtTheNextRead()
        async throws
    {
        let fake = try Fake(refreshExit: 1, refreshError: Self.setupError, first: .setUp)
        let controller = MenuController(context: fake.context, runner: fake.runner)
        await controller.refreshNow()
        #expect(StatusReader(context: fake.context).configExists())
        #expect(controller.refreshState == .idle)
    }

    @Test @MainActor func aReadDuringARefreshNowAfterASetupFailureAndInitKeepsItRunning()
        async throws
    {
        let fake = try Fake(refreshExit: 1, refreshError: Self.setupError, first: .holdOnceSetUp)
        let controller = MenuController(context: fake.context, runner: fake.runner)
        await controller.refreshNow()
        #expect(controller.refreshState == .failed(Self.setupError))
        try fake.writeConfig()
        let task = Task { await controller.refreshNow() }
        let running = await Self.waitFor(5) { controller.refreshState == .running }
        controller.reload()
        #expect(running)
        #expect(controller.refreshState == .running)
        try fake.release()
        await task.value
        #expect(controller.refreshState == .idle)
    }

    @Test @MainActor func aStatusFileChangeAndAReloadNotifyAnObserverOfTheScreen() throws {
        let fake = try Fake()
        try fake.writeConfig()
        let controller = MenuController(context: fake.context, runner: fake.runner)
        let changes = Counter()
        withObservationTracking {
            _ = controller.screen
        } onChange: {
            changes.add()
        }
        try fake.writeStatus(generatedAt: Date())
        controller.reload()
        #expect(changes.value == 1)
    }

    @Test @MainActor func aRefreshNowNotifiesAnObserverOfTheRefreshState() async throws {
        let fake = try Fake()
        try fake.writeConfig()
        let controller = MenuController(context: fake.context, runner: fake.runner)
        let changes = Counter()
        withObservationTracking {
            _ = controller.refreshState
        } onChange: {
            changes.add()
        }
        await controller.refreshNow()
        #expect(changes.value == 1)
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
