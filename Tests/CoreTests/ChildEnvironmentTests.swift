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

    @Test func theWholeClaudeCodePrefixIsProtectedExceptTheChatMarker() {
        for name in [
            "CLAUDE_CODE_GATEWAY_TOKEN", "CLAUDE_CODE_MANAGED_SETTINGS_PATH",
            "CLAUDE_CODE_ACCOUNT_UUID", "CLAUDE_CODE_SOMETHING_NEW", "ANTHROPIC_CUSTOM_HEADERS",
            "ANTHROPIC_FOUNDRY_API_KEY", "CLAUDE_ENV_FILE", "CLAUDE_CODE_SUBAGENT_MODEL",
            "ANTHROPIC_MODEL",
        ] {
            #expect(ProtectedEnv.isProtected(name), "\(name)")
        }
    }

    /// Names that carry a credential or choose the account, then names that do neither.
    static let credentialClass = [
        ProtectedEnv.tokenVariable, "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_FOUNDRY_API_KEY", "ANTHROPIC_CUSTOM_HEADERS", "CLAUDE_CODE_OAUTH_REFRESH_TOKEN",
        "CLAUDE_CODE_OAUTH_SCOPES", "CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR",
        "CLAUDE_CODE_GATEWAY_TOKEN_FILE_DESCRIPTOR", "CCR_AGENT_PROXY_TOKEN_FILE_DESCRIPTOR",
        "ANTHROPIC_BASE_URL", "ANTHROPIC_BEDROCK_BASE_URL", "CLAUDE_CODE_API_BASE_URL",
        "ANTHROPIC_PROFILE", "ANTHROPIC_CONFIG_DIR", "CLAUDE_CODE_USE_BEDROCK",
        "CLAUDE_CODE_USE_FOUNDRY", "CLAUDE_SECURESTORAGE_CONFIG_DIR",
        "CLAUDE_CODE_CUSTOM_OAUTH_URL", "CLAUDE_SESSION_INGRESS_TOKEN_FILE",
        "CLAUDE_BRIDGE_OAUTH_TOKEN", "CLAUDE_TRUSTED_DEVICE_TOKEN", "CLAUDE_BG_SESSION_CREDENTIAL",
        "USE_STAGING_OAUTH", "CLAUDE_LOCAL_OAUTH_API_BASE", "CCR_OAUTH_TOKEN_FILE",
    ]
    static let harmlessClass = [
        "CLAUDE_CODE_SUBAGENT_MODEL", "ANTHROPIC_MODEL", "ANTHROPIC_SMALL_FAST_MODEL",
        "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_MESSAGING_SOCKET",
        "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDE_CODE_ACCOUNT_UUID", "CLAUDE_CODE_SOMETHING_NEW",
        "CLAUDE_ENV_FILE", "CLAUDE_BG_AUTO_MEMORY_OFF", "CLAUDE_CODE_CHILD_SESSION", "PATH",
        ProtectedEnv.configDirVariable,
    ]

    @Test func onlyNamesThatCarryACredentialOrChooseTheAccountCountAsCredentials() {
        for name in Self.credentialClass {
            #expect(ProtectedEnv.carriesCredential(name), "\(name)")
            #expect(ProtectedEnv.isProtected(name), "\(name)")
        }
        for name in Self.harmlessClass {
            #expect(!ProtectedEnv.carriesCredential(name), "\(name)")
        }
    }

    @Test func hooksOffNamesAreFoundByWordsSoANewOneIsStillRefused() {
        for name in [
            "CLAUDE_CODE_SIMPLE", "CLAUDE_CODE_PERSONAL_HOOKS_OFF", "CLAUDE_CODE_RESTRICTED",
            "CLAUDE_CODE_RESTRICT_PERSONAL_CONFIG", "CLAUDE_CODE_SAFE_MODE",
            "CLAUDE_CODE_NEW_SAFE_X",
        ] {
            #expect(ProtectedEnv.mayDisableHooks(name), "\(name)")
        }
        #expect(!ProtectedEnv.mayDisableHooks("CLAUDE_CODE_CHILD_SESSION"))
        #expect(!ProtectedEnv.mayDisableHooks("PATH"))
    }

    @Test func everySettingsSourceTheProgramReadsCountsAsHooksOff() {
        for name in [
            "CLAUDE_CODE_MANAGED_SETTINGS_PATH", "CLAUDE_CODE_REMOTE_SETTINGS_PATH",
            "CLAUDE_CODE_MOCK_REMOTE_SETTINGS",
        ] {
            #expect(ProtectedEnv.mayDisableHooks(name), "\(name)")
            #expect(ProtectedEnv.switchesHooksOff(name), "\(name)")
        }
        // A chat shell carries these, so they must never refuse a line.
        for name in [
            "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_SUBAGENT_MODEL",
            "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN",
            "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_CODE_EXECPATH", "CLAUDE_CODE_CHILD_SESSION",
        ] {
            #expect(!ProtectedEnv.mayDisableHooks(name), "\(name)")
        }
        // Only an exact name counts in a settings file, so a timing knob blocks nothing there.
        #expect(!ProtectedEnv.switchesHooksOff("CLAUDE_CODE_SESSIONEND_HOOKS_TIMEOUT_MS"))
        #expect(ProtectedEnv.switchesHooksOff("CLAUDE_CODE_SIMPLE"))
    }

    /// Login locations outside the older prefixes, and members of each plumbing family.
    static let loginLocationClass = [
        "CLAUDE_SECURESTORAGE_CONFIG_DIR", "CLAUDE_SESSION_INGRESS_TOKEN_FILE",
        "CLAUDE_TRUSTED_DEVICE_TOKEN", "CLAUDE_REMOTE_TOOLS_BRIDGE_URL", "USE_LOCAL_OAUTH",
        "USE_STAGING_OAUTH", "AGENT_PROXY_AUTH_TOKEN", "CLAUDE_LOCAL_OAUTH_API_BASE",
        "CLAUDE_LOCAL_OAUTH_CONSOLE_BASE", "CLAUDE_BG_SESSION_CREDENTIAL",
        "CLAUDE_BG_AUTH_SNAPSHOT_PATH", "CLAUDE_BG_SOCKET_TOKENS_PATH", "CLAUDE_BG_RV_AUTH",
        "CLAUDE_BRIDGE_OAUTH_TOKEN", "CLAUDE_BRIDGE_BASE_URL", "CLAUDE_BRIDGE_SESSION_INGRESS_URL",
        "CLAUDE_RUNNER_ACCOUNT_EMAIL", "CLAUDE_RUNNER_CLAUDE_BIN", "CCR_OAUTH_TOKEN_FILE",
        "CCR_SESSION_ACCOUNT_EMAIL", "CLAUDE_BG_BACKEND",
    ]

    @Test func theLoginLocationsAndPlumbingFamiliesAreProtected() {
        for name in Self.loginLocationClass {
            #expect(ProtectedEnv.isProtected(name), "\(name)")
        }
        // A name of the user's own stays usable for a caller's settings.
        for name in ["CLAUDE_ROLE", "CLAUDE_CLIENT", "CLAUDE_PROJECT_TAG", "USE_COLOR"] {
            #expect(!ProtectedEnv.isProtected(name), "\(name)")
        }
    }

    @Test func aPersonLaunchDropsTheStoredLoginFolderAndItsSiblings() {
        var ambient = Dictionary(uniqueKeysWithValues: Self.loginLocationClass.map { ($0, "x") })
        ambient["TERM"] = "xterm"
        ambient["CLAUDE_ROLE"] = "worker"
        let env = ChildEnvironment.person(context: context(ambient), configDir: nil)
        for name in Self.loginLocationClass { #expect(env[name] == nil, "\(name)") }
        #expect(env["TERM"] == "xterm")
        #expect(env["CLAUDE_ROLE"] == "worker")
        let probe = ChildEnvironment.probe(
            context: context(ambient), claudeFolder: claudeDir, configDir: nil, passProxyEnv: true)
        for name in Self.loginLocationClass { #expect(probe[name] == nil, "\(name)") }
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
