import Foundation
import Testing

@testable import Core

@Suite struct CallerSettingsTests {
    func launch(envNames: [String] = ["MY_FLAG"], keys: [String] = ["env"]) -> LaunchSettings {
        LaunchSettings(settingsKeys: keys, envNames: envNames)
    }

    func refusal(_ text: String?, _ l: LaunchSettings? = nil) -> String? {
        do {
            _ = try CallerSettings.validate(text, launch: l ?? launch())
            return nil
        } catch let e as ToolError { return e.message } catch { return "other" }
    }

    @Test func noSettingsAndAnEmptyObjectPass() {
        #expect(refusal(nil) == nil)
        #expect(refusal("{}") == nil)
        #expect(refusal("{\"env\":{\"MY_FLAG\":\"1\"}}") == nil)
    }

    @Test func rejectsAnythingThatIsNotOneSmallObject() {
        #expect(refusal("[1]") != nil)
        #expect(refusal("nope") != nil)
        #expect(refusal("{\"env\":") != nil)
        let big = "{\"env\":{\"MY_FLAG\":\"" + String(repeating: "x", count: 17_000) + "\"}}"
        #expect(refusal(big)?.contains("larger") == true)
    }

    @Test func topLevelKeysMustBeInTheConfigList() {
        let hooks = refusal("{\"hooks\":{}}")
        #expect(hooks?.contains("'hooks'") == true)
        #expect(refusal("{\"disableAllHooks\":true}") != nil)
        // Hook and credential keys are refused even when the config lists them.
        #expect(refusal("{\"hooks\":{}}", launch(keys: ["env", "hooks"])) != nil)
        #expect(refusal("{\"apiKeyHelper\":\"x\"}", launch(keys: ["apiKeyHelper"])) != nil)
    }

    @Test func prototypeKeysAreRefusedAtAnyDepth() {
        let allowed = launch(keys: ["env", "crossSessionInbound"])
        let nested = #"{"crossSessionInbound":"accept","env":{"a":[{"__proto__":{}}]}}"#
        #expect(refusal(nested, allowed)?.contains("'__proto__'") == true)
        let deep = refusal(#"{"env":{"constructor":{}}}"#, allowed)
        #expect(deep?.contains("never allowed") == true)
        // A config that lists a key off the allowlist is refused before any key is read.
        let listed = refusal("{\"env\":{}}", launch(keys: ["env", "x"]))
        #expect(listed?.contains("settingsKeys") == true)
    }

    @Test func theDesignsExampleSettingsPassWhenTheConfigListsThem() {
        let design = launch(
            envNames: ["CLAUDE_ROLE", "CLAUDE_CLIENT"], keys: ["env", "crossSessionInbound"])
        let env = #""env":{"CLAUDE_ROLE":"worker","CLAUDE_CLIENT":"card-1"}"#
        #expect(refusal("{\"crossSessionInbound\":\"accept\",\(env)}", design) == nil)
        let object = refusal(#"{"crossSessionInbound":{"a":1}}"#, design)
        #expect(object?.contains("not a string") == true)
        // The public default lists neither, so a caller still cannot use them there.
        #expect(refusal(#"{"crossSessionInbound":"accept"}"#)?.contains("settingsKeys") == true)
        #expect(refusal(#"{"env":{"CLAUDE_ROLE":"x"}}"#)?.contains("launch.envNames") == true)
    }

    @Test func envNamesMustBeListedAndShaped() {
        #expect(refusal("{\"env\":{\"OTHER\":\"1\"}}")?.contains("launch.envNames") == true)
        #expect(refusal("{\"env\":{\"lower\":\"1\"}}", launch(envNames: ["lower"])) != nil)
        #expect(refusal("{\"env\":{\"MY_FLAG\":1}}")?.contains("not a string") == true)
        #expect(refusal("{\"env\":[]}")?.contains("not an object") == true)
    }

    @Test func protectedAndDangerousNamesAreNeverAllowedEvenWhenListed() {
        let names = [
            ProtectedEnv.tokenVariable, ProtectedEnv.configDirVariable, "ANTHROPIC_API_KEY",
            "ANTHROPIC_BASE_URL", "CLAUDE_CODE_USE_VERTEX", "AGENT_BALANCER_ACCOUNT",
            "AGENT_BALANCER_X", "PATH", "HOME", "NODE_OPTIONS", "NODE_EXTRA_CA_CERTS",
            "SSL_CERT_FILE", "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY", "ALL_PROXY",
        ]
        for name in names {
            let text = "{\"env\":{\"\(name)\":\"x\"}}"
            let message = refusal(text, launch(envNames: names))
            #expect(message?.contains("never allowed") == true, "\(name)")
        }
    }

    /// The name check refuses these even when the config list does not name them.
    @Test func everyProtectedAndLoginLocationNameIsRefusedByName() {
        let names = [
            "CLAUDE_SECURESTORAGE_CONFIG_DIR", "CLAUDE_CODE_CUSTOM_OAUTH_URL",
            "CLAUDE_CODE_SHELL_PREFIX", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_JOB_DIR", "CLAUDE_PID",
            "CLAUDE_ENV_FILE", "CLAUDE_SESSION_INGRESS_TOKEN_FILE", "CLAUDE_TRUSTED_DEVICE_TOKEN",
            "CLAUDE_BG_SESSION_CREDENTIAL", "CLAUDE_BRIDGE_OAUTH_TOKEN", "CLAUDE_RUNNER_CLAUDE_BIN",
            "CCR_OAUTH_TOKEN_FILE", "USE_LOCAL_OAUTH", "CLAUDE_LOCAL_OAUTH_APPS_BASE",
            "ANTHROPIC_PROFILE", "LD_PRELOAD", "DYLD_INSERT_LIBRARIES", "BASH_ENV",
        ]
        for name in names {
            let message = refusal("{\"env\":{\"\(name)\":\"x\"}}")
            #expect(message?.contains("'\(name)' is never allowed") == true, "\(name)")
            #expect(CallerSettings.isForbiddenEnvName(name), "\(name)")
        }
        // Names of the user's own pass the name check and need only the config's list.
        for name in ["CLAUDE_ROLE", "CLAUDE_CLIENT", "MY_FLAG"] {
            #expect(!CallerSettings.isForbiddenEnvName(name), "\(name)")
        }
    }

    /// Names that load code into the TLS library or a Java process, or write TLS keys to a file.
    static let codeLoadingNames = [
        "OPENSSL_CONF", "OPENSSL_MODULES", "OPENSSL_ENGINES", "OPENSSL_ANY_LATER_NAME",
        "SSLKEYLOGFILE", "JAVA_TOOL_OPTIONS", "JDK_JAVA_OPTIONS",
    ]

    @Test(arguments: CallerSettingsTests.codeLoadingNames)
    func aCodeLoadingNameIsRefusedAtPickTimeEvenWhenListed(name: String) {
        #expect(CallerSettings.isForbiddenEnvName(name))
        let text = "{\"env\":{\"\(name)\":\"x\"}}"
        #expect(refusal(text)?.contains("'\(name)' is never allowed") == true)
        let listed = refusal(text, launch(envNames: [name]))
        #expect(listed == "launch.envNames holds a name that is never allowed.")
    }

    /// `_JAVA_OPTIONS` already fails the name shape; the list refuses it as well.
    @Test func theJavaOptionsNameWithALeadingUnderscoreIsRefusedTwice() {
        #expect(CallerSettings.isForbiddenEnvName("_JAVA_OPTIONS"))
        #expect(refusal(#"{"env":{"_JAVA_OPTIONS":"x"}}"#)?.contains("is not valid") == true)
    }

    /// `CLAUDE_` names outside the protected group that claude uses to load code, start a
    /// program, open a path, change permissions or join another session, or could not be settled.
    static let refusedByName = [
        "CLAUDE_DEV_MODS_DIR", "CLAUDE_PROJECT_DIR", "CLAUDE_SKILL_DIR", "CLAUDE_TMPDIR",
        "CLAUDE_STAGE_FILE_ROOT", "CLAUDE_CLIENT_PRESENCE_FILE", "CLAUDE_RELAUNCH_SESSION_ADD_DIRS",
        "CLAUDE_MEMORY_STORES", "CLAUDE_ARTIFACT_HOST_GRANT", "CLAUDE_PROJECT_UUID",
        "CLAUDE_WORKFLOW_NAME_ONLY", "CLAUDE_SNIP", "CLAUDE_SERVE_DRAIN_TIMEOUT_MS",
        "CLAUDE_AGENTS_AUTO_RELAUNCHED_AT", "CLAUDE_MOD_MADE", "CLAUDE_SCRIPT_HOOK_ACK",
    ]

    /// The families, each by a name claude 2.1.332 holds or, for the options family, one shaped
    /// like those its plugins get.
    static let refusedFamilies = [
        "CLAUDE_PTY_", "CLAUDE_SSH_", "CLAUDE_PLUGIN_", "CLAUDE_REMOTE_WORKFLOW_",
        "CLAUDE_GATEWAY_",
        "CLAUDE_CHROME_", "CLAUDE_COWORK_", "CLAUDE_INTERNAL_",
    ]

    static let refusedClaudeNames =
        refusedByName + [
            "CLAUDE_PTY_HOST_EXEC", "CLAUDE_PTY_HOST_NO_STABLE_PATH", "CLAUDE_PTY_RECORD",
            "CLAUDE_SSH_LOCAL_BINARY", "CLAUDE_SSH_RUN_DIR", "CLAUDE_PLUGIN_ROOT",
            "CLAUDE_PLUGIN_DATA", "CLAUDE_PLUGIN_OPTION_TOKEN", "CLAUDE_REMOTE_WORKFLOW_SCRIPT",
            "CLAUDE_REMOTE_WORKFLOW_ARGS", "CLAUDE_GATEWAY_ALLOW_LOOPBACK",
            "CLAUDE_CHROME_PERMISSION_MODE", "CLAUDE_COWORK_MEMORY_PATH_OVERRIDE",
            "CLAUDE_INTERNAL_FC_OVERRIDES",
        ]

    @Test(arguments: CallerSettingsTests.refusedClaudeNames)
    func aClaudeNameThatLoadsCodeOrIsUnsettledIsRefusedAtPickTime(name: String) {
        #expect(CallerSettings.isForbiddenEnvName(name))
        let text = "{\"env\":{\"\(name)\":\"x\"}}"
        #expect(refusal(text)?.contains("'\(name)' is never allowed") == true)
        #expect(
            refusal(text, launch(envNames: [name]))
                == "launch.envNames holds a name that is never allowed.")
    }

    @Test func everyRefusedClaudeFamilyRefusesANameOfItsOwn() {
        #expect(ProtectedEnv.launchRefusedNames == Set(Self.refusedByName))
        #expect(ProtectedEnv.launchRefusedPrefixes == Self.refusedFamilies)
        for prefix in Self.refusedFamilies {
            #expect(prefix.hasPrefix("CLAUDE_") && prefix.hasSuffix("_"), "\(prefix)")
            #expect(CallerSettings.isForbiddenEnvName(prefix + "LATER_NAME"), "\(prefix)")
        }
    }

    /// Names of the user's own, and names claude reads for a time, a display choice, a label or a
    /// switch, still pass the name check.
    @Test func claudeNamesThatLoadNoCodeStillPass() {
        let design = launch(envNames: ["CLAUDE_ROLE", "CLAUDE_CLIENT"])
        let env = #"{"env":{"CLAUDE_ROLE":"worker","CLAUDE_CLIENT":"card-1"}}"#
        #expect(refusal(env, design) == nil)
        for name in [
            "CLAUDE_ROLE", "CLAUDE_CLIENT", "CLAUDE_CLIENT_ID", "CLAUDE_TEAM",
            "CLAUDE_AFK_TIMEOUT_MS", "CLAUDE_AX_SCREEN_READER", "CLAUDE_STREAM_IDLE_TIMEOUT_MS",
            "CLAUDE_AUTO_BACKGROUND_TASKS", "CLAUDE_BASH_MAINTAIN_PROJECT_WORKING_DIR",
            "CLAUDE_HELPER_CONTEXT", "CLAUDE_DEBUG",
        ] {
            #expect(!CallerSettings.isForbiddenEnvName(name), "\(name)")
            let text = "{\"env\":{\"\(name)\":\"x\"}}"
            #expect(refusal(text, launch(envNames: [name])) == nil, "\(name)")
        }
    }

    @Test func aRefusalNamesTheKeyAndNeverTheValue() {
        let secret = "sk-" + "ant-" + "oat01-" + String(repeating: "z", count: 40)
        let message = refusal("{\"env\":{\"MY_FLAG\":5,\"OTHER\":\"\(secret)\"}}")
        #expect(message != nil)
        #expect(message?.contains(secret) == false)
        let key = refusal("{\"\(secret)\":1}")
        #expect(key?.contains("launch.settingsKeys") == true)
    }

    @Test func theMergeKeepsTheCallersEntriesAndAddsTheLabel() throws {
        let checked = try CallerSettings.validate("{\"env\":{\"MY_FLAG\":\"1\"}}", launch: launch())
        let data = try checked.merged(extraEnv: [LaunchFiles.accountVariable: "pool-a"])
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let env = try #require(object["env"] as? [String: String])
        #expect(env == ["MY_FLAG": "1", "AGENT_BALANCER_ACCOUNT": "pool-a"])
    }
}
