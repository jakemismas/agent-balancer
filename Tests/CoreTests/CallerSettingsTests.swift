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
        #expect(refusal("{\"hooks\":{}}", launch(keys: ["env", "hooks"])) == nil)
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
