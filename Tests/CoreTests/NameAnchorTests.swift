import Foundation
import Testing

@testable import Core

/// Every name check anchors its pattern at both ends, so a name that ends in a line break never
/// passes as the name before it.
@Suite struct NameAnchorTests {
    static let endings = ["\n", "\r", "\r\n"]

    let readAt = Date(timeIntervalSince1970: 1_800_000_000)

    func json(_ object: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    /// `text` as written and as a JSON parse hands it over, backed by an `NSString`, since the
    /// regular expression search of the two forms differs on some systems.
    func forms(_ text: String) throws -> [String] {
        let data = try JSONSerialization.data(withJSONObject: [text: 1])
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return [text, try #require(object.keys.first)]
    }

    @Test(arguments: NameAnchorTests.endings)
    func aCallerEnvNameWithALineBreakFails(ending: String) throws {
        for base in ["PATH", "SSL_CERT_FILE", "HTTPS_PROXY", "MY_FLAG"] {
            let name = base + ending
            // A list that skipped the config check, so only the shape check stands in the way.
            let launch = LaunchSettings(settingsKeys: ["env"], envNames: [name])
            do {
                _ = try CallerSettings.validate(try json(["env": [name: "x"]]), launch: launch)
                Issue.record("\(base) with a line break passed")
            } catch let error as ToolError {
                #expect(error.message.contains("is not valid"), "\(base)")
            }
        }
    }

    @Test(arguments: NameAnchorTests.endings)
    func aListedEnvNameOrSettingsKeyWithALineBreakFailsAtLoad(ending: String) throws {
        func message(_ tune: (inout Config) -> Void) -> String? {
            var config = Config(accounts: [])
            tune(&config)
            do {
                try ConfigValidator.validate(config)
                return nil
            } catch let error as ToolError { return error.message } catch { return "other" }
        }
        #expect(message { $0.launch.envNames = ["CLAUDE_ROLE"] } == nil)
        for name in try forms("CLAUDE_ROLE" + ending) {
            #expect(
                message { $0.launch.envNames = [name] }
                    == "launch.envNames holds a name that is not valid.")
        }
        for key in try forms("env" + ending) {
            #expect(
                message { $0.launch.settingsKeys = [key] }
                    == "launch.settingsKeys holds a name that is not valid.")
        }
    }

    @Test(arguments: NameAnchorTests.endings)
    func aSettingsEnvNameWithALineBreakIsNoName(ending: String) throws {
        for base in ["CLAUDE_CODE_OAUTH_REFRESH_TOKEN", "ANTHROPIC_API_KEY", "CLAUDE_CODE_SIMPLE"] {
            let facts = try HookRecord.parse(Data(try json(["env": [base + ending: "v"]]).utf8))
            #expect(facts.keyEnvNames.isEmpty && facts.hooksOffEnvNames.isEmpty, "\(base)")
            let plain = try HookRecord.parse(Data(try json(["env": [base: "v"]]).utf8))
            #expect(plain.keyEnvNames.count + plain.hooksOffEnvNames.count == 1, "\(base)")
        }
    }

    @Test(arguments: NameAnchorTests.endings)
    func anInheritedNameWithALineBreakIsNotHandedToALauncher(ending: String) throws {
        for name in try forms("CLAUDE_CODE_NEW_Y" + ending) {
            let names = Recipe.unsetNames(env: [:], ambient: ["CLAUDE_CODE_NEW_X": "1", name: "1"])
            #expect(names.contains("CLAUDE_CODE_NEW_X"))
            #expect(!names.contains { $0.hasPrefix("CLAUDE_CODE_NEW_Y") })
        }
    }

    @Test(arguments: NameAnchorTests.endings)
    func aModelNameWithALineBreakFails(ending: String) throws {
        #expect(PickModel.isValidName("sonnet[1m]"))
        let t = try TestHome()
        try ConfigStore(context: t.context).save(Config(accounts: []))
        let service = PickService(context: t.context)
        for model in try forms("sonnet" + ending) {
            #expect(!PickModel.isValidName(model))
            do {
                _ = try service.pick(PickRequest(model: model))
                Issue.record("a model name with a line break passed")
            } catch let error as ToolError {
                #expect(error.message == "--model is not a valid model name.")
            }
        }
    }

    @Test(arguments: NameAnchorTests.endings)
    func anEventTypeWithALineBreakFails(ending: String) throws {
        let t = try TestHome()
        let log = EventLog(context: t.context)
        _ = try log.answer(EventsQuery(type: "limited"))
        for type in try forms("limited" + ending) {
            do {
                _ = try log.answer(EventsQuery(type: type))
                Issue.record("a type with a line break passed")
            } catch let error as ToolError {
                #expect(error.message == "--type must be an event type such as limited.")
            }
        }
    }

    /// One reply with a weekly window and one more entry under `name`.
    func reply(_ name: String, _ entry: [String: Any]) throws -> String {
        let weekly: [String: Any] = ["utilization": 0.1, "resetsAt": 1_800_086_400]
        return try json([
            "type": "rate_limit_event",
            "rate_limit_info": ["unifiedWindows": ["seven_day": weekly, name: entry]],
        ])
    }

    @Test(arguments: NameAnchorTests.endings)
    func aProbeWindowNameWithALineBreakIsNotKept(ending: String) throws {
        let entry: [String: Any] = ["utilization": 0.2, "resetsAt": 1_800_003_600]
        let text = try reply(WindowName.fiveHour + ending, entry)
        guard case .reading(let r) = ProbeReader.parse(text, readAt: readAt) else {
            Issue.record("expected a reading")
            return
        }
        #expect(Set(r.windows.keys) == [WindowName.sevenDay])
    }

    static let otherShapes = [
        "five_hour\n", "seven_day\r", "Monthly Extra", "someone@example.com",
        String(repeating: "w", count: 41),
    ]

    @Test(arguments: NameAnchorTests.otherShapes)
    func aBadUsageUnderAWindowNameOfAnotherShapeFailsTheReply(name: String) throws {
        let values: [Any] = [-0.5, "0.5", NSNull(), true]
        for value in values {
            let text = try reply(name, ["utilization": value])
            guard case .failed(let issue) = ProbeReader.parse(text, readAt: readAt) else {
                Issue.record("a bad usage under an odd name passed: \(value)")
                continue
            }
            #expect(issue.code == .checkFailed)
            #expect(issue.text == ProbeReader.badUsage)
        }
    }

    @Test(arguments: NameAnchorTests.otherShapes)
    func aGoodUsageUnderAWindowNameOfAnotherShapeIsDroppedAndTheReplyParses(name: String) throws {
        let text = try reply(name, ["utilization": 0.5, "resetsAt": 1_800_003_600])
        guard case .reading(let r) = ProbeReader.parse(text, readAt: readAt) else {
            Issue.record("a reply with an odd window name did not parse")
            return
        }
        #expect(Set(r.windows.keys) == [WindowName.sevenDay])
    }
}
