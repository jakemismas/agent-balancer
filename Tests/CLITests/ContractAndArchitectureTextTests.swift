import Foundation
import Testing

@testable import Core

/// Sentences of docs/CONTRACT.md and docs/ARCHITECTURE.md that state what the code does: which
/// commands probe, what the status document's `next` sets aside, and what `uninstall` says about
/// an access list.
@Suite struct ContractAndArchitectureTextTests {
    /// A doc with the line breaks and indents of its wrapped paragraphs collapsed to single
    /// spaces.
    static func prose(_ relative: String) throws -> String {
        try String(contentsOf: Support.root.appendingPathComponent(relative), encoding: .utf8)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The part of the architecture doc from `start` up to the next heading at `level` or above.
    static func section(_ start: String, level: String) throws -> String {
        let doc = try String(
            contentsOf: Support.root.appendingPathComponent("docs/ARCHITECTURE.md"),
            encoding: .utf8)
        let from = try #require(doc.range(of: "\n" + start + "\n"))
        let rest = doc[from.upperBound...]
        let end = rest.range(of: "\n" + level + " ")?.lowerBound ?? rest.endIndex
        return rest[..<end].split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    @Test func theContractNamesEveryCommandThatProbes() throws {
        let contract = try Self.prose("docs/CONTRACT.md")
        #expect(contract.contains("Only `refresh`, `pick` and a token account's `login` probe."))
        #expect(!contract.contains("Only `refresh` and `pick` probe."))
        let callers = try Self.section("## 16. The contract callers use", level: "##")
        #expect(callers.contains("(only `refresh`, `pick` and a token account's `login` probe)"))
        #expect(!callers.contains("(only `refresh` and `pick` probe)"))
    }

    @Test func sectionTenOneSaysNextSetsAsideLeasesAndTheAgeRuleAndKeepsTheProbeSourceRule()
        throws
    {
        let status = try Self.section("### 10.1 `agent-balancer status --json`", level: "###")
        #expect(
            status.contains(
                "computed with the picker rules but without leases and without the age rule of `picker.maxReadingAgeMinutes`, the main account's included,"
            ))
        #expect(
            status.contains(
                "The main account's probe-source rule stays: a main account whose reading is not a probe reading is not picked for `next`."
            ))
        #expect(!status.contains("without the main account's probe-source and age rules"))
    }

    @Test func theUninstallSectionSaysAnAccessListCanStopAStep() throws {
        let uninstall = try Self.section("## 12. Install, update, uninstall", level: "##")
        let tokens = TokenPaths.folderName
        let launch = LaunchFiles.folder
        for phrase in [
            "how many entries in `\(launch)/` where a label's folder belongs `lstat` cannot check, such as a label's folder whose access list denies its owner",
            "says to run `chmod -h -N` on each entry there, or `chmod -N` where that says Permission denied, then run `agent-balancer uninstall` again.",
            "Such an entry may be a link with an access list of its own, and `-h` makes `chmod` act on the link itself, not on the folder it points to.",
            "`chmod -h -N` opens the entry, so it says Permission denied where the access list also denies its owner `read` (`list` on a folder); plain `chmod -N` does not open the entry and clears that list.",
            "an entry `lstat` cannot check, or a folder wider than 0700 or one the user cannot open or search, such as one at 0600 or one whose access list denies its owner `list` or `search`)",
            "`chmod 700` on a folder wider than 0700, `chmod -N` and then `chmod 700` on one that cannot be opened or searched, or, on an entry `lstat` cannot check, such as one whose access list denies its owner `readattr`, `chmod -h -N`, or `chmod -N` if that says Permission denied, and then `chmod -h 700`.",
            "`chmod -N` removes an access list, which `chmod 700` leaves in place.",
            "A folder wider than 0700 or one that cannot be opened or searched is one `lstat` showed as a real folder, never a link, so its commands need no `-h`, and plain `chmod -N` clears its list without opening it.",
            "An entry `lstat` cannot check may be a link, so `-h` makes each command act on the link itself; `-N` comes first because `chmod -h 700` fails as long as `lstat` cannot check the entry, and `chmod -h -N` opens the entry, so where the access list also denies its owner `read` it says Permission denied and plain `chmod -N` clears the list.",
            "Neither clears the access list of a link whose own list denies its owner `read`: `chmod -h -N` cannot open it, and `chmod -N` acts on what it points to, so the rerun stops again. Only a `chmod -h +a` on the link itself makes such a link, since a new link takes no entry from its folder.",
            "A data folder in a home the user cannot search cannot be checked either, and no command on the data folder reaches it until the home can be searched again.",
            "When one does, or a launch file cannot be overwritten with a tombstone, `uninstall` stops with exit 1 and deletes no token file and nothing after it, and its text says, on each label's folder in `\(launch)/` that is not a link, to run `chmod -h -N` and `chmod -h 700`, and `chmod -h -N` on each file directly in it, or `chmod -N` where that says Permission denied, with `chflags -h nouchg` first on any of them that is locked.",
            "That clears a folder that is not writable, a lock, and an access list that denies the owner, set on a file or a folder or inherited from the folder, so a rerun gets past this step;",
            "a temporary file that a failed tombstone write could not delete is counted in step 3 with its own text,",
            "a label's folder that cannot be searched is refused on the rerun with its own text, as above.",
            "Those label folders passed the folder checks, so `chmod -h -N` opens them, and a link where a label's folder belongs is counted on its own, so no command the text names acts on the folder a link points to or on the files in it.",
            "A launch file's name that `lstat` cannot check, such as a file whose access list denies its owner `readattr` or one in a label's folder that stopped being searchable after the check, counts as one that does.",
            "A link, a file, another user's folder or an entry `lstat` cannot check where a label's folder belongs, and a folder named like a label only in other letter case, are never followed or opened:",
            "A token file that cannot be deleted, such as in a `\(tokens)/` folder that is not writable or whose access list denies its owner `delete_child`, or one that is locked, still holds its token,",
            "a token file's name that `lstat` cannot check, such as a file whose access list denies its owner `readattr`, may hold one",
            "the closing text says to run `chmod -h -N` and `chmod -h 700` on `\(tokens)/`, and `chmod -h -N` on each token file in it, or `chmod -N` where that says Permission denied, with `chflags -h nouchg` first on any of them that is locked,",
            "such as in a folder whose access list denies its owner `delete_child`, or `lstat` cannot check it, such as one whose access list denies its owner `readattr`, it is counted on its own,",
            "the closing text says, on each folder that holds one, `\(tokens)/` or a label's folder in `\(launch)/` that is not a link, to run `chmod -h -N` and `chmod -h 700`, and `chmod -h -N` on each temporary file in it, or `chmod -N` where that says Permission denied, with `chflags -h nouchg` first on any of them that is locked,",
            "or a link, a file, another user's folder or an entry `lstat` cannot check where a label's folder belongs in `\(launch)/`), after the closing text says so.",
            "It never follows a link, opens a file, enters another user's folder or opens an entry `lstat` cannot check where a label's folder belongs in `\(launch)/`,",
        ] {
            #expect(uninstall.contains(phrase), "\(phrase)")
        }
        for phrase in [
            "such as in a label's folder that stopped being searchable",
            "and `chmod -N` on it when it has an access list",
            "deletes no token file and nothing after it, so a rerun can finish.",
            "that has an access list",
            "so a rerun can finish",
            "or `chmod -h -N` and then `chmod -h 700` on one that cannot be opened or searched",
            "writable and to run `chmod -h -N` on",
            "such as a file whose access list denies its owner or",
            "such as a file whose access list denies its owner,",
            "such as one whose access list denies its owner,",
        ] {
            #expect(!uninstall.contains(phrase), "\(phrase)")
        }
    }

    @Test func theArchitectureSaysWhatARefreshOrALoginWhoseRebuildDidNotSaveLeaves() throws {
        let sections: [(start: String, level: String, phrases: [String])] = [
            (
                "## 4. Architecture and module map", "##",
                [
                    "One probe clears it whatever the times: the first check of a token that `login` saves, when it works and the rebuild that records it saves `state/current.json` (4A.5)."
                ]
            ),
            (
                "### 4A.4 The token kind", "###",
                [
                    "When the first check works, it also ends a probe's rejection recorded before that check, whatever the reading times, once the status rebuild that records the check saves `state/current.json` (4A.5)."
                ]
            ),
            (
                "### 4A.5 Checks per kind at pick time (fail closed)", "###",
                [
                    "the rejection was recorded before that check, of the token it replaced or of the new token by a probe that ran between the save and the check, and `login` holds the label's probe lock from that check until the rebuild has run, so no later probe's rejection is ended by it.",
                    "a `login` with a new token whose first check works brings the account back at once, once that rebuild saves `state/current.json`. When that rebuild is skipped at its 30 second wait for the history lock, saves no `state/current.json` or fails, `login`, still holding the probe lock, keeps the check in `state/token-checks.json` and then deletes the label's record from `state/token-rejections.json` (section 13), so every record left there postdates the check; the next rebuild that reads the kept check and saves `state/current.json` ends the rejection that file held from before the check, as the check's own rebuild would have (a rebuild that read the token records before the check leaves it to the next one), and until then a rejection dated ahead of the clock keeps the token out of `pick` and `run`. A rejection that a probe records after the check still stands: that rebuild ends the earlier one before it folds its own probes, and keeps a record written after the check. When `login` cannot keep the check either (as while another command holds `locks/token-records.lock` for 30 seconds), or a rebuild that folds the kept check is ended between clearing it and saving `state/current.json` (section 13), nothing stored marks the check, so a rejection dated ahead of the clock stands until another such `login`, or a stored reading newer than the rejection once the clock passes its time; one dated at or before the clock ends at the next rebuild, which sees the check's newer stored reading.",
                ]
            ),
            (
                "### 6.1 Sources, cheapest first", "###",
                [
                    "a negative or non-number value, minus infinity included, in any window with a valid name, is `check_failed`, and a number too large to read leaves its line unread, 6.2)"
                ]
            ),
            (
                "### 6.2 The probe", "###",
                [
                    "Everything else is discarded unread, a line that does not parse as JSON included, such as one with a number too large to read."
                ]
            ),
            (
                "### 6.3 Cache and age", "###",
                [
                    "A `refresh` holds a label's probe lock from a registry check it makes once it has the lock until it has saved its reading and run the status rebuild that records it (6.4)"
                ]
            ),
            (
                "### 6.4 Refresh cadence and daily cost", "###",
                [
                    "and once more at its end with the sign-in checks and each result whose own rebuild did not finish with `state/current.json` saved (section 13), so a refresh that the menu ends after its 300 second timeout keeps what its finished probes found, unless such a rebuild was skipped at its 30 second wait for the history lock, saved no `state/current.json` or failed, or the menu ended the refresh after a probe finished but before that probe's own rebuild did. A token account's rejection it keeps in those cases too: as the probe answers, before that rebuild, `refresh` writes the rejection to `state/token-rejections.json` (section 13), dated as the rebuild would date it, and the terminate signal the menu sends waits until that write is done, then ends the process.",
                    "The menu's end stops the process, so the last rebuild does not run, and those results are lost from the status: a reading that a working probe stored shows at the next rebuild, a token account's rejection still keeps the token out, since `refresh` wrote it apart from `state/current.json`, and any other error is lost until the account's next probe.",
                    "A failed plain probe leaves the reading as old as it was, so the next refresh probes the account again; a Fable probe whose own rebuild had not finished is not counted as tried (6.3), nor is one whose rejection its own rebuild did not save in `state/current.json`, so the next refresh runs it again, while any other whose own rebuild was skipped or saved no `state/current.json` was counted and runs again once a day has passed. Until then `pick` and `run` judge the account as they did before that probe, except that a token account's kept rejection keeps the token out.",
                ]
            ),
            (
                "## 11. Menu bar", "##",
                [
                    "or, for a token account, until `login` saves a new token whose first check works and the rebuild that records that check, or a later one that reads it as kept, saves `state/current.json` (4A.5), or until `login` completes a new sign-in"
                ]
            ),
        ]
        for item in sections {
            let text = try Self.section(item.start, level: item.level)
            for phrase in item.phrases {
                #expect(text.contains(phrase), "\(item.start): \(phrase)")
            }
        }
        let tokenRow = try Self.section(
            "### 4A.5 Checks per kind at pick time (fail closed)", level: "###")
        #expect(!tokenRow.contains("the rejection was of the token it replaced, and"))
        let refresh = try Self.section("### 6.4 Refresh cadence and daily cost", level: "###")
        #expect(!refresh.contains("unless such a rebuild could not save that file."))
    }

    @Test func theDocsStateTheRuleForAModelThePickCannotPlace() throws {
        let contract = try Self.prose("docs/CONTRACT.md")
        #expect(contract.contains("so `pick` skips every account set to refuse Fable launches"))
        let rules = try Self.section("### 7.2 Rules, in order", level: "###")
        #expect(rules.contains("Model unknown, so Fable room not checked."))
        let pick = try Self.section("### 10.2 `agent-balancer pick --json`", level: "###")
        #expect(!pick.contains("(treated as all-models only)"))
    }

    @Test func theDuplicateRowStatesTheRuleTheToolApplies() throws {
        let errors = try Self.section("## 9. Errors and states", level: "##")
        #expect(
            errors.contains("and whose 5-hour reset time does too when both have one still ahead"))
        #expect(!errors.contains("weekly and 5-hour reset times both equal"))
        let token = try Self.section("### 4A.4 The token kind", level: "###")
        #expect(token.contains("when both accounts have one still ahead"))
    }

    @Test func theFableAgeCountsFromTheLastProbeThatShowedTheStoredUse() throws {
        let budgets = try Self.section(
            "### 7.4 Two budgets per account: the Fable reading and its fallback", level: "###")
        #expect(
            budgets.contains(
                "Both count from the last Fable probe whose reply showed the stored use: a reply with a higher use, or with the same use in the same window"
            ))
        let cache = try Self.section("### 6.3 Cache and age", level: "###")
        #expect(
            cache.contains(
                "The Fable reading also takes the `readAt` of a reply that shows its stored use in the same window"
            ))
    }

    @Test func ruleSevenSaysThePickDecidesOnTheRegistryAsSavedUnderTheLock() throws {
        let rules = try Self.section("### 7.2 Rules, in order", level: "###")
        #expect(
            rules.contains(
                "Once it holds the lock, `pick` reads the registry again and decides on it as saved then, not as it read it before its probes"
            ))
        #expect(
            rules.contains("An account added meanwhile is neither probed nor judged in that pick"))
    }

    @Test func theDriftChecksListALinkWhoseDefaultFolderItemMoved() throws {
        let drift = try Self.section("### 5.7 Drift checks that fail closed", level: "###")
        #expect(
            drift.contains(
                "1. every link is still a symlink to the recorded target, and the default folder's item, while it exists, still resolves to that target;"
            ))
        #expect(
            drift.contains(
                "Check 1 resolves the default folder's item of each listed link, following its links as `link` does, by path and metadata only, and opens no shared file."
            ))
    }

    @Test func theDriftChecksNameADefaultFolderItemThatNoLongerResolvesOrCannotBeChecked() throws {
        let drift = try Self.section("### 5.7 Drift checks that fail closed", level: "###")
        #expect(
            drift.contains(
                "the account fails with \"The default folder's <name> no longer resolves. Fix it there first, then run `agent-balancer link --repair <label>` in Terminal.\""
            ))
        #expect(
            drift.contains(
                "the account fails with \"The default folder's <name> cannot be checked, so the tool cannot tell where it resolves.\""
            ))
    }

    @Test func ruleSevenSaysAPickWithNoRegistrySavedUnderTheLockDecidesNothing() throws {
        let rules = try Self.section("### 7.2 Rules, in order", level: "###")
        #expect(
            rules.contains(
                "With no registry saved by then, as after an `uninstall` that ran meanwhile, `pick` decides nothing: it exits 1"
            ))
    }

    @Test func theContractsUninstallExitStatusNamesAnEntryItCannotCheck() throws {
        let contract = try Self.prose("docs/CONTRACT.md")
        #expect(
            contract.contains(
                "or leaves unopened an entry that may hold one: one named like a token file or a launch folder in other letter case, or a link, a file, another user's folder or an entry it cannot check where a label's launch folder belongs."
            ))
    }

    /// The file layout of section 4: the fenced block under its heading.
    static func layout() throws -> String {
        let doc = try String(
            contentsOf: Support.root.appendingPathComponent("docs/ARCHITECTURE.md"),
            encoding: .utf8)
        let heading = try #require(doc.range(of: "\n## 4. Architecture and module map\n"))
        let open = try #require(doc.range(of: "\n```\n", range: heading.upperBound..<doc.endIndex))
        let close = try #require(doc.range(of: "\n```\n", range: open.upperBound..<doc.endIndex))
        return String(doc[open.upperBound..<close.lowerBound])
    }

    /// The row of the layout that starts with `path`, its wrapped lines joined by single spaces.
    static func layoutRow(_ path: String) throws -> String {
        let lines = try layout().split(separator: "\n").map(String.init)
        let first = try #require(lines.firstIndex { $0.hasPrefix("  \(path) ") }, "\(path)")
        let rest = lines[(first + 1)...].prefix { $0.hasPrefix("   ") }
        return ([lines[first]] + rest).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The layout names every script under scripts/, and each release script has a row that
    /// says what it does.
    @Test func theLayoutNamesEveryScript() throws {
        let layout = try Self.layout()
        let scripts = try FileManager.default.contentsOfDirectory(
            atPath: Support.root.appendingPathComponent("scripts").path)
        #expect(scripts.count >= 9)
        for name in scripts.sorted() {
            #expect(layout.contains("scripts/\(name)"), "\(name)")
        }
        for (script, says) in [
            ("scripts/check-release.sh", "the release check:"),
            ("scripts/release-version.sh", "the release version rules"),
            ("scripts/release-notes.sh", "prints the release notes of a version"),
        ] {
            let row = try Self.layoutRow(script)
            #expect(row.contains(says), "\(script): \(row)")
        }
    }
}
