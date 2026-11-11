import Foundation
import Testing

@testable import Core

@Suite struct ReadingConfigTests {
    @Test func missingSectionsDecodeToTheDefaults() throws {
        let config = try JSONDecoder().decode(Config.self, from: Data("{\"schemaVersion\":1}".utf8))
        #expect(config.fable == FableSettings())
        #expect(config.fable.capPercentOfWeekly == 50)
        #expect(config.fable.probe == true)
        #expect(config.fable.probeBudgetUsd == 0.50)
        #expect(config.fable.probeTimeoutSeconds == 20)
        #expect(config.fable.minRoomPercentOfCap == 10)
        #expect(config.fable.recheckAfterWeeklyRisePercent == 5)
        #expect(config.picker.maxReadingAgeMinutes == 15)
    }

    @Test func aPartialSectionKeepsTheOtherDefaults() throws {
        let text = "{\"schemaVersion\":1,\"fable\":{\"probe\":false},\"picker\":{}}"
        let config = try JSONDecoder().decode(Config.self, from: Data(text.utf8))
        #expect(config.fable.probe == false)
        #expect(config.fable.probeTimeoutSeconds == 20)
        #expect(config.picker.maxReadingAgeMinutes == 15)
    }

    @Test func newKeysSurviveASaveAndUnknownOnesAreKept() throws {
        let t = try TestHome()
        let store = ConfigStore(context: t.context)
        var config = Config()
        config.fable.probeBudgetUsd = 0.75
        config.picker.maxReadingAgeMinutes = 30
        try store.save(config)
        let url = t.context.dataRoot.appendingPathComponent("config.json")
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var fable = try #require(object["fable"] as? [String: Any])
        #expect(fable["probeBudgetUsd"] as? Double == 0.75)
        let picker = try #require(object["picker"] as? [String: Any])
        #expect(picker["maxReadingAgeMinutes"] as? Int == 30)
        fable["futureKey"] = 1
        object["fable"] = fable
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        let loaded = try #require(try store.load())
        try store.save(loaded)
        let again = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect((again["fable"] as? [String: Any])?["futureKey"] as? Int == 1)
        #expect(try store.load()?.fable.probeBudgetUsd == 0.75)
    }

    @Test func theValidatorRefusesOutOfRangeValues() {
        func message(_ edit: (inout Config) -> Void) -> String? {
            var c = Config()
            edit(&c)
            do {
                try ConfigValidator.validate(c)
                return nil
            } catch let e as ToolError { return e.message } catch { return "other" }
        }
        #expect(message { $0.fable.capPercentOfWeekly = 0 }?.contains("capPercentOfWeekly") == true)
        #expect(message { $0.fable.probeBudgetUsd = 0 }?.contains("probeBudgetUsd") == true)
        #expect(
            message { $0.fable.probeTimeoutSeconds = 0 }?.contains("probeTimeoutSeconds") == true)
        #expect(
            message { $0.fable.minRoomPercentOfCap = 101 }?.contains("minRoomPercentOfCap") == true)
        #expect(
            message { $0.fable.recheckAfterWeeklyRisePercent = -1 }?
                .contains("recheckAfterWeeklyRisePercent") == true)
        #expect(
            message { $0.picker.maxReadingAgeMinutes = 0 }?.contains("maxReadingAgeMinutes") == true
        )
        #expect(message { _ in } == nil)
    }
}
