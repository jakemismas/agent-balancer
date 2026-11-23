import Foundation
import Testing

@testable import Core

/// docs/ORCHESTRATORS.md says only what the tool and docs/CONTRACT.md say: each command and flag
/// it names is in the tool's help, each field and exit code it lists is the contract's, its
/// example answer has the keys `pick --json` writes and a folder account's recipe, and its
/// examples are made up.
@Suite struct OrchestratorsDocTests {
    static let page = "docs/ORCHESTRATORS.md"

    /// The help of `agent-balancer <words>`.
    static func help(_ words: [String]) throws -> String {
        let bin = try #require(Support.builtBinary())
        let out = try Support.run(bin, words + ["--help"], env: ["PATH": "/usr/bin:/bin"])
        #expect(out.status == 0, "\(words)")
        return String(decoding: out.stdout, as: UTF8.self)
    }

    /// Whether the help text lists `flag` as an option.
    static func lists(_ help: String, _ flag: String) -> Bool {
        help.split(separator: "\n").contains { raw in
            var line = raw.drop { $0 == " " }
            if line.count > 4, line.first == "-", line.dropFirst(2).hasPrefix(", ") {
                line = line.dropFirst(4)
            }
            return line == flag || line.hasPrefix(flag + " ")
        }
    }

    /// The subcommands `agent-balancer --help` lists.
    static func subcommands() throws -> [String] {
        try help([]).split(separator: "\n")
            .drop { !$0.hasPrefix("SUBCOMMANDS:") }.dropFirst()
            .filter { $0.hasPrefix("  ") && !$0.hasPrefix("   ") }
            .compactMap { $0.split(separator: " ").first.map(String.init) }
    }

    /// The lines of the page outside its fenced blocks.
    static func prose(_ doc: String) -> [String] {
        var lines: [String] = []
        var fence = false
        for line in doc.split(separator: "\n") {
            if line.drop(while: { $0 == " " }).hasPrefix("```") {
                fence.toggle()
            } else if !fence {
                lines.append(String(line))
            }
        }
        return lines
    }

    /// The keys `pick --json` and `events --json` write, and the keys of a candidate.
    static func answerKeys() throws -> Set<String> {
        let pick = PickResult(
            pickedAt: Date(), model: "x", label: "lab", env: [:], args: [], launchPrefix: nil,
            launchArgs: nil, unsetEnv: [], backgroundOnly: false, reason: "",
            candidates: [CandidateResult(label: "lab", eligible: true, reason: "")], dryRun: false)
        let events = EventsAnswer(
            generatedAt: Date(), recordId: nil, cursor: 0, oldestSeq: nil, gap: false, more: false,
            events: [])
        var keys: Set<String> = []
        for data in [try PickResult.encoder().encode(pick), try JSONEncoder().encode(events)] {
            let object = try #require(
                try JSONSerialization.jsonObject(with: data) as? [String: Any])
            keys.formUnion(object.keys)
            for candidate in object["candidates"] as? [[String: Any]] ?? [] {
                keys.formUnion(candidate.keys)
            }
        }
        return keys
    }

    /// Each `agent-balancer <subcommand>` the page writes, in a code span, a code line or the
    /// sketch's argument list, is a subcommand, and each flag after it is one of its options. A
    /// flag the page names alone is an option of `pick` or `events`, the commands it explains.
    @Test func everyCommandAndFlagIsInTheToolsHelp() throws {
        let doc = try ReadmeTests.read(Self.page)
        let subcommands = try Self.subcommands()
        #expect(subcommands.contains("pick"))

        var commands: [[String]] = []
        for match in doc.matches(of: /`agent-balancer ([a-z]+)([^`]*)`/) {
            commands.append(
                [String(match.output.1)] + match.output.2.split(separator: " ").map(String.init))
        }
        // One line at a time, so a command line right below another is read too.
        for line in doc.split(separator: "\n") {
            guard let match = line.wholeMatch(of: /[ ]*agent-balancer ([a-z]+)([^`]*)/) else {
                continue
            }
            commands.append(
                [String(match.output.1)] + match.output.2.split(separator: " ").map(String.init))
        }
        for match in doc.matches(of: /\["agent-balancer", ([^\]]*)\]/) {
            let words = match.output.1.matches(of: /"([^"]*)"/).map { String($0.output.1) }
            #expect(!words.isEmpty)
            commands.append(words)
        }
        #expect(commands.count >= 8)
        for words in commands {
            let sub = words[0]
            #expect(subcommands.contains(sub), "\(sub)")
            let help = try Self.help([sub])
            for flag in words.dropFirst() where flag.hasPrefix("--") {
                #expect(Self.lists(help, flag), "\(sub) \(flag)")
            }
        }

        let explained = try Self.help(["pick"]) + Self.help(["events"])
        let alone = doc.matches(of: /`(--[a-z][a-z-]*)/).map { String($0.output.1) }
        #expect(alone.count >= 8)
        for flag in alone { #expect(Self.lists(explained, flag), "\(flag)") }

        // Every flag of every span, so one after a bare subcommand or another flag is read too.
        let contract = ReadmeTests.flat(try ReadmeTests.read("docs/CONTRACT.md"))
        var checked = 0
        for span in Self.prose(doc).joined(separator: "\n").matches(of: /`([^`]+)`/) {
            var words = span.output.1.split(whereSeparator: \.isWhitespace).map(String.init)
            if words.first == "agent-balancer" { words.removeFirst() }
            // Claude Code's flags are not in the tool's help, so its span must be the contract's.
            if words.first == "claude" {
                #expect(contract.contains("`\(words.joined(separator: " "))`"), "\(words)")
                continue
            }
            let flags = words.filter { $0.prefixMatch(of: /--[A-Za-z]/) != nil }
            guard !flags.isEmpty else { continue }
            let sub = words.first.flatMap { subcommands.contains($0) ? $0 : nil }
            let help = try sub.map { try Self.help([$0]) } ?? explained
            for flag in flags { #expect(Self.lists(help, flag), "\(span.output.1)") }
            checked += flags.count
        }
        #expect(checked >= 20)
    }

    /// No flag sits in plain text, the rule the README check keeps for the README and the guide.
    @Test func noFlagIsInPlainText() throws {
        var flags: [String] = []
        for line in Self.prose(try ReadmeTests.read(Self.page)) {
            let plain = " " + line.replacing(/`[^`]*`/, with: " ")
            flags += plain.matches(of: /[^A-Za-z0-9-](--[A-Za-z][A-Za-z0-9-]*)/).map {
                String($0.output.1)
            }
        }
        #expect(flags.isEmpty, "\(flags)")
    }

    /// A name alone in code is a contract field, a subcommand, a config key or a listed word.
    @Test func everyNameInCodeIsAFieldACommandOrAKey() throws {
        let contract = try ReadmeTests.read("docs/CONTRACT.md")
        let named = Set(
            contract.matches(of: /`([A-Za-z][A-Za-z0-9.]*)`/).map { String($0.output.1) })
        let fields = try Self.answerKeys().intersection(named)
        // Like a field, a variable the source defines counts only where the contract names it.
        let variables = Set(Recipe.unsetNames).union(ProtectedEnv.credentialNames)
            .union(ProtectedEnv.loginLocationNames)
            .intersection(contract.matches(of: /`([A-Z][A-Z0-9_]*)`/).map { String($0.output.1) })
        let subcommands = Set(try Self.subcommands())
        let config = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(Config()))
                as? [String: Any])
        var keys: Set<String> = []
        for (section, value) in config {
            guard let settings = value as? [String: Any] else { continue }
            for key in settings.keys { keys.insert(section + "." + key) }
        }
        #expect(keys.contains("picker.leaseMinutes"))
        let words: Set = ["claude", "typed", "fable", "lab"]
        var names: [String] = []
        for line in Self.prose(try ReadmeTests.read(Self.page)) {
            // With `_` and `-`, so a snake-case or dashed slip of a field is read too.
            names += line.matches(of: /`([A-Za-z][A-Za-z0-9._-]*)`/).map { String($0.output.1) }
        }
        #expect(names.count >= 20)
        for name in names {
            let known =
                fields.contains(name) || subcommands.contains(name) || keys.contains(name)
                || words.contains(name) || variables.contains(name)
            #expect(known, "\(name)")
        }
    }

    /// The page's exit codes are the contract's, with the same meanings.
    @Test func theExitCodesAreTheContracts() throws {
        func codes(_ text: String) -> [String: String] {
            Dictionary(
                text.matches(of: /\n\| ([0-9]) \| ([^|]+) \|/).map {
                    (String($0.output.1), $0.output.2.trimmingCharacters(in: .whitespaces))
                }, uniquingKeysWith: { first, _ in first })
        }
        let page = codes(try ReadmeTests.read(Self.page))
        #expect(Set(page.keys) == ["0", "1", "2"])
        #expect(page == codes(try ReadmeTests.read("docs/CONTRACT.md")))
    }

    /// Each exit code the text names, as in "exit 1" or "Exit 2", is one of the contract's.
    @Test func everyExitTheTextNamesIsTheContracts() throws {
        let contract = try ReadmeTests.read("docs/CONTRACT.md")
        let codes = Set(contract.matches(of: /\n\| ([0-9]+) \|/).map { String($0.output.1) })
        #expect(codes == ["0", "1", "2"])
        let named = try ReadmeTests.read(Self.page).matches(of: /\b[Ee]xit ([0-9]+)\b/).map {
            String($0.output.1)
        }
        #expect(named.count >= 7)
        for code in named { #expect(codes.contains(code), "exit \(code)") }
    }

    /// A caller trusts the version the text names, so it must be the one `pick --json` writes.
    @Test func everySchemaVersionTheTextNamesIsTheEncoders() throws {
        let prose = Self.prose(try ReadmeTests.read(Self.page)).joined(separator: "\n")
        let named = prose.matches(of: /\b[Ss]chema\s+version\s+([0-9]+)/).map {
            String($0.output.1)
        }
        #expect(named.count >= 2)
        for version in named {
            #expect(version == "\(PickResult.currentSchema)", "schema version \(version)")
        }
    }

    /// The page keeps its launch, no-free-account and skill sections and its exit sentences.
    @Test func thePageStatesEveryRequiredPoint() throws {
        try ReadmeTests.expectPoints(
            [
                (
                    "Read the exit code",
                    [
                        "Treat any other exit code as a failed call, like exit 1.",
                        "At exit 0 and 2 the answer is JSON on standard output; at exit 1 the error text is on standard error.",
                        "| 0 | A recipe | Launch with it |",
                        "| 2 | Nothing fits | Do not launch. Leave the work waiting, show `reason` and pick again later |",
                        "| 1 | No pick: a refused flag, refused settings, a busy lock or another error | Report the error text. No lease was written, and a launch file stays only when the error names it: never use that file; the commands the error names are for a person in their own terminal |",
                    ]
                ),
                (
                    "Read the answer",
                    [
                        "the environment of `claude`. Null at exit 2 and with `--dry-run`",
                        "always `--settings` and a path. Null at exit 2 and with `--dry-run`",
                        "A list under `--caller launcher`; null at exit 2 and with `--dry-run`",
                        "| `label` | The chosen account, or null when nothing fits |",
                        "| `reason` | Why, in every answer. Show it; do not parse it |",
                        "| `env` | Names and values to add to the environment of `claude`. Null at exit 2 and with `--dry-run` |",
                        "| `args` | Arguments to put after your own flags: always `--settings` and a path. Null at exit 2 and with `--dry-run` |",
                        "| `unsetEnv` | Names to remove from the environment of `claude`: a fixed list plus each protected name your own environment holds, less any name `env` sets. A list under `--caller launcher`; null at exit 2 and with `--dry-run` |",
                        "| `candidates` | One entry per account, with `label` and `eligible`, and a `reason` to show |",
                    ]
                ),
                (
                    "Launch Claude Code",
                    [
                        "Start `claude` with your own environment, minus every name in `unsetEnv`, plus every entry of `env`, and with `args` after your own flags, as an argument array.",
                        "Never paste any of it into a shell string, and never branch on the account kind: the recipe is the same for every account.",
                        "Launch within the lease window, `picker.leaseMinutes` (10 minutes by default).",
                        "Never reuse a recipe; pick again for the next launch.",
                        "After each launch, check that it landed, as [CONTRACT.md](CONTRACT.md#check-the-launch) says: if its session is missing, stop launching onto that account and report it.",
                    ]
                ),
                (
                    "When no account is free",
                    [
                        "Exit 2 means no account fits right now, and each entry of `candidates` says why.",
                        "Do not launch, and do not choose a label yourself",
                        "pick again with `--exclude` and that worker's label.",
                    ]
                ),
                (
                    "Install the skill",
                    [
                        "the tool never writes inside `~/.claude`",
                        "run `agent-balancer link --repair <label>` for each folder account; until then `pick` skips it.",
                    ]
                ),
            ], in: ReadmeTests.read(Self.page))
    }

    /// The fields the page lists are stable fields of the contract, and its example answer has
    /// the keys `pick --json` writes, the keys of each candidate, and a folder account's recipe
    /// under `--caller launcher`: the folder in `env`, the names a launcher removes, which leave
    /// out the folder variable that `env` sets, and a launch file.
    @Test func theFieldsAndTheExampleAnswerAreTheContracts() throws {
        let section = try ReadmeTests.section("Read the answer", of: ReadmeTests.read(Self.page))
        let contract = try ReadmeTests.read("docs/CONTRACT.md")
        let stable = Set(
            contract.matches(of: /\n\| `([A-Za-z]+)` \|\s/).map { String($0.output.1) })
        let listed = section.matches(of: /\n\| `([A-Za-z]+)` \|\s/).map { String($0.output.1) }
        #expect(listed.count >= 7)
        for field in listed { #expect(stable.contains(field), "\(field)") }

        let block = try #require(section.firstMatch(of: /```json\n([\s\S]*?)\n```/))
        let answer = try #require(
            try JSONSerialization.jsonObject(with: Data(block.output.1.utf8)) as? [String: Any])
        let sample = PickResult(
            pickedAt: Date(), model: "x", label: "lab", env: [:], args: [], launchPrefix: nil,
            launchArgs: nil, unsetEnv: [], backgroundOnly: false, reason: "",
            candidates: [CandidateResult(label: "lab", eligible: true, reason: "")], dryRun: false)
        let written = try #require(
            try JSONSerialization.jsonObject(with: PickResult.encoder().encode(sample))
                as? [String: Any])
        #expect(Set(answer.keys) == Set(written.keys))
        let candidates = try #require(answer["candidates"] as? [[String: Any]])
        for candidate in candidates {
            #expect(Set(candidate.keys) == ["label", "eligible", "reason"])
        }
        #expect(answer["schemaVersion"] as? Int == PickResult.currentSchema)

        let label = try #require(answer["label"] as? String)
        let env = try #require(answer["env"] as? [String: String])
        #expect(Array(env.keys) == [ProtectedEnv.configDirVariable])
        #expect(answer["unsetEnv"] as? [String] == Recipe.unsetNames(env: env))
        #expect(answer["launchPrefix"] is NSNull && answer["launchArgs"] is NSNull)
        let args = try #require(answer["args"] as? [String])
        #expect(args.count == 2 && args.first == "--settings")
        let file = URL(fileURLWithPath: args[1])
        #expect(LaunchFiles.isFileName(file.lastPathComponent))
        #expect(file.deletingLastPathComponent().path.hasSuffix("/\(LaunchFiles.folder)/\(label)"))
    }

    /// A launcher acts on these rows, so each must say what the contract's row says.
    @Test func eachFieldAndExitRowSaysWhatTheContractsRowSays() throws {
        func rows(_ text: String) -> [String: String] {
            var found: [String: String] = [:]
            for line in text.split(separator: "\n") {
                if let row = line.wholeMatch(of: /\| (`[A-Za-z]+`|[0-9]+) \| (.*) \|/) {
                    found[String(row.output.1)] = String(row.output.2)
                }
            }
            return found
        }
        let doc = try ReadmeTests.read(Self.page)
        let page = rows(
            try ReadmeTests.section("Read the exit code", of: doc)
                + ReadmeTests.section("Read the answer", of: doc))
        let contract = rows(try ReadmeTests.read("docs/CONTRACT.md"))
        let version = "`\(PickResult.currentSchema)`"
        // The contract's words, then the page's; a launcher applies a recipe by launching with it.
        let same = { (words: String) in (words, words) }
        let meaning: [String: [(String, String)]] = [
            "0": [("Apply it", "Launch with it")],
            "1": [
                same("Report the error text. No lease was written"),
                same(
                    "a launch file stays only when the error names it: never use that file; the commands the error names are for a person in their own terminal"
                ),
            ],
            "2": [
                same("Do not launch."), ("Leave the item waiting", "Leave the work waiting"),
                same("show `reason`"),
            ],
            "`schemaVersion`": [same(version)],
            "`label`": [same("The chosen account"), same("null when nothing fits")],
            "`reason`": [
                ("In every answer", "in every answer"),
                ("The text is informational", "do not parse it"),
            ],
            "`env`": [
                ("object of strings", "Names and values"), ("Exit 2: null", "Null at exit 2"),
            ],
            "`args`": [
                same("always `--settings` and a path"), ("Exit 2: null", "Null at exit 2"),
            ],
            "`unsetEnv`": [same("A list under `--caller launcher`")],
            "`candidates`": [
                ("Each entry has", "One entry per account, with"), same("`label` and `eligible`"),
                same("`reason`"),
            ],
        ]
        #expect(Set(page.keys) == Set(meaning.keys))
        for (key, pairs) in meaning {
            let theirs = contract[key] ?? ""
            let ours = page[key] ?? ""
            for (said, written) in pairs {
                #expect(theirs.contains(said), "CONTRACT.md \(key): \(said)")
                #expect(ours.contains(written), "\(key): \(written)")
            }
            #expect(ours.contains("Do not launch") == theirs.contains("Do not launch"), "\(key)")
        }
        #expect(page["`schemaVersion`"] == version)
    }

    /// Each local link of the page names a file, and a heading there when it names one. The
    /// examples use the made-up home only, and the page is printable ASCII.
    @Test func theLinksResolveAndTheExamplesAreMadeUp() throws {
        let doc = try ReadmeTests.read(Self.page)
        let links = doc.matches(of: /\]\(([^)#]+)(#[^)]+)?\)/)
        #expect(links.count >= 3)
        for link in links {
            let target = Support.root.appendingPathComponent("docs/" + link.output.1)
            let text = try String(contentsOf: target, encoding: .utf8)
            guard let anchor = link.output.2 else { continue }
            #expect(
                ReadmeTests.anchors(of: text).contains(String(anchor)),
                "\(link.output.1)\(anchor)")
        }
        for home in doc.matches(of: /\/Users\/([^\/\s"]+)/) {
            #expect(home.output.1 == "example")
        }
        #expect(
            doc.unicodeScalars.allSatisfy { $0.value == 0x0A || (0x20...0x7E).contains($0.value) })
    }
}
