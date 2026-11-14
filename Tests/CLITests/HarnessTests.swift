import Core
import Foundation
import Testing

/// The helpers the CLI tests run commands through: input a command never reads, and a prompt
/// that never comes.
@Suite struct HarnessTests {
    @Test func aCommandThatExitsBeforeReadingItsInputLeavesTheTestProcessRunning() throws {
        let cli = try CLIHome(installFake: false)
        defer { cli.cleanup() }
        // Far more than a pipe holds, so the write is still going when the command exits.
        let input = String(repeating: "x", count: 1 << 20)
        let out = try cli.run(["--version"], stdin: input)
        #expect(out.status == 0)
        #expect(String(decoding: out.stdout, as: UTF8.self).contains(Version.current))
    }

    @Test func aPromptThatNeverAppearsFailsTheTestInsteadOfHanging() throws {
        let cli = try CLIHome(installFake: false)
        defer { cli.cleanup() }
        try ConfigStore(context: ToolContext(home: cli.home, ambient: [:])).save(
            Config(accounts: []))
        let started = Date()
        #expect(throws: Support.PromptNotShown.self) {
            _ = try cli.runOnTerminal(
                ["uninstall"], prompt: "A prompt the command never prints: ", between: {},
                typing: "no\n", deadline: 2)
        }
        #expect(Date().timeIntervalSince(started) < 20)
        #expect(!cli.read("config.json").isEmpty)
    }
}
