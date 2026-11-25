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
    /// True after the setup error failed a refresh begun with no config, which setup makes stale.
    @ObservationIgnored private var failedBeforeSetup = false
    /// Runs after each pass of the file loop, so an open Manage accounts window reads the same
    /// file on the same beat.
    @ObservationIgnored public var afterFileRead: (@MainActor () -> Void)?
    /// When set, replaces the sleep before each pass of the file loop, so a test can step it.
    @ObservationIgnored var fileWait: (@MainActor () async -> Void)?

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

    /// Reads the files and rebuilds the screen. Once `config.json` loads as a valid config, it also
    /// clears a refresh that failed because setup had not run. Cheap, and safe to call often.
    public func reload() {
        let config = reader.validConfig()
        let inputs = MenuInputs(
            configExists: reader.configExists(), cliFound: runner.isAvailable,
            cliTried: runner.triedPaths, status: reader.load(), now: clock(),
            backgroundMinutes: StatusReader.backgroundMinutes(config))
        if failedBeforeSetup && config != nil {
            failedBeforeSetup = false
            refreshState = .idle
        }
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
        timing.refreshSecondsOverride
            ?? Self.refreshSeconds(backgroundMinutes: reader.backgroundMinutes())
    }

    /// The refresh interval in seconds, worked out in `Double` so no interval can overflow.
    nonisolated static func refreshSeconds(backgroundMinutes: Int) -> Double {
        Double(backgroundMinutes) * 60
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
            if let fileWait {
                await fileWait()
            } else {
                try? await Task.sleep(for: .seconds(timing.fileReadSeconds))
            }
            if Task.isCancelled { return }
            reload()
            afterFileRead?()
        }
    }

    /// Runs `agent-balancer refresh`, shows progress, then the rebuilt status or the tool's own
    /// error text.
    public func refreshNow() async {
        if refreshState == .running { return }
        let beforeSetup = !reader.configExists()
        refreshState = .running
        failedBeforeSetup = false
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
                // The shown line decides, so a clear never hides another error's text.
                failedBeforeSetup = beforeSetup && shown.contains(Messages.notSetUp)
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
