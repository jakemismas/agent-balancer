import Foundation
import Testing

@testable import Core

@Suite struct ClaudeRunnerTests {
    @Test func resolvesTheFakeInLocalBin() throws {
        let t = try TestHome()
        try t.installFake()
        try t.fakeFixture(auth: "logged_in")
        let located = try t.runner.locate()
        #expect(located.path == t.fakePath.path)
        let out = try t.runner.run(arguments: ["--version"])
        #expect(out.status == 0)
        #expect(out.stdout.contains("Claude Code"))
        #expect(t.fakeRecord("args.log").contains("--version"))
    }

    @Test func missingBinaryIsCheckFailed() throws {
        let t = try TestHome()
        let runner = ClaudeRunner(context: t.context, candidates: [t.fakePath])
        #expect(throws: ToolError.self) { try runner.locate() }
        do {
            _ = try runner.run(arguments: ["--version"])
            Issue.record("expected a throw")
        } catch let error as ToolError {
            #expect(error.code == .checkFailed)
        }
    }

    @Test func refusesAGroupWritableBinary() throws {
        let t = try TestHome()
        try t.installFake()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o775], ofItemAtPath: t.fakePath.path)
        do {
            _ = try t.runner.locate()
            Issue.record("expected a refusal")
        } catch let error as ToolError {
            #expect(error.code == .checkFailed)
        }
    }

    @Test func refusesAWritableLocalBinFolder() throws {
        let t = try TestHome()
        try t.installFake()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o777],
            ofItemAtPath: t.home.appendingPathComponent(".local/bin").path)
        #expect(throws: ToolError.self) { try t.runner.locate() }
    }

    @Test func aSymlinkedFakeMayChangeTargetBetweenRunsWithoutAFailure() throws {
        let t = try TestHome()
        try t.installFake()
        let real1 = t.home.appendingPathComponent("v1/claude")
        let real2 = t.home.appendingPathComponent("v2/claude")
        for real in [real1, real2] {
            try FileManager.default.createDirectory(
                at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: t.fakePath, to: real)
        }
        try FileManager.default.removeItem(at: t.fakePath)
        try FileManager.default.createSymbolicLink(at: t.fakePath, withDestinationURL: real1)
        let first = try t.runner.run(arguments: ["--version"])
        try FileManager.default.removeItem(at: t.fakePath)
        try FileManager.default.createSymbolicLink(at: t.fakePath, withDestinationURL: real2)
        let second = try t.runner.run(arguments: ["--version"])
        #expect(first.status == 0 && second.status == 0)
        #expect(try t.runner.locate().path == t.fakePath.path)
    }

    @Test func childSeesOnlyAllowlistedNames() throws {
        let t = try TestHome()
        try t.installFake()
        var ambient: [String: String] = [
            "CLAUDE_CONFIG_DIR": "/ambient", ProtectedEnv.tokenVariable: Canaries.oauth(),
            "ANTHROPIC_API_KEY": Canaries.apiKey(), "ANTHROPIC_BASE_URL": "u",
            "CLAUDE_CODE_USE_BEDROCK": "1", "CLAUDE_CODE_USE_VERTEX": "1",
            "AB_CANARY": Canaries.oauth(), "HTTPS_PROXY": "p", "SSH_AUTH_SOCK": "/s",
            "EDITOR": "vi", "PATH": "/evil",
        ]
        ambient["USER"] = "me"
        let runner = ClaudeRunner(context: t.context(ambient: ambient))
        _ = try runner.run(arguments: ["--version"])
        let seen = Set(
            t.fakeRecord("env-names.txt").split(separator: "\n").map(String.init))
        // The shell the fake runs in adds these on its own.
        let shellAdded: Set<String> = ["PWD", "SHLVL", "_", "OLDPWD"]
        let allowed: Set<String> = ["PATH", "HOME", "USER", "LOGNAME", "LANG", "TMPDIR"]
        #expect(seen.subtracting(shellAdded).isSubset(of: allowed), "saw \(seen)")
        #expect(
            t.fakeRecord("config-dir.txt").trimmingCharacters(in: .whitespacesAndNewlines)
                == "unset")
    }

    @Test func configDirIsSetOnlyForANonDefaultFolder() throws {
        let t = try TestHome()
        try t.installFake()
        let other = t.home.appendingPathComponent("acct/.claude")
        _ = try t.runner.run(arguments: ["--version"], configDir: other)
        #expect(
            t.fakeRecord("config-dir.txt").trimmingCharacters(in: .whitespacesAndNewlines)
                == other.path)
        _ = try t.runner.run(arguments: ["--version"], configDir: t.context.defaultClaudeFolder)
        #expect(
            t.fakeRecord("config-dir.txt").trimmingCharacters(in: .whitespacesAndNewlines)
                == "unset")
    }

    @Test func personEnvironmentDropsProtectedNamesAndKeepsTerm() throws {
        let t = try TestHome()
        try t.installFake()
        let ambient = [
            "HOME": t.home.path, "PATH": "/usr/bin:/bin", "TERM": "xterm", "SSH_AUTH_SOCK": "/s",
            "ANTHROPIC_API_KEY": Canaries.apiKey(),
            "CLAUDE_CONFIG_DIR": "/ambient",
        ]
        let runner = ClaudeRunner(context: t.context(ambient: ambient))
        _ = try runner.run(arguments: ["--version"], environment: .person)
        let seen = Set(t.fakeRecord("env-names.txt").split(separator: "\n").map(String.init))
        #expect(seen.contains("TERM") && seen.contains("SSH_AUTH_SOCK"))
        #expect(!seen.contains("ANTHROPIC_API_KEY") && !seen.contains("CLAUDE_CONFIG_DIR"))
    }

    @Test func timeoutEndsTheChild() throws {
        let t = try TestHome()
        try t.installFake()
        try t.fake("delay", "10")
        let started = Date()
        let out = try t.runner.run(arguments: ["--version"], timeout: 1)
        #expect(out.timedOut)
        #expect(Date().timeIntervalSince(started) < 8)
    }

    @Test func outputIsCappedAndScrubbedAsAWholeBuffer() throws {
        let t = try TestHome()
        try t.installFake()
        let secret = Canaries.oauth()
        let padding = String(repeating: "x ", count: 2040)
        try t.fake("auth.json", padding + secret + "\n" + String(repeating: "y", count: 5000))
        let out = try t.runner.run(arguments: ["auth", "status"], outputCap: 4200)
        #expect(out.truncated)
        #expect(out.stdout.utf8.count <= 4300)
        #expect(!out.stdout.contains(secret))
        #expect(!out.stdout.contains("sk-" + "ant-"))
    }

    @Test func stderrGetsBothScrubPasses() throws {
        let t = try TestHome()
        try t.installFake()
        let mail = Canaries.email()
        let secret = Canaries.apiKey()
        try t.fake("stderr.txt", "oops \(mail) \(secret) \(Canaries.homePath())\n")
        let out = try t.runner.run(arguments: ["--version"])
        #expect(!out.stderr.contains(mail))
        #expect(!out.stderr.contains(secret))
        #expect(!out.stderr.contains("/Users/pat"))
    }

    @Test func probeFormCarriesSafeModeOnlyWhenOn() {
        #expect(ProbeForm.arguments(safeMode: true).contains("--safe-mode"))
        #expect(!ProbeForm.arguments(safeMode: false).contains("--safe-mode"))
        #expect(ProbeForm.arguments(safeMode: false).contains("--strict-mcp-config"))
    }

    @Test func unknownOptionIsCheckFailedWithScrubbedText() throws {
        let t = try TestHome()
        try t.installFake()
        try t.fake("unknown-option", "1")
        let out = try t.runner.run(arguments: ProbeForm.arguments(safeMode: true))
        let issue = ProbeForm.failure(for: out)
        #expect(issue?.code == .checkFailed)
        #expect(issue?.text.contains("unknown option") == true)
    }

    @Test func noCodePathBuildsAShellCommand() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/Core/Runner/ClaudeRunner.swift"),
            encoding: .utf8)
        #expect(!source.contains("/bin/sh"))
        #expect(!source.contains("/bin/bash"))
        #expect(!source.contains("\"-c\""))
        #expect(source.contains("proc.arguments = arguments"))
    }
}
