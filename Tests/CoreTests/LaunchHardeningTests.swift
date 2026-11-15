import Foundation
import Testing

@testable import Core

@Suite struct LaunchHardeningTests {
    @Test func aPersonLaunchDropsJobProcessAndClaudeCodeNames() throws {
        let t = try TestHome()
        let context = t.context(ambient: [
            "CLAUDE_JOB_DIR": "/x", "CLAUDE_PID": "1", "CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR": "3",
            "CLAUDE_CODE_CHILD_SESSION": "1", "TERM": "xterm",
        ])
        let env = ChildEnvironment.person(context: context, configDir: nil)
        #expect(env["CLAUDE_JOB_DIR"] == nil)
        #expect(env["CLAUDE_PID"] == nil)
        #expect(env["CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR"] == nil)
        #expect(env["TERM"] == "xterm")
    }

    @Test func aLauncherUnsetsJobAndProcessNames() {
        let names = Recipe.unsetNames(env: [:], ambient: ["CLAUDE_CODE_FD": "3"])
        #expect(names.contains("CLAUDE_JOB_DIR") && names.contains("CLAUDE_PID"))
        #expect(names.contains("CLAUDE_CODE_FD"))
    }

    @Test func aLauncherAlwaysUnsetsTheStoredLoginNamesAndEveryLoginLocationItHolds() {
        let held = [
            "CLAUDE_BRIDGE_OAUTH_TOKEN", "USE_STAGING_OAUTH", "CCR_OAUTH_TOKEN_FILE",
            "CLAUDE_BG_SESSION_CREDENTIAL", "CLAUDE_TRUSTED_DEVICE_TOKEN",
        ]
        var ambient = Dictionary(uniqueKeysWithValues: held.map { ($0, "x") })
        ambient["CLAUDE_ROLE"] = "worker"
        let names = Recipe.unsetNames(env: [:], ambient: ambient)
        for name in ProtectedEnv.storeNames + ProtectedEnv.settingsSourceNames + held {
            #expect(names.contains(name), "\(name)")
        }
        #expect(!names.contains("CLAUDE_ROLE"))
        for name in ProtectedEnv.storeNames + ProtectedEnv.settingsSourceNames {
            #expect(Recipe.unsetNames.contains(name), "\(name)")
        }
    }

    @Test func aStoredLoginNameRefusesATypedLineAndAConfigFolderDoesNot() {
        for name in ProtectedEnv.storeNames {
            #expect(throws: ToolError.self) {
                try PickService.checkStoredLogin(PickService.AmbientState([name: ""]))
            }
        }
        #expect(throws: Never.self) {
            try PickService.checkStoredLogin(
                PickService.AmbientState([ProtectedEnv.configDirVariable: "/x", "TERM": "x"]))
        }
    }

    @Test func aHooksOffNameRefusesATypedLine() {
        #expect(throws: ToolError.self) {
            try PickService.checkHooksOff(PickService.AmbientState(["CLAUDE_CODE_SIMPLE": "1"]))
        }
        for name in ProtectedEnv.settingsSourceNames {
            #expect(throws: ToolError.self) {
                try PickService.checkHooksOff(PickService.AmbientState([name: "/x"]))
            }
        }
        #expect(throws: Never.self) {
            try PickService.checkHooksOff(PickService.AmbientState(["TERM": "x"]))
        }
    }
}
