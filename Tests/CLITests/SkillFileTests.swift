import Foundation
import Testing

/// The skill file for a user's Claude and the public contract carry the commands and rules a
/// caller needs.
@Suite struct SkillFileTests {
    static func read(_ relative: String) throws -> String {
        try String(
            contentsOf: Support.root.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test func frontMatterHasANameAndAOneSentenceDescription() throws {
        let skill = try Self.read("skill/agent-balancer/SKILL.md")
        let lines = skill.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.first == "---")
        let end = try #require(lines.dropFirst().firstIndex(of: "---"))
        let front = lines[1..<end]
        #expect(front.contains("name: agent-balancer"))
        let description = try #require(
            front.first { $0.hasPrefix("description: ") }
        ).dropFirst("description: ".count)
        #expect(description.hasSuffix("."))
        #expect(description.dropLast().contains(". ") == false)
    }

    @Test func theSkillNamesEachCommandAndRule() throws {
        let skill = try Self.read("skill/agent-balancer/SKILL.md")
        let required = [
            "agent-balancer status --json --cached",
            "agent-balancer pick --json",
            "`env` and `args`",
            "launchPrefix",
            "launchArgs",
            "pick --settings",
            "Never pass `--settings` to `claude`",
            "Never branch on the account `kind`",
            "Never open, copy, print or keep a launch file",
            "--full-login",
            "Information is not authority",
        ]
        for phrase in required { #expect(skill.contains(phrase), "\(phrase)") }
    }

    @Test func theContractCoversBothCallersAndTheStableFields() throws {
        let contract = try Self.read("docs/CONTRACT.md")
        let required = [
            "launchPrefix", "launchArgs", "unsetEnv", "`env`", "`args`", "--exclude",
            "--full-login", "schema version 1", "events --json", "history --json",
            "Information is not authority", "`configDir` is not a contract field",
            "| 0 |", "| 2 |", "| 1 |",
        ]
        for phrase in required { #expect(contract.contains(phrase), "\(phrase)") }
    }

    @Test func neitherFileHasADashOrAnEmoji() throws {
        for file in ["skill/agent-balancer/SKILL.md", "docs/CONTRACT.md"] {
            let text = try Self.read(file)
            let bad = text.unicodeScalars.filter {
                $0.value == 0x2014 || $0.value == 0x2013 || $0.value >= 0x1F000
            }
            #expect(bad.isEmpty, "\(file)")
        }
    }
}
