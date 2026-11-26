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
        let names =
            ProtectedEnv.behaviorNames + ProtectedEnv.settingsSourceNames + [
                "CLAUDE_CODE_NEW_HOOKS_X"
            ]
        for name in names {
            do {
                try PickService.checkHooksOff(PickService.AmbientState([name: "/x", "TERM": "x"]))
                Issue.record("\(name) was not refused")
            } catch let error as ToolError {
                #expect(error.message.hasPrefix("\(name) is set in this shell"), "\(name)")
                #expect(!error.message.contains("/x"), "\(name)")
            } catch {
                Issue.record("unexpected error for \(name)")
            }
        }
        // The first such name in sorted order is the one the refusal names.
        let two = PickService.AmbientState([
            "CLAUDE_CODE_SIMPLE": "1", "CLAUDE_CODE_SAFE_MODE": "1",
        ])
        #expect(two.hooksOffName == "CLAUDE_CODE_SAFE_MODE")
        for name in ChildEnvironmentTests.namesThatLeaveHooksOn + ["TERM"] {
            #expect(throws: Never.self) {
                try PickService.checkHooksOff(PickService.AmbientState([name: "1"]))
            }
        }
    }

    /// Both typed strings take only paths that pass the folder pattern of section 5.2.
    @Test func launchArgsTakesOnlyAPathThatPassesTheFolderPattern() throws {
        let base = "/opt/ab-home"
        let context = ToolContext(home: URL(fileURLWithPath: base), ambient: [:])
        let good = try LaunchFiles.fileURL(context: context, label: "main", leaseId: "l-0123abcd")
            .path
        #expect(good.hasPrefix(base + "/"))
        #expect(try Recipe.launchArgs(settingsPath: good) == "--settings '\(good)'")
        let tail = String(good.dropFirst(base.count))
        for home in [
            "/opt/ab home", "/opt/x$(id)", "/opt/caf\u{E9}", "/opt/it's", "/opt/a\\b", "/opt/a\tb",
            "/opt/./x", "opt/relative",
        ] {
            #expect(!FolderPaths.isValidPath(home + tail), "\(home)")
            #expect(throws: ToolError.self, "\(home)") {
                try Recipe.launchArgs(settingsPath: home + tail)
            }
            #expect(throws: ToolError.self, "\(home)") {
                try Recipe.launchPrefix(configDir: home + "/.agent-balancer/accounts/x/.claude")
            }
        }
    }
}
