import Foundation
import Observation

/// How often the menu app looks and runs the tool. Tests shorten these.
public struct MenuTiming: Sendable {
    /// Seconds between `status --cached` runs.
    public var statusPollSeconds: Double = 60
    /// Seconds between reads of `status.json`, which stand in for a file watcher.
    public var fileReadSeconds: Double = 5
    /// Overrides `refresh.backgroundMinutes` as a number of seconds when set.
    public var refreshSecondsOverride: Double?
    public var refreshTimeoutSeconds: Double = 300
    public var statusTimeoutSeconds: Double = 60

    public init() {}
}

/// The state behind the menu: it reads the status document, runs the tool's `refresh` at launch
/// when the document is missing or old and then on a timer, and runs `status --cached` every 60
/// seconds. It writes no file and runs only the agent-balancer tool.
@MainActor @Observable
public final class MenuController {
    public private(set) var screen: MenuScreen
    public private(set) var refreshState: RefreshState = .idle

    @ObservationIgnored private let reader: StatusReader
    @ObservationIgnored private let runner: CLIRunner
    @ObservationIgnored private let timing: MenuTiming
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    public init(
        context: ToolContext, runner: CLIRunner? = nil, timing: MenuTiming = MenuTiming(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.reader = StatusReader(context: context)
        self.runner = runner ?? CLIRunner(context: context)
        self.timing = timing
        self.clock = clock
        self.screen = .card(
            CardModel(
                title: "Reading accounts", text: "The first reading takes a minute.", command: nil,
                lines: []))
        reload()
    }

    /// Reads the files and rebuilds the screen. Cheap, and safe to call often.
    public func reload() {
        let inputs = MenuInputs(
            configExists: reader.configExists(), cliFound: runner.isAvailable,
            cliTried: runner.triedPaths, status: reader.load(), now: clock(),
            backgroundMinutes: reader.backgroundMinutes())
        let next = MenuBuilder.screen(inputs)
        if next != screen { screen = next }
    }

    public func start() {
        guard tasks.isEmpty else { return }
        tasks = [
            Task { [weak self] in await self?.refreshLoop() },
            Task { [weak self] in await self?.statusLoop() },
            Task { [weak self] in await self?.fileLoop() },
        ]
    }

    public func stop() {
        for t in tasks { t.cancel() }
        tasks = []
    }

    private func refreshIntervalSeconds() -> Double {
        timing.refreshSecondsOverride ?? Double(reader.backgroundMinutes() * 60)
    }

    /// True when `status.json` is missing, cannot be read, or is older than the interval.
    private func needsLaunchRefresh() -> Bool {
        switch reader.load() {
        case .loaded(let snapshot):
            guard let at = snapshot.generatedAt else { return true }
            return clock().timeIntervalSince(at) > refreshIntervalSeconds()
        case .newerSchema: return false
        case .missing, .unreadable: return true
        }
    }

    private func refreshLoop() async {
        if needsLaunchRefresh() { await refreshNow() }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(refreshIntervalSeconds()))
            if Task.isCancelled { return }
            await refreshNow()
        }
    }

    private func statusLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(timing.statusPollSeconds))
            if Task.isCancelled { return }
            let runner = self.runner
            let timeout = timing.statusTimeoutSeconds
            _ = await Self.runOffMain { try runner.run(["status", "--cached"], timeout: timeout) }
            reload()
        }
    }

    private func fileLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(timing.fileReadSeconds))
            if Task.isCancelled { return }
            reload()
        }
    }

    /// Runs `agent-balancer refresh`, shows progress, then the rebuilt status or the tool's own
    /// error text.
    public func refreshNow() async {
        if refreshState == .running { return }
        refreshState = .running
        let runner = self.runner
        let timeout = timing.refreshTimeoutSeconds
        let result = await Self.runOffMain { try runner.run(["refresh"], timeout: timeout) }
        switch result {
        case .failure(let error):
            refreshState = .failed(Self.firstLine(error.localizedDescription))
        case .success(let output):
            if output.timedOut {
                refreshState = .failed("Refresh timed out.")
            } else if output.status != 0 {
                let text = output.stderr.isEmpty ? output.stdout : output.stderr
                let shown = Self.firstLine(text)
                refreshState = .failed(
                    shown.isEmpty ? "Refresh failed (exit \(output.status))." : shown)
            } else {
                refreshState = .idle
            }
        }
        reload()
    }

    private static func firstLine(_ text: String) -> String {
        let line =
            text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return Display.safe(line, limit: 240)
    }

    private static func runOffMain(
        _ work: @escaping @Sendable () throws -> RunOutput
    ) async -> Result<RunOutput, Error> {
        await Task.detached { Result { try work() } }.value
    }
}
