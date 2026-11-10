import Foundation
import Testing

@testable import Core

@Suite struct ChildEnvironmentTests {
    let home = URL(fileURLWithPath: "/tmp/ab-env-home")
    let claudeDir = URL(fileURLWithPath: "/tmp/ab-env-home/.local/bin")

    func context(_ ambient: [String: String]) -> ToolContext {
        ToolContext(home: home, ambient: ambient)
    }

    var protectedAmbient: [String: String] {
        [
            "CLAUDE_CONFIG_DIR": "/elsewhere", ProtectedEnv.tokenVariable: Canaries.oauth(),
            "ANTHROPIC_API_KEY": Canaries.apiKey(), "ANTHROPIC_BASE_URL": "x",
            "CLAUDE_CODE_USE_BEDROCK": "1", "CLAUDE_CODE_USE_VERTEX": "1",
        ]
    }

    @Test func protectedGroupCoversEveryName() {
        for name in protectedAmbient.keys { #expect(ProtectedEnv.isProtected(name)) }
        #expect(!ProtectedEnv.isProtected("PATH"))
        #expect(!ProtectedEnv.isProtected("CLAUDE_CODE_CHILD_SESSION"))
    }

    @Test func probeEnvironmentIsAnAllowlist() {
        var ambient = protectedAmbient
        ambient["PATH"] = "/evil"
        ambient["USER"] = "me"
        ambient["LANG"] = "en_US.UTF-8"
        ambient["LC_ALL"] = "C"
        ambient["TMPDIR"] = "/tmp/x"
        ambient["HTTPS_PROXY"] = "http://proxy.example.com"
        ambient["AB_CANARY"] = Canaries.oauth()
        ambient["SSH_AUTH_SOCK"] = "/s"
        ambient["TERM"] = "xterm"
        let env = ChildEnvironment.probe(
            context: context(ambient), claudeFolder: claudeDir, configDir: nil, passProxyEnv: false)
        #expect(
            Set(env.keys) == ["PATH", "HOME", "USER", "LANG", "LC_ALL", "TMPDIR"])
        #expect(env["PATH"]!.hasPrefix(claudeDir.path + ":/opt/homebrew/bin"))
        #expect(env["HOME"] == home.path)
    }

    @Test func proxyNamesPassOnlyWhenAsked() {
        let ambient = ["HTTPS_PROXY": "p", "NO_PROXY": "n", "SSL_CERT_FILE": "c"]
        let off = ChildEnvironment.probe(
            context: context(ambient), claudeFolder: claudeDir, configDir: nil, passProxyEnv: false)
        let on = ChildEnvironment.probe(
            context: context(ambient), claudeFolder: claudeDir, configDir: nil, passProxyEnv: true)
        #expect(off["HTTPS_PROXY"] == nil)
        #expect(on["HTTPS_PROXY"] == "p" && on["NO_PROXY"] == "n" && on["SSL_CERT_FILE"] == "c")
    }

    @Test func configDirIsSetOnlyForANonDefaultFolder() {
        let ctx = context(["CLAUDE_CONFIG_DIR": "/ambient"])
        let other = home.appendingPathComponent("elsewhere/.claude")
        let set = ChildEnvironment.probe(
            context: ctx, claudeFolder: claudeDir, configDir: other, passProxyEnv: false)
        #expect(set["CLAUDE_CONFIG_DIR"] == other.path)
        let viaDefault = ChildEnvironment.probe(
            context: ctx, claudeFolder: claudeDir, configDir: ctx.defaultClaudeFolder,
            passProxyEnv: false)
        #expect(viaDefault["CLAUDE_CONFIG_DIR"] == nil)
        let none = ChildEnvironment.probe(
            context: ctx, claudeFolder: claudeDir, configDir: nil, passProxyEnv: false)
        #expect(none["CLAUDE_CONFIG_DIR"] == nil)
    }

    @Test func personLaunchKeepsTerminalAndAgentDropsProtectedGroup() {
        var ambient = protectedAmbient
        ambient["TERM"] = "xterm-256color"
        ambient["SSH_AUTH_SOCK"] = "/tmp/agent.sock"
        ambient["EDITOR"] = "vi"
        let env = ChildEnvironment.person(context: context(ambient), configDir: nil)
        #expect(env["TERM"] == "xterm-256color")
        #expect(env["SSH_AUTH_SOCK"] == "/tmp/agent.sock")
        #expect(env["EDITOR"] == "vi")
        for name in protectedAmbient.keys { #expect(env[name] == nil) }
    }

    @Test func personLaunchSetsConfigDirOnlyForNonDefault() {
        let ctx = context([:])
        let other = home.appendingPathComponent("acct/.claude")
        #expect(
            ChildEnvironment.person(context: ctx, configDir: other)["CLAUDE_CONFIG_DIR"]
                == other.path)
        #expect(
            ChildEnvironment.person(context: ctx, configDir: ctx.defaultClaudeFolder)[
                "CLAUDE_CONFIG_DIR"] == nil)
    }
}
