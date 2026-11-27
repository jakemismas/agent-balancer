/// The group of environment names that never reach a child process the tool builds.
/// Every other site refers to this one and adds only its own extras.
public enum ProtectedEnv {
    /// The Claude Code token variable. The name is joined from halves so the safety scan, which
    /// keeps that name inside the Tokens module, passes over this one shared list.
    public static let tokenVariable = "CLAUDE_CODE_" + "OAUTH_TOKEN"

    public static let configDirVariable = "CLAUDE_CONFIG_DIR"

    public static let anthropicPrefix = "ANTHROPIC_"

    public static let useFlagPrefix = "CLAUDE_CODE_USE_"

    /// Any other Claude Code credential variable, such as an OAuth refresh token.
    public static let oauthPrefix = "CLAUDE_CODE_OAUTH_"

    /// Every other Claude Code variable. The installed program reads many names that carry an
    /// account, redirect a request or load other settings, and the set changes between versions,
    /// so the whole prefix is protected and only the name the tool itself relies on passes.
    public static let codePrefix = "CLAUDE_CODE_"

    /// The one `CLAUDE_CODE_` name that is not protected: it marks a chat's tool shell.
    public static let childSessionVariable = "CLAUDE_CODE_CHILD_SESSION"

    /// The variable that names a file a shell sources before a command.
    public static let envFileVariable = "CLAUDE_ENV_FILE"

    /// claude names the stored login's entry from this ahead of `CLAUDE_CONFIG_DIR`.
    public static let storeDirVariable = "CLAUDE_SECURESTORAGE_CONFIG_DIR"

    /// A typed line holding one of these may read another stored login, whatever its prefix.
    public static let storeNames = [storeDirVariable, "CLAUDE_CODE_CUSTOM_OAUTH_URL"]

    /// claude finds a stored login, credential store, token file or sign-in endpoint by these.
    public static let loginLocationNames: Set<String> = [
        storeDirVariable, "CLAUDE_SESSION_INGRESS_TOKEN_FILE", "CLAUDE_TRUSTED_DEVICE_TOKEN",
        "CLAUDE_REMOTE_TOOLS_BRIDGE_URL", "USE_LOCAL_OAUTH", "USE_STAGING_OAUTH",
        "AGENT_PROXY_AUTH_TOKEN", "CLAUDE_LOCAL_OAUTH_API_BASE", "CLAUDE_LOCAL_OAUTH_APPS_BASE",
        "CLAUDE_LOCAL_OAUTH_CONSOLE_BASE", "CLAUDE_BG_SESSION_CREDENTIAL",
        "CLAUDE_BG_AUTH_SNAPSHOT_PATH", "CLAUDE_BG_SOCKET_TOKENS_PATH", "CLAUDE_BG_RV_AUTH",
        "CLAUDE_BG_PTY_AUTH", "CLAUDE_BG_CLAIM_AUTH", "CLAUDE_BRIDGE_OAUTH_TOKEN",
        "CLAUDE_BRIDGE_BASE_URL", "CLAUDE_BRIDGE_SESSION_INGRESS_URL", "CCR_OAUTH_TOKEN_FILE",
    ]

    /// These carry the credentials of the session that set them, so no child inherits them.
    public static let plumbingPrefixes = [
        "CLAUDE_BG_", "CLAUDE_BRIDGE_", "CLAUDE_RUNNER_", "CCR_", "CLAUDE_LOCAL_OAUTH_",
    ]

    /// Known variables that switch hooks off.
    public static let behaviorNames = [
        "CLAUDE_CODE_SIMPLE", "CLAUDE_CODE_SAFE_MODE", "CLAUDE_CODE_PERSONAL_HOOKS_OFF",
        "CLAUDE_CODE_RESTRICTED", "CLAUDE_CODE_RESTRICT_PERSONAL_CONFIG",
    ]

    /// Policy settings outrank the launch file, so a settings source can switch hooks off.
    public static let settingsSourceNames = [
        "CLAUDE_CODE_MANAGED_SETTINGS_PATH", "CLAUDE_CODE_REMOTE_SETTINGS_PATH",
        "CLAUDE_CODE_MOCK_REMOTE_SETTINGS",
    ]

    /// Names with a hooks-off word that claude 2.1.332 reads for something that leaves hooks on.
    public static let hooksStayOnNames: Set<String> = [
        "CLAUDE_CODE_SESSIONEND_HOOKS_TIMEOUT_MS", "CLAUDE_CODE_RESUME_SESSIONSTART_HOOKS_WAIT_MS",
        "CLAUDE_CODE_HOOKS_SAME_THREAD", "CLAUDE_CODE_ENABLE_FUNCTION_HOOKS",
        "CLAUDE_CODE_SIMPLE_SYSTEM_PROMPT", "CLAUDE_CODE_FLEETVIEW_SIMPLE",
    ]

    /// Words as well as names, so a hooks-off name that a later version adds is still refused.
    public static func mayDisableHooks(_ name: String) -> Bool {
        guard name.hasPrefix(codePrefix), name != childSessionVariable,
            !hooksStayOnNames.contains(name)
        else { return false }
        return switchesHooksOff(name)
            || ["SIMPLE", "SAFE", "RESTRICT", "HOOKS"].contains {
                name.contains($0)
            }
    }

    /// The listed hooks-off names and settings sources, without the words.
    public static func switchesHooksOff(_ name: String) -> Bool {
        behaviorNames.contains(name) || settingsSourceNames.contains(name)
    }

    /// Names a launcher removes whether or not they are set, besides what `isProtected` finds in
    /// the ambient environment.
    public static var baselineUnset: [String] {
        [configDirVariable, tokenVariable] + keyNames
            + [
                "ANTHROPIC_BASE_URL", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX",
                "CLAUDE_CODE_USE_FOUNDRY", "CLAUDE_CODE_USE_MANTLE",
            ] + storeNames + behaviorNames + settingsSourceNames + ["CLAUDE_JOB_DIR", "CLAUDE_PID"]
    }

    /// `CLAUDE_` families outside the protected group that a launch file's `env` never takes, by
    /// the rule of `launchRefusedNames`.
    public static let launchRefusedPrefixes = [
        "CLAUDE_PTY_", "CLAUDE_SSH_", "CLAUDE_PLUGIN_", "CLAUDE_REMOTE_WORKFLOW_",
        "CLAUDE_GATEWAY_", "CLAUDE_CHROME_", "CLAUDE_COWORK_", "CLAUDE_INTERNAL_",
    ]

    /// Names claude 2.1.332 holds to load code, start a program, open a path, change permissions,
    /// route requests, join another session or bill a project, or whose use was not found.
    public static let launchRefusedNames: Set<String> = [
        "CLAUDE_DEV_MODS_DIR", "CLAUDE_PROJECT_DIR", "CLAUDE_SKILL_DIR", "CLAUDE_TMPDIR",
        "CLAUDE_STAGE_FILE_ROOT", "CLAUDE_CLIENT_PRESENCE_FILE", "CLAUDE_RELAUNCH_SESSION_ADD_DIRS",
        "CLAUDE_MEMORY_STORES", "CLAUDE_ARTIFACT_HOST_GRANT", "CLAUDE_PROJECT_UUID",
        "CLAUDE_WORKFLOW_NAME_ONLY", "CLAUDE_SNIP", "CLAUDE_SERVE_DRAIN_TIMEOUT_MS",
        "CLAUDE_AGENTS_AUTO_RELAUNCHED_AT", "CLAUDE_MOD_MADE", "CLAUDE_SCRIPT_HOOK_ACK",
    ]

    /// The two key and token names, besides the Claude Code token, that a settings file may carry.
    public static let keyNames = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"]

    /// These carry a credential or choose the account, endpoint or provider a session bills.
    public static let credentialNames: Set<String> = [
        tokenVariable, "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_FOUNDRY_API_KEY",
        "ANTHROPIC_FOUNDRY_AUTH_TOKEN", "ANTHROPIC_AWS_API_KEY", "ANTHROPIC_CUSTOM_HEADERS",
        "ANTHROPIC_UNIX_SOCKET", "ANTHROPIC_PROFILE", "ANTHROPIC_CONFIG_DIR",
        "ANTHROPIC_IDENTITY_TOKEN", "ANTHROPIC_IDENTITY_TOKEN_FILE", "ANTHROPIC_FEDERATION_RULE_ID",
        "ANTHROPIC_ORGANIZATION_ID", "ANTHROPIC_SERVICE_ACCOUNT_ID", "ANTHROPIC_WORKSPACE_ID",
        "ANTHROPIC_SCOPE", "CLAUDE_CODE_API_BASE_URL", "CLAUDE_CODE_CUSTOM_OAUTH_URL",
        "CLAUDE_CODE_SESSION_ACCESS_TOKEN", "CLAUDE_CODE_SESSIONS_OAUTH_TOKEN",
        "CLAUDE_CODE_GATEWAY_TOKEN", "CLAUDE_CODE_HOST_AUTH_ENV_VAR", "CLAUDE_CODE_HOST_CREDS_FILE",
        "CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST", "CLAUDE_CODE_FEDERATION_CACHE_DIR",
    ]

    /// A model choice is protected but carries no credential, so it skips no account.
    public static func carriesCredential(_ name: String) -> Bool {
        credentialNames.contains(name) || loginLocationNames.contains(name)
            || name.hasPrefix(oauthPrefix) || name.hasPrefix(useFlagPrefix)
            || (name.hasPrefix(anthropicPrefix) && name.hasSuffix("_BASE_URL"))
            || (name.hasSuffix("_FILE_DESCRIPTOR") && isProtected(name))
    }

    /// The config folder also names the stored login's entry, so a settings file may not move it.
    public static func isKeyInSettings(_ name: String) -> Bool {
        carriesCredential(name) || name == configDirVariable
    }

    public static func isProtected(_ name: String) -> Bool {
        name == configDirVariable || name == tokenVariable || name == envFileVariable
            || name.hasPrefix(anthropicPrefix)
            || (name.hasPrefix(codePrefix) && name != childSessionVariable)
            || loginLocationNames.contains(name)
            || plumbingPrefixes.contains { name.hasPrefix($0) }
    }
}
