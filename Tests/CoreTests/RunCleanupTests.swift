import Foundation
import Testing

@testable import Core

/// `run` when its settings path cannot be fixed by a reader, and what it leaves when the lease
/// save after its launch file fails.
extension RunSettingsVerdictTests {
    func refusal(_ service: PickService, label: String = "main") -> ToolError? {
        do {
            _ = try service.prepareRun(label: label, arguments: [])
            return nil
        } catch {
            return error as? ToolError
        }
    }

    @Test func aSettingsLinkThatGoesNowhereRefusesRunWithTheTextThatNamesTheFix() throws {
        let (t, service) = try setUp(settings: hookBody)
        let url = settingsURL(t)
        let hooks = HookRecord(context: t.context)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(
            at: url, withDestinationURL: t.home.appendingPathComponent("gone.json"))
        // A reader runs, as the advice to run doctor would have it, and run still refuses.
        _ = try? hooks.readSettings()
        let before = tree(t)
        let dangling = try #require(refusal(service))
        #expect(dangling.message == Messages.settingsLinkGoesNowhere)
        #expect(dangling.code == .settingsChanged)
        #expect(dangling.message.contains("Repair the link or remove it"))
        #expect(tree(t) == before && !startedClaude(t))
        // A link to itself goes nowhere too.
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: url)
        _ = try? hooks.readSettings()
        #expect(refusal(service)?.message == Messages.settingsLinkGoesNowhere)
        // A folder at the settings path is not a file.
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        _ = try? hooks.readSettings()
        #expect(refusal(service)?.message == Messages.settingsNotAFile)
        // Repaired and read again, run goes ahead.
        try FileManager.default.removeItem(at: url)
        try writeSettings(t, hookBody)
        _ = try hooks.readSettings()
        #expect(refusal(service) == nil)
    }

    @Test func aFailedLeaseSaveInRunDropsTheLaunchFileItWrote() throws {
        let (t, service) = try setUp(settings: hookBody)
        try installToken(t)
        let state = t.context.dataRoot.appendingPathComponent("state")
        chmod(state.path, 0o500)
        defer { chmod(state.path, 0o700) }
        try #require(access(state.path, W_OK) != 0)
        #expect(refusal(service, label: "pool-a") != nil)
        chmod(state.path, 0o700)
        let launch = LaunchFiles.rootURL(context: t.context).appendingPathComponent("pool-a")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: launch.path)) ?? []
        #expect(left.filter { $0.hasSuffix(".json") }.isEmpty)
        #expect(TokenAccounts.openLeaseCount(context: t.context, leaseMinutes: 30) == 0)
        #expect(!startedClaude(t))
    }

    @Test func aFailedLeaseSaveInPickDropsTheLaunchFileItWrote() throws {
        let (t, _) = try setUp(settings: hookBody, accounts: [login()])
        try t.fakeProbe("ok.jsonl")
        let state = t.context.dataRoot.appendingPathComponent("state")
        // A first pick stores a reading, so the second one probes nothing.
        _ = try PickService(context: t.context).pick(PickRequest(caller: .launcher))
        let launch = LaunchFiles.rootURL(context: t.context).appendingPathComponent("main")
        func launchFiles() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: launch.path)) ?? [])
                .filter { $0.hasSuffix(".json") }
        }
        let before = launchFiles()
        let leases = try Data(contentsOf: state.appendingPathComponent("leases.json"))
        chmod(state.path, 0o500)
        defer { chmod(state.path, 0o700) }
        try #require(access(state.path, W_OK) != 0)
        #expect(throws: ToolError.self) {
            _ = try PickService(context: t.context).pick(PickRequest(caller: .launcher))
        }
        chmod(state.path, 0o700)
        #expect(launchFiles() == before)
        #expect(try Data(contentsOf: state.appendingPathComponent("leases.json")) == leases)
    }
}
