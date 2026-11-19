import Core
import Foundation
import Testing

/// README.md, docs/GUIDE.md and CONTRIBUTING.md hold every point each must make, in its order;
/// the README check fails on each thing it guards and the render script publishes only its own
/// pictures; and the README pictures come from made-up accounts in states the status writer can
/// produce.
@Suite struct ReadmeTests {
    static let labels = ["main", "personal", "lab", "spare-a", "spare-b"]
    static let thinkingPage =
        "https://platform.claude.com/docs/en/build-with-claude/preserved-thinking"
    static let guide = "docs/GUIDE.md"

    static func read(_ relative: String) throws -> String {
        try String(contentsOf: Support.root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// The text under `## <title>`, up to the next heading of that level.
    static func section(_ title: String, of doc: String) throws -> String {
        let start = try #require(doc.range(of: "\n## \(title)\n"), "no section \(title)")
        let rest = doc[start.upperBound...]
        let end = rest.range(of: "\n## ")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    /// The text with every run of spaces and line breaks as one space, so a phrase matches
    /// across a wrapped line.
    static func flat(_ text: String) -> String {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" }).joined(separator: " ")
    }

    /// The first phrase that is missing or comes before the one ahead of it, or nil.
    static func outOfOrder(_ phrases: [String], in text: String) -> String? {
        var from = text.startIndex
        for phrase in phrases {
            guard let found = text.range(of: phrase, range: from..<text.endIndex) else {
                return phrase
            }
            from = found.upperBound
        }
        return nil
    }

    /// Heading anchors as GitHub makes them, with lines in fenced blocks skipped.
    static func anchors(of text: String) -> Set<String> {
        var found: Set<String> = []
        var fence = false
        for line in text.split(separator: "\n") {
            if line.drop(while: { $0 == " " }).hasPrefix("```") {
                fence.toggle()
                continue
            }
            guard !fence, line.hasPrefix("#") else { continue }
            found.insert(
                "#"
                    + line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces).lowercased()
                    .filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" }
                    .replacingOccurrences(of: " ", with: "-"))
        }
        return found
    }

    static func expectPoints(_ points: [(String, [String])], in doc: String) throws {
        for (title, phrases) in points {
            let text = flat(try section(title, of: doc))
            for phrase in phrases { #expect(text.contains(phrase), "\(title): \(phrase)") }
        }
    }

    /// Script output as a log may show it: any token shape cut short.
    static func masked(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self).replacingOccurrences(
            of: "sk-" + "ant-[A-Za-z0-9_-]*", with: "sk-ant-<cut>", options: .regularExpression)
    }

    /// A picture of a Markdown file: the scene its light file names, the element, and the first
    /// line of text after it.
    struct Picture {
        let scene: String
        let text: String
        let after: String
    }

    static func pictures(in doc: String) -> [Picture] {
        doc.matches(of: /<picture>[\s\S]*?<\/picture>/).map { match in
            let text = String(match.output)
            let scene =
                text.firstMatch(of: /src="docs\/media\/([a-z-]+)-light\.png"/).map {
                    String($0.output.1)
                } ?? ""
            let after =
                doc[match.range.upperBound...].split(separator: "\n")
                .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(String.init) ?? ""
            return Picture(scene: scene, text: text, after: after)
        }
    }

    /// One line of italic text, the way the README captions a picture.
    static func isCaption(_ line: String) -> Bool {
        line.count > 2 && line.hasPrefix("*") && line.hasSuffix("*") && !line.hasPrefix("**")
    }

    /// GitHub keeps align on a div but not style, and reads Markdown in it after a blank line.
    static func centered(_ picture: Picture) -> String {
        "<div align=\"center\">\n\(picture.text)\n\n\(picture.after)\n\n</div>\n"
    }

    // MARK: The README's order

    @Test func theReadmeFollowsThePlannedOrder() throws {
        let readme = try Self.read("README.md")
        let lines = readme.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        #expect(lines.first == "# agent-balancer")
        let pitch = lines.dropFirst().first { !$0.isEmpty } ?? ""
        #expect(pitch.hasSuffix(".") && !pitch.dropLast().contains(". "), "one sentence of pitch")

        // One picture, the menu in a healthy state, and its caption come right after the pitch.
        let afterPitch = try #require(readme.range(of: pitch)).upperBound
        let firstHeading = try #require(readme.range(of: "\n## ")).lowerBound
        let opening = String(readme[afterPitch..<firstHeading])
        let hero = Self.pictures(in: opening)
        #expect(hero.map(\.scene) == ["hero"])
        var left = opening
        for picture in hero {
            left = left.replacingOccurrences(of: Self.centered(picture), with: "")
        }
        let rest = left.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        #expect(rest.isEmpty && hero.map(\.after).allSatisfy(Self.isCaption), "\(rest)")

        let headings = lines.filter { $0.hasPrefix("## ") }.map { String($0.dropFirst(3)) }
        #expect(
            headings == [
                "How it works", "Quick start", "The app", "For scripts and orchestrators", "FAQ",
                "Details", "Contributing", "License",
            ])

        // Every picture names its light and dark file and has a one-line caption under it.
        let pictures = Self.pictures(in: readme)
        #expect(pictures.map(\.scene) == ["hero", "manage-tokens", "manage-folders", "menu"])
        let captions = [
            "hero": "*The menu with three made-up accounts.*",
            "manage-tokens":
                "*Manage accounts shows the `agent-balancer` command behind each change.*",
            "manage-folders": "*A folder account: its own folder, linked to your shared settings.*",
            "menu": "*A weekly limit and a rejected sign-in: the pick skips both.*",
        ]
        #expect(pictures.map(\.after) == pictures.map { captions[$0.scene] ?? "" })
        for picture in pictures {
            #expect(
                picture.text.contains(
                    "<source media=\"(prefers-color-scheme: dark)\" srcset=\"docs/media/\(picture.scene)-dark.png\">"
                ), "\(picture.scene)")
            #expect(picture.text.contains("src=\"docs/media/\(picture.scene)-light.png\""))
            #expect(Self.isCaption(picture.after), "\(picture.scene): \(picture.after)")
            #expect(readme.contains(Self.centered(picture)), "\(picture.scene)")
        }

        let last = lines.last { !$0.isEmpty } ?? ""
        #expect(last.hasPrefix("> agent-balancer is an independent project."))
        #expect(last.contains("no affiliation with Anthropic"))
        #expect(readme.hasSuffix(last + "\n"))
    }

    /// How it works is three bullets and nothing else.
    @Test func howItWorksIsThreeBullets() throws {
        let section = try Self.section("How it works", of: Self.read("README.md"))
        let lines = section.split(separator: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        #expect(lines.filter { $0.hasPrefix("- ") }.count == 3)
        // A nested bullet or an ordered item is a point too.
        #expect(
            lines.filter { $0.prefixMatch(of: /\s*([-*+]|[0-9]+[.)])[ ]/) != nil }.count == 3,
            "\(lines)")
        #expect(lines.allSatisfy { $0.hasPrefix("- ") || $0.hasPrefix("  ") }, "\(lines)")
    }

    /// The quick start installs from the real tap with commands that work when copied, opens the
    /// app, adds the accounts and shows what the status prints, in that order.
    @Test func theQuickStartRunsFromTheInstallToTheStatus() throws {
        let quick = try Self.section("Quick start", of: Self.read("README.md"))
        let order = [
            "macOS 14 or later on Apple silicon", "two or more Claude",
            "`AgentBalancerBar.zip`", "   brew install jakemismas/tap/agent-balancer\n",
            "   gh release download --repo jakemismas/agent-balancer --pattern AgentBalancerBar.zip\n",
            "   gh attestation verify AgentBalancerBar.zip --repo jakemismas/agent-balancer\n",
            "`AgentBalancerBar.app` to Applications", "[four steps](docs/GUIDE.md#install)",
            "`agent-balancer login <label>` opens the browser",
            "agent-balancer init --label main\n", "agent-balancer add personal\n",
            "agent-balancer login personal\n", "agent-balancer config set-main main\n",
            "agent-balancer refresh\n", "```text\n   $ agent-balancer status --cached\n",
            "next for fable: lab\n", "`agent-balancer run <label>`", "$(brew --prefix)",
            "`brew upgrade agent-balancer`", "[guide](docs/GUIDE.md)",
        ]
        let miss = Self.outOfOrder(order, in: quick)
        #expect(miss == nil, "\(miss ?? "")")
        #expect(!quick.contains("<user>") && !quick.contains("<owner>"))
    }

    /// The opening line and the FAQ name the problem in the words people use when they ask, in
    /// plain sentences: each answer is one or two sentences, and nothing is hidden in a comment.
    @Test func theOpeningAndTheFaqNameTheProblemInPlainWords() throws {
        let readme = try Self.read("README.md")
        let pitch = readme.split(separator: "\n").dropFirst().first.map(String.init) ?? ""
        let faq = try Self.section("FAQ", of: readme)
        let entries = faq.components(separatedBy: "\n\n").map(Self.flat).filter { !$0.isEmpty }
        #expect(entries.count >= 4)
        for entry in entries {
            let answer = try #require(
                entry.firstMatch(of: /^\*\*[^*]+\?\*\* (.+)$/).map { String($0.output.1) },
                "\(entry)")
            #expect(answer.hasSuffix("."), "\(entry)")
            #expect(answer.dropLast().split(separator: /[.?!]\s/).count <= 2, "\(entry)")
        }
        let words = Self.flat(pitch + " " + faq)
        for phrase in [
            "several Claude Code accounts or subscriptions", "several Claude Code subscriptions",
            "five-hour or weekly usage limits", "five-hour or weekly usage limit?",
            "switch accounts", "CLAUDE_CONFIG_DIR",
        ] {
            #expect(words.contains(phrase), "\(phrase)")
        }
        #expect(!readme.contains("<!--"))
    }

    /// The rules on where `claude` must be and the modes of the tool's files sit in Details, near
    /// the end, with the uninstall line.
    @Test func detailsSaysWhereClaudeMustBeAndTheFileModes() throws {
        let details = Self.flat(try Self.section("Details", of: Self.read("README.md")))
        let order = [
            "The tool looks for `claude` only at `~/.local/bin/claude`, `/opt/homebrew/bin/claude` and `/usr/local/bin/claude`, never at a path from its own files.",
            "If yours is elsewhere, link it into `~/.local/bin`.",
            "That file, and `~/.local/bin` if used, must be owned by you or root and not writable by group or others, access lists included.",
            "Its files are mode 0600 and its folders are mode 0700.",
            "`agent-balancer uninstall`", "drag the app to the Trash",
            "`brew uninstall agent-balancer`",
        ]
        let miss = Self.outOfOrder(order, in: details)
        #expect(miss == nil, "\(miss ?? "")")
    }

    /// Under two minutes at 238 words a minute, the published mean silent reading rate for English
    /// non-fiction (Brysbaert 2019); code blocks are left out because they are copied, not read.
    @Test func theReadmeReadsInUnderTwoMinutes() throws {
        var prose: [Substring] = []
        var fence = false
        for line in try Self.read("README.md").split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence.toggle()
                continue
            }
            if !fence { prose.append(line) }
        }
        let words = prose.joined(separator: " ").replacing(/<[^>]*>/, with: " ")
            .split(whereSeparator: \.isWhitespace)
        #expect(words.count <= 450, "\(words.count) words")
    }

    @Test func theFirstFiveMinutesFollowTheFirstRunOrder() throws {
        let steps = try Self.section("First five minutes", of: Self.read(Self.guide))
        let order = [
            "agent-balancer init --label <label>", "agent-balancer refresh",
            "agent-balancer status", "Open the app",
            "agent-balancer add <label> [--ends YYYY-MM-DD | --ending-soon]\n",
            "agent-balancer login <label>\n", "agent-balancer status",
            "agent-balancer add <label> --kind folder", "agent-balancer link <label> --dry-run\n",
            "agent-balancer link <label>\n", "agent-balancer login <label>\n",
            "agent-balancer config set-main <label>", "$(brew --prefix)",
        ]
        let miss = Self.outOfOrder(order, in: steps)
        #expect(miss == nil, "\(miss ?? "")")
        let text = Self.flat(steps)
        for phrase in [
            "An account keeps one end marker",
            "Approve the token in the browser as the account you are adding",
            "the tool does not check which account a token belongs to",
            "One account per folder, for good",
            "Saved thinking from current models works only in the account that produced it",
            "Never sign a different account into a folder that already has chats",
            "Add a new folder for the new account instead",
            "[preserved thinking](\(Self.thinkingPage))", "skills folder",
            "If `~/.claude/skills` did not exist when you ran `agent-balancer link`, run `agent-balancer link --repair <label>` for each folder account; until then `agent-balancer pick` skips it.",
        ] {
            #expect(text.contains(phrase), "\(phrase)")
        }
    }

    // MARK: Every point the plan names

    /// On macOS 14 the first open of the ad hoc signed app is four steps, with these button names.
    @Test func theInstallSectionGivesTheFourStepsThatOpenTheAdHocSignedApp() throws {
        let install = Self.flat(try Self.section("Install", of: Self.read(Self.guide)))
        let steps = [
            "[quick start](../README.md#quick-start)", "a prebuilt tool",
            "your Mac needs no developer tools",
            "The app is ad hoc signed and not notarized", "On macOS 14 that open takes four steps",
            "1. Open the app.", "shows only an OK button. Choose OK.",
            "2. Open System Settings, then Privacy & Security.", "Under Security",
            "was blocked from use, choose Open Anyway.",
            "3. Enter an administrator's password when asked, and choose Modify Settings.",
            "4. macOS asks whether you are sure you want to open it. Choose Open.",
            "Do these four steps again after each upgrade until the app is notarized.",
            "`brew upgrade agent-balancer`", "replace the app from the new zip",
        ]
        let miss = Self.outOfOrder(steps, in: install)
        #expect(miss == nil, "\(miss ?? "")")
    }

    @Test func theLimitsSectionSaysEachPoint() throws {
        let limits = try Self.section("Limits", of: Self.read(Self.guide))
        let text = Self.flat(limits)
        for phrase in [
            "The tool's checks are advisory against code that runs as you",
            "a chat that can run `agent-balancer pick`", "a file that holds a token",
            "a token session can print its own token",
            "paste deny rules like these into your own Claude Code settings",
            "The tool never writes them",
            "Treat a chat with shell access as able to use every account.",
            "A short lease on each pick counts that launch's expected use",
            "so an account near its limit is not handed out again seconds later",
        ] {
            #expect(text.contains(phrase), "\(phrase)")
        }
        // The folder names are split so the safety scan keeps them inside their modules.
        #expect(limits.contains("\"Read(~/.agent-balancer/" + "tok" + "ens/**)\""))
        #expect(limits.contains("\"Read(~/.agent-balancer/" + "lau" + "nch/**)\""))
    }

    @Test func theReadmeAndTheGuideStateEveryRequiredPoint() throws {
        let readme = try Self.read("README.md")
        let guide = try Self.read(Self.guide)
        try Self.expectPoints(
            [
                (
                    "Quick start",
                    [
                        "macOS 14 or later on Apple silicon", "Claude Code signed in",
                        "the GitHub CLI (signed in for the check)",
                        "two or more Claude accounts", "brew install jakemismas/tap/agent-balancer",
                        "gh attestation verify", "--repo jakemismas/agent-balancer",
                        "Unzip it and drag", "to Applications",
                    ]
                ),
                (
                    "For scripts and orchestrators",
                    [
                        "`agent-balancer pick --json` before each launch",
                        "[docs/ORCHESTRATORS.md](docs/ORCHESTRATORS.md)",
                        "[docs/CONTRACT.md](docs/CONTRACT.md)",
                    ]
                ),
                (
                    "Contributing",
                    [
                        "(CONTRIBUTING.md)", "(CODE_OF_CONDUCT.md)", "(SECURITY.md)",
                        "report vulnerabilities as [SECURITY.md](SECURITY.md) describes",
                    ]
                ),
            ], in: readme)
        try Self.expectPoints(
            [
                ("Install", ["Open Anyway", "after each upgrade"]),
                (
                    "How it picks",
                    [
                        "A login or folder account is in error, for example, when a sign-in check finds it signed out",
                        "or signed in as another email or on another plan than the tool expects",
                        "A token account is in error, for example, when its token file is missing or unusable",
                        "its email is a note that is never checked",
                    ]
                ),
                (
                    "How it works",
                    [
                        "Other tools also switch accounts by remaining usage",
                        "the biggest of them does it by swapping login tokens",
                        "never reads the Claude login, the Keychain or the credential files",
                        "the only credential it keeps is a setup-token that you make yourself",
                        "a reserve for a main account, a menu bar view and one launch recipe",
                        "[CONTRACT.md](CONTRACT.md)", "[ORCHESTRATORS.md](ORCHESTRATORS.md)",
                    ]
                ),
                (
                    "What it does not do",
                    [
                        "a session you start with `agent-balancer run` and `claude --version` in `agent-balancer doctor`",
                        "remove only links it made and still lists",
                    ]
                ),
                (
                    "Privacy",
                    [
                        "No telemetry.", "No network calls of its own.",
                        "never reads the Claude login, the Keychain or the credential files",
                        "It runs `claude auth status`",
                        "`agent-balancer login` can start a sign-in",
                        "The only credential it keeps is a setup-token that you make yourself.",
                        "Its files are mode 0600 and its folders are mode 0700.",
                        "With safe mode off", "your hooks run in every probe the tool starts",
                        "in `agent-balancer refresh`, in `agent-balancer pick` and in the first check that `agent-balancer login` runs after it saves a token",
                    ]
                ),
                (
                    "Where tokens live",
                    [
                        "The token lives only in", ".json` and in that label's launch files",
                        "Both are mode 0600", "excluded from backups",
                        "inside a known sync folder, such as iCloud Drive or Dropbox",
                        "A leaked token can make model requests on that subscription for up to a year",
                        "`agent-balancer login <label>` again replaces the token",
                        "No manual check has confirmed whether a new token ends the old one",
                        "or found a way to cancel one", "may keep working until its year ends",
                        "You decide whether storing a setup-token fits your Claude terms",
                        "The folder kind works without any stored token",
                    ]
                ),
                (
                    "Uninstall",
                    [
                        "Account folders and their logins stay",
                        "It removes each link it still lists in them that points where it made it point",
                        "A folder account you removed earlier is no longer listed, so its links stay",
                        "run `agent-balancer unlink <label>` before you remove a folder account",
                    ]
                ),
            ], in: guide)
        let uninstall = try Self.section("Uninstall", of: guide)
        let miss = Self.outOfOrder(
            [
                "`agent-balancer uninstall`", "Drag the app to the Trash",
                "`brew uninstall agent-balancer`",
            ], in: uninstall)
        #expect(miss == nil, "\(miss ?? "")")
    }

    /// Nothing sets the description and topics before the public flip, so the draft must stay.
    @Test func theReleasePageHoldsTheDraftDescriptionAndTopics() throws {
        let page = try Self.read("docs/RELEASING.md")
        let draft = Self.flat(try Self.section("Repository description and topics", of: page))
        for phrase in [
            "For anyone with several Claude Code accounts or subscriptions: agent-balancer reads each account's five-hour and weekly usage and picks the account for your next launch. A command line tool, a macOS menu bar app and a skill.",
            "Topics: `claude-code`, `claude`, `usage-limits`, `rate-limits`, `multiple-accounts`, `account-switcher`, `load-balancer`, `orchestration`, `macos`, `menu-bar`, `cli`, `swift`.",
        ] {
            #expect(draft.contains(phrase), "\(phrase)")
        }
    }

    /// Wordings that once said more than the code does stay out of the README and the guide.
    @Test func noReadmeClaimIsWiderThanTheCode() throws {
        for file in ["README.md", Self.guide] {
            let text = Self.flat(try Self.read(file))
            for wide in [
                "never touches", "does not change your settings files", "Only `claude` talks",
                "The only program that talks to the network", "cannot be cancelled",
                "a line that falls", "not marked ended", "with the most room",
                "build-with-claude/extended-thinking", "Saved thinking from a model",
                "signed in as the expected person on the expected plan",
                "and a session you start with `run`.", "the links it made in them go",
                "inside a synced folder", "writes no file and", "spreads close launches out",
            ] {
                #expect(text.contains(wide) == false, "\(file): \(wide)")
            }
        }
    }

    /// The only web address in the README, the guide, the orchestrator page and CONTRIBUTING.md
    /// is the preserved-thinking page, linked from the folder account rule in the guide.
    @Test func everyExternalLinkIsThePageItsSourceNames() throws {
        let address = try Regex(#"https?://[^\s)>"`]+"#)
        var links: [String] = []
        for file in ["README.md", "CONTRIBUTING.md", Self.guide, "docs/ORCHESTRATORS.md"] {
            let text = try Self.read(file)
            links += text.matches(of: address).map { "\(file) \(text[$0.range])" }
        }
        #expect(links == ["\(Self.guide) \(Self.thinkingPage)"])
    }

    /// Each local link of the five pages names a file, and a heading of it when it has an anchor.
    @Test func everyLocalLinkNamesAFileAndAHeadingThere() throws {
        var count = 0
        let pages = [
            "README.md", Self.guide, "docs/ORCHESTRATORS.md", "SECURITY.md", "CONTRIBUTING.md",
        ]
        for page in pages {
            let folder = Support.root.appendingPathComponent(page).deletingLastPathComponent()
            for link in try Self.read(page).matches(of: /\]\(([^)\s]*)\)/) {
                let target = String(link.output.1)
                if target.hasPrefix("http://") || target.hasPrefix("https://") { continue }
                count += 1
                let parts = target.split(
                    separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                let file =
                    parts[0].isEmpty
                    ? Support.root.appendingPathComponent(page)
                    : folder.appendingPathComponent(String(parts[0]))
                guard FileManager.default.fileExists(atPath: file.path) else {
                    Issue.record("\(page): \(target) names no file")
                    continue
                }
                guard parts.count == 2 else { continue }
                let text = try String(contentsOf: file, encoding: .utf8)
                #expect(Self.anchors(of: text).contains("#" + parts[1]), "\(page): \(target)")
            }
        }
        #expect(count >= 20)
    }

    @Test func contributingStatesEveryPlannedPoint() throws {
        let doc = try Self.read("CONTRIBUTING.md")
        let headings = doc.split(separator: "\n").filter { $0.hasPrefix("## ") }
            .map { String($0.dropFirst(3)) }
        #expect(
            headings == [
                "Tools", "Build and check", "Safety rules", "Issue first", "Landing", "License",
            ])
        try Self.expectPoints(
            [
                (
                    "Tools",
                    [
                        "the Swift toolchain", "swift-format", "gitleaks on your `PATH`",
                        "`brew install gitleaks`",
                        "`scripts/check.sh` must pass before you open a pull request.",
                    ]
                ),
                (
                    "Build and check",
                    [
                        "swift build -c release", "the README check",
                        "builds the app and the command line tool",
                        "copies the README pictures that run drew into `docs/media/`",
                    ]
                ),
                (
                    "Safety rules",
                    [
                        "`scripts/check-safety.sh` fails the build when a change breaks one",
                        "No network code", "No Keychain or Security framework calls",
                        "No shell execution and no child processes outside the `Runner` module",
                        "Tokens are read only by the `Tokens` and `Launch` modules",
                        "the Markdown files at the top of the repository",
                    ]
                ),
                (
                    "Issue first",
                    [
                        "Open an issue before a large change", "[docs/CONTRACT.md]",
                        "A change to that page needs the maintainer's decision",
                    ]
                ),
                (
                    "Landing",
                    [
                        "folds your pull request into one commit", "keeps you as its author",
                        "a fast-forward push to `main`", "The merge button is not used",
                    ]
                ),
                ("License", ["licensed under the MIT license"]),
            ], in: doc)
    }

    /// The process rule names exactly what the safety scan's process pattern matches.
    @Test func contributingNamesWhatTheProcessScanMatches() throws {
        let rules = Self.flat(try Self.section("Safety rules", of: Self.read("CONTRIBUTING.md")))
        let scan = try Self.read("scripts/check-safety.sh")
        let line = try #require(
            scan.split(separator: "\n").first { $0.hasPrefix("scan process '") })
        let pattern = try #require(line.split(separator: "'").dropFirst().first)
        let names = pattern.split(separator: "|").map {
            $0.replacingOccurrences(of: "\\b", with: "").replacingOccurrences(of: "\\(", with: "")
                .replacingOccurrences(of: "[a-z]*", with: "")
        }
        #expect(names.count == 7)
        for name in names { #expect(rules.contains("`\(name)`"), "\(name)") }
        #expect(rules.contains("a function whose name starts with `execv`"))
        #expect(!rules.contains("an `exec` function"))
    }

    // MARK: The README check

    @Test func eachPictureExistsAndTheCheckScriptPasses() throws {
        let fm = FileManager.default
        for picture in LeakShapes.picturePaths {
            let path = Support.root.appendingPathComponent(picture)
            let data = try #require(fm.contents(atPath: path.path), "\(picture)")
            #expect(data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
        }
        let render = try Self.read("scripts/render-views.sh")
        #expect(render.contains("docs/media"))
        let bin = try #require(Support.builtBinary())
        let temp = try Support.makeTempDir()
        defer { try? fm.removeItem(at: temp) }
        let out = try Support.run(
            Support.root.appendingPathComponent("scripts/check-readme.sh"), [bin.path],
            env: ["PATH": "/usr/bin:/bin:/opt/homebrew/bin", "TMPDIR": temp.path])
        #expect(out.status == 0, "\(Self.masked(out.stderr))")
        #expect(try fm.contentsOfDirectory(atPath: temp.path).isEmpty)
    }

    /// Copies what the README check reads, and `extra`, into `root`.
    static func copyReadmeFiles(to root: URL, extra: [String] = []) throws {
        let fm = FileManager.default
        let files =
            [
                "scripts/check-readme.sh", "README.md", "CONTRIBUTING.md", "CODE_OF_CONDUCT.md",
                "SECURITY.md", "LICENSE", "docs/CONTRACT.md", "docs/ARCHITECTURE.md", guide,
                "docs/ORCHESTRATORS.md",
            ] + LeakShapes.sceneSources + LeakShapes.picturePaths + extra
        for file in files {
            let to = root.appendingPathComponent(file)
            try fm.createDirectory(
                at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: Support.root.appendingPathComponent(file), to: to)
        }
    }

    /// Runs the README check over a copy of what it reads, after `change`. Returns its exit
    /// status, whether it left its temporary folder empty, and what it printed on stderr.
    static func checkCopy(_ change: (URL) throws -> Void) throws -> (Int32, Bool, String) {
        let fm = FileManager.default
        let root = try Support.makeTempDir()
        let temp = try Support.makeTempDir()
        defer {
            try? fm.removeItem(at: root)
            try? fm.removeItem(at: temp)
        }
        try copyReadmeFiles(to: root)
        try change(root)
        let bin = try #require(Support.builtBinary())
        let out = try Support.run(
            root.appendingPathComponent("scripts/check-readme.sh"), [bin.path],
            env: ["PATH": "/usr/bin:/bin:/opt/homebrew/bin", "TMPDIR": temp.path])
        let cleaned = try fm.contentsOfDirectory(atPath: temp.path).isEmpty
        return (out.status, cleaned, masked(out.stderr))
    }

    static func replace(_ old: String, with new: String, in file: String, under root: URL) throws {
        let url = root.appendingPathComponent(file)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains(old), "\(file): \(old)")
        try text.replacingOccurrences(of: old, with: new)
            .write(to: url, atomically: true, encoding: .utf8)
    }

    /// Adds a chunk to a picture of the copy.
    static func plant(_ type: String, _ body: [UInt8], in picture: String, under root: URL) throws {
        let url = root.appendingPathComponent(picture)
        try LeakShapes.png(Data(contentsOf: url), adding: type, body).write(to: url)
    }

    /// Writes a local banned-string list into the copy.
    static func banList(under root: URL) throws {
        let list = root.appendingPathComponent(".claude/sprint/banned-strings.txt")
        try FileManager.default.createDirectory(
            at: list.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "\nzanzibar\n".write(to: list, atomically: true, encoding: .utf8)
    }

    /// One input the README check must refuse: what changes in the copy, and words that only one
    /// guard of the script prints.
    struct GuardCase: Sendable, CustomTestStringConvertible {
        let name: String
        let key: String
        let change: @Sendable (URL) throws -> Void
        var testDescription: String { name }
    }

    static func guardCases() -> [GuardCase] {
        let readme = "README.md"
        let readmeScenes = "Sources/AgentBalancerBar/ReadmeScenes.swift"
        let manageScenes = "Sources/AgentBalancerBar/Manage/ManageScenes.swift"
        let renderScenes = "Sources/AgentBalancerBar/RenderScenes.swift"
        let picture = "docs/media/menu-light.png"
        let comment = Array("Comment".utf8) + [0]
        func edit(_ name: String, _ key: String, _ file: String, _ old: String, _ new: String)
            -> GuardCase
        {
            GuardCase(name: name, key: key) {
                try Self.replace(old, with: new, in: file, under: $0)
            }
        }
        // A fenced block put into the guide just before a heading.
        func block(_ name: String, _ key: String, _ text: String) -> GuardCase {
            edit(name, key, guide, "## How it picks", text + "\n\n## How it picks")
        }
        // Text added at the end of the README, so a fence that a broken rule leaves open takes in
        // no other line of it.
        func tail(_ name: String, _ key: String, _ text: String) -> GuardCase {
            GuardCase(name: name, key: key) {
                let url = $0.appendingPathComponent(readme)
                let old = try String(contentsOf: url, encoding: .utf8)
                try (old + "\n" + text + "\n").write(to: url, atomically: true, encoding: .utf8)
            }
        }
        // A fence left open just before a heading of the guide, and a misspelled command in a later
        // section.
        func leftOpen(_ name: String, _ key: String, _ text: String) -> GuardCase {
            GuardCase(name: name, key: key) {
                try Self.replace(
                    "## How it picks", with: text + "\n\n## How it picks", in: guide, under: $0)
                try Self.replace(
                    "`agent-balancer refresh` reads each",
                    with: "`agent-balancer refrsh` reads each", in: guide, under: $0)
            }
        }
        let span = "is not an agent-balancer command"
        let command = "is not in agent-balancer --help"
        let option = "is not an option of agent-balancer"
        let path = "metadata holds a path"
        let account = "names an account outside the fixture"
        let word = "has a word that is neither"
        return [
            edit(
                "a bare `link --repairs`", span, guide, "`agent-balancer link <label> --repair`",
                "`link --repairs`"),
            edit("a bare `eventz`", span, guide, "`agent-balancer events`", "`eventz`"),
            edit("a bare flag", span, readme, "`agent-balancer pick --json`", "`--json`"),
            edit(
                "a prompt line naming no command", command, guide,
                "agent-balancer login <label>\n   ```",
                "agent-balancer login <label>\n   $ agent-balancer frobnicate <label>\n   ```"),
            edit(
                "a renamed `events`", command, guide, "`agent-balancer events`",
                "`agent-balancer eventz`"),
            edit(
                "a renamed `unlink`", command, guide, "`agent-balancer unlink <label>` and",
                "`agent-balancer unlinks <label>` and"),
            edit(
                "a command --help does not list", command, readme, "`agent-balancer run <label>`",
                "`agent-balancer launch <label>`"),
            edit(
                "a config command --help does not list", "is not in agent-balancer config --help",
                guide, "agent-balancer config set-main <label>",
                "agent-balancer config set-mains <label>"),
            edit(
                "a flag --help does not list", option, guide, "link <label> --dry-run",
                "link <label> --dry-runs"),
            edit(
                "a renamed `--repair`", option, guide, "`agent-balancer link <label> --repair`",
                "`agent-balancer link <label> --repairs`"),
            edit(
                "a short flag --help does not list", option, readme,
                "`agent-balancer pick --json`", "`agent-balancer pick -z`"),
            edit(
                "a misspelled first flag in brackets", option, readme,
                "`agent-balancer pick --json`", "`agent-balancer pick [--jsn]`"),
            edit(
                "a flag in plain text", "is in plain text: write it in code after", guide,
                "or neither.", "or neither (see --ends)."),
            edit(
                "a command in plain text", "sits in plain text", guide, "Open the app:",
                "Run agent-balancer status, then open the app:"),
            edit(
                "a command in plain text in the README", "sits in plain text", readme,
                "Upgrade with", "Run agent-balancer refresh, then upgrade with"),
            edit(
                "a code span across a line break", "runs across a line break", readme,
                "`agent-balancer pick --json`", "`agent-balancer\n  pick --json`"),
            edit(
                "an HTML code tag", "uses an HTML code tag", guide, "Open the app:",
                "Open the app (<code>eventz</code>):"),
            block("a pre block", "uses an HTML code tag", "<pre>\nagent-balancer status\n</pre>"),
            edit(
                "a misspelled command in plain text",
                "is neither a command in code nor a listed word", guide, "Open the app:",
                "Run agent-balancer statuz, then open the app:"),
            edit(
                "a misspelled command across a line break",
                "is neither a command in code nor a listed word", guide,
                "swapping login tokens. agent-balancer never reads",
                "swapping login tokens. agent-balancer\n  eventz reads"),
            edit(
                "a misspelled command in an indented code block",
                "is neither a command in code nor a listed word", guide, "## How it picks",
                "    agent-balancer eventz\n\n## How it picks"),
            block(
                "a tab inside a command in an indented code block",
                "is neither a command in code nor a listed word",
                "Some text.\n\n    agent-balancer\teventz"),
            block(
                "a misspelled command in an sh block", command,
                "```sh\nagent-balancer frobnicate <label>\n```"),
            block(
                "a misspelled flag in a bash block", option,
                "```bash\nagent-balancer refresh --forse\n```"),
            block(
                "a prompt and a misspelled command in a console block", command,
                "```console\n$ agent-balancer eventz\n```"),
            block(
                "a misspelled command in a four-backtick fence", command,
                "````\nagent-balancer frobnicate\n````"),
            block(
                "a misspelled command in a tilde fence", command,
                "~~~\nagent-balancer frobnicate\n~~~"),
            tail(
                "a shorter marker inside a fence", command,
                "````\n```\nagent-balancer frobnicate\n````"),
            tail(
                "a tilde marker inside a backtick fence", command,
                "```\n~~~\nagent-balancer frobnicate\n```"),
            tail("a fence that never closes", "never closes", "```sh\nagent-balancer status"),
            leftOpen(
                "a misspelled command after a json fence left open in a list item", command,
                "8. Optional: paste this into your settings:\n\n   ```json\n   {}"),
            leftOpen(
                "a json fence left open after a list", "never closes", "    ```json\n    {}"),
            leftOpen(
                "an sh fence left open after a list", "never closes",
                "    ```sh\n    agent-balancer status"),
            block(
                "a bare command line in a json block", "does not parse as JSON",
                "```json\nagent-balancer frobnicate --nope\n```"),
            block(
                "a misspelled flag in a json string", option,
                "```json\n{ \"hooks\": { \"command\": \"agent-balancer pick --jsn\" } }\n```"),
            edit(
                "a command after mkdir and && in a code block", command, readme,
                "mkdir -p ~/.claude/skills && ln -s",
                "mkdir -p ~/.claude/skills && agent-balancer eventz && ln -s"),
            edit(
                "a command after && in a code span", command, readme,
                "`agent-balancer pick --json`",
                "`agent-balancer pick --json && agent-balancer eventz`"),
            edit(
                "a command after a brew line and &&", command, readme,
                "`brew upgrade agent-balancer`",
                "`brew upgrade agent-balancer && agent-balancer frobnicate`"),
            edit(
                "a command in a $(...) substitution", command, guide, "`claude auth status`",
                "`claude $(agent-balancer eventz)`"),
            block(
                "a command in a backtick substitution", command,
                "```sh\nclaude -p \"`agent-balancer eventz`\"\n```"),
            block(
                "a command after another word", command,
                "```sh\nagent-balancer status && time agent-balancer eventz\n```"),
            block(
                "a command written as a path to the tool", command,
                "```sh\nagent-balancer status && /opt/homebrew/bin/agent-balancer eventz\n```"),
            edit(
                "a flag after a choice in a usage line", option, guide,
                "[--ends YYYY-MM-DD | --ending-soon]", "[--ends YYYY-MM-DD | --ending-soonn]"),
            edit(
                "a command in parentheses", command, readme, "`agent-balancer pick --json`",
                "`agent-balancer pick --json && (agent-balancer eventz)`"),
            edit(
                "a command name in double quotes", command, readme, "`agent-balancer pick --json`",
                "`agent-balancer pick --json && \"agent-balancer\" eventz`"),
            edit(
                "a command name in single quotes", command, readme, "`agent-balancer pick --json`",
                "`agent-balancer pick --json && 'agent-balancer' eventz`"),
            edit(
                "a command name after a backslash", command, readme, "`agent-balancer pick --json`",
                "`agent-balancer pick --json && \\agent-balancer eventz`"),
            edit(
                "a no-break space inside a command", "outside printable ASCII", readme,
                "`agent-balancer pick --json`",
                "`agent-balancer pick --json && agent-balancer\u{00A0}eventz`"),
            edit(
                "a no-break space inside a command of the guide", "outside printable ASCII", guide,
                "`agent-balancer pick --json`",
                "`agent-balancer pick --json && agent-balancer\u{00A0}eventz`"),
            edit(
                "a linked file that does not exist", "' does not exist", readme,
                "(docs/CONTRACT.md)", "(docs/CONTRACTS.md)"),
            edit(
                "a linked file of the guide that does not exist", "' does not exist", guide,
                "(CONTRACT.md)", "(CONTRACTS.md)"),
            GuardCase(name: "a missing guide", key: "is missing") {
                try FileManager.default.removeItem(at: $0.appendingPathComponent(guide))
            },
            block(
                "a text block with no prompt line", "does not start with a prompt line",
                "```text\nnext: lab\n```"),
            block(
                "a text block of another command", "a command other than agent-balancer status",
                "```text\n$ agent-balancer refresh\nnext: lab\n```"),
            block(
                "a line in a text block that is not status output",
                "is not agent-balancer status output",
                "```text\n$ agent-balancer status\nnext: lab\nall good\n```"),
            block(
                "an account outside the fixture in a text block",
                "is not agent-balancer status output",
                "```text\n$ agent-balancer status\nwork [token, pool] ok week 1.0% 5h n/a resets - in use 0\n```"
            ),
            block(
                "an error line in a text block", "is not agent-balancer status output",
                "```text\n$ agent-balancer status\n  error token_missing: Run agent-balancer eventz.\n```"
            ),
            block(
                "a misspelled flag on the prompt line of a text block", option,
                "```text\n$ agent-balancer status --cashed\nnext: lab\n```"),
            block(
                "a text block of status --json", "a command other than agent-balancer status",
                "```text\n$ agent-balancer status --json\nnext: main\n```"),
            block("an empty text block", "does not start with a prompt line", "```text\n```"),
            edit(
                "a changed state in the README's status example",
                "is not agent-balancer status output", readme, "lab [token, pool] ok week",
                "lab [token, pool] fine week"),
            edit(
                "a srcset to a picture that does not exist", "' does not exist", readme,
                "srcset=\"docs/media/menu-dark.png\"", "srcset=\"docs/media/menu-drk.png\""),
            GuardCase(name: "a missing picture", key: "missing picture") {
                try FileManager.default.removeItem(
                    at: $0.appendingPathComponent("docs/media/menu-dark.png"))
            },
            GuardCase(name: "a picture that is not a PNG", key: "is not a PNG") {
                try Data("not a picture".utf8).write(
                    to: $0.appendingPathComponent("docs/media/menu-dark.png"))
            },
            GuardCase(name: "a zTXt chunk", key: "carries a compressed chunk") {
                try Self.plant("zTXt", comment + [0, 1, 2, 3], in: picture, under: $0)
            },
            GuardCase(name: "an iTXt chunk", key: "carries a compressed chunk") {
                try Self.plant(
                    "iTXt", comment + [0, 0, 0, 0] + Array("x".utf8), in: picture, under: $0)
            },
            GuardCase(name: "an iCCP chunk", key: "carries a compressed chunk") {
                try Self.plant("iCCP", comment + [0, 1, 2, 3], in: picture, under: $0)
            },
            GuardCase(name: "an iTXt chunk in the hero", key: "carries a compressed chunk") {
                try Self.plant(
                    "iTXt", comment + [0, 0, 0, 0] + Array("x".utf8),
                    in: "docs/media/hero-light.png", under: $0)
            },
            GuardCase(name: "a home path in a picture's metadata", key: path) {
                try Self.plant(
                    "tEXt", comment + Array(("/Users/" + "someone").utf8), in: picture, under: $0)
            },
            GuardCase(name: "another absolute path in a picture's metadata", key: path) {
                let text = "/Vol" + "umes/Someone/Desktop/shot.png"
                try Self.plant("tEXt", comment + Array(text.utf8), in: picture, under: $0)
            },
            GuardCase(name: "a tilde path in a picture's metadata", key: path) {
                try Self.plant(
                    "tEXt", comment + Array(("~/" + "Desktop/shot.png").utf8), in: picture,
                    under: $0)
            },
            GuardCase(name: "a path inside a file URL in a picture's metadata", key: path) {
                let text = "file://" + "/Users/" + "someone/Desktop/shot.png"
                try Self.plant("tEXt", comment + Array(text.utf8), in: picture, under: $0)
            },
            GuardCase(name: "a ~user path in a picture's metadata", key: path) {
                let text = "~some" + "one/Desktop/shot.png"
                try Self.plant("tEXt", comment + Array(text.utf8), in: picture, under: $0)
            },
            GuardCase(
                name: "a path in a URL with another scheme in a picture's metadata", key: path
            ) {
                let text = "smb://host" + "/share/some" + "one/x"
                try Self.plant("tEXt", comment + Array(text.utf8), in: picture, under: $0)
            },
            GuardCase(name: "a $HOME path in a picture's metadata", key: path) {
                let text = "$HO" + "ME/Desktop/shot.png"
                try Self.plant("tEXt", comment + Array(text.utf8), in: picture, under: $0)
            },
            GuardCase(name: "an address in a picture's metadata", key: "metadata holds an address")
            {
                let text = "someone@" + "example.org"
                try Self.plant("tEXt", comment + Array(text.utf8), in: picture, under: $0)
            },
            GuardCase(
                name: "an address with an upper-case domain in a picture's metadata",
                key: "metadata holds an address"
            ) {
                let text = "someone@" + "EXAMPLE.ORG"
                try Self.plant("tEXt", comment + Array(text.utf8), in: picture, under: $0)
            },
            GuardCase(name: "an org id in a picture's metadata", key: "metadata holds an org id") {
                let text = "org " + UUID().uuidString.lowercased()
                try Self.plant("tEXt", comment + Array(text.utf8), in: picture, under: $0)
            },
            GuardCase(name: "a token in a picture's metadata", key: "metadata holds a token") {
                let text = "sk-" + "ant-" + "oat01-" + Canary.randomTail(40)
                try Self.plant("tEXt", comment + Array(text.utf8), in: picture, under: $0)
            },
            GuardCase(
                name: "a banned string in a picture's metadata", key: "metadata holds a banned"
            ) {
                try Self.banList(under: $0)
                try Self.plant("tEXt", comment + Array("Zanzibar".utf8), in: picture, under: $0)
            },
            GuardCase(
                name: "a banned string that ends a text chunk followed by another",
                key: "metadata holds a banned"
            ) {
                try Self.banList(under: $0)
                // Each chunk goes in right after IHDR, so the one planted last comes first.
                let other = Array("Software".utf8) + [0] + Array("made up".utf8)
                try Self.plant("tEXt", other, in: picture, under: $0)
                try Self.plant(
                    "tEXt", comment + Array("made up Zanzibar".utf8), in: picture, under: $0)
            },
            edit(
                "a scene file the check does not read", "reuses a scene file", readmeScenes,
                "enum ReadmeScenes {", "enum ReadmeScenes {\n// " + "OtherScenes.x"),
            GuardCase(name: "a missing scene source", key: "missing scene source") {
                try FileManager.default.removeItem(at: $0.appendingPathComponent(renderScenes))
            },
            edit(
                "an account outside the fixture in a label field", account, renderScenes,
                "\"label\": \"spare-a\"", "\"label\": \"work\""),
            edit(
                "an account outside the fixture in a command line", account, manageScenes,
                "config set spare-b ending-soon", "config set work ending-soon"),
            edit(
                "an account outside the fixture as a typed label", account, manageScenes,
                "draft.typed = \"spare-a\"", "draft.typed = \"work\""),
            edit(
                "an account in a reason text", word, readmeScenes,
                "\"Soonest weekly reset: resets Tue 9:00 AM.\"", "\"work resets soonest.\""),
            edit(
                "an account in a warning text", word, renderScenes, "Same reset times as main.",
                "Same reset times as work."),
            edit(
                "a capitalized account in a warning text", word, renderScenes,
                "Same reset times as main.", "Same reset times as Work."),
            edit(
                "an account in a comment", word, renderScenes,
                "/// Fixed data for the render tool.",
                "/// Fixed data for the render tool, as on work."),
            edit(
                "an address outside example.com in a reused scene", "holds an address other than",
                manageScenes, "spare-b@" + "example.com\"", "spare-b@" + "example.org\""),
            edit(
                "an example.com address of no fixture label in a reused scene",
                "holds an address other than", manageScenes, "spare-b@" + "example.com\"",
                "account@" + "example.com\""),
            // One leading hyphen before a fixture label passes; nothing wider does.
            edit(
                "a fixture address with two leading hyphens in a reused scene",
                "holds an address other than", manageScenes, "\"-lab@" + "example.com\"",
                "\"--lab@" + "example.com\""),
            edit(
                "a hyphen before no fixture label in a reused scene",
                "holds an address other than", manageScenes, "\"-lab@" + "example.com\"",
                "\"-x@" + "example.com\""),
            edit(
                "a home path in the README fixture", "source holds a path outside", readmeScenes,
                "~/.agent-balancer/accounts/lab/.claude", "/Users/" + "someone/.claude"),
            edit(
                "another absolute path in a reused scene", "source holds a path outside",
                manageScenes, "\"/Users/example\"", "\"/Vol" + "umes/example\""),
            GuardCase(name: "a banned string in the README fixture", key: "source holds a banned") {
                try Self.banList(under: $0)
                try Self.replace(
                    "enum ReadmeScenes {", with: "enum ReadmeScenes {\n// Zanzibar",
                    in: readmeScenes,
                    under: $0)
            },
        ]
    }

    @Test(arguments: guardCases())
    func theCheckScriptFailsOnEachThingItGuards(guardCase: GuardCase) throws {
        let (status, cleaned, printed) = try Self.checkCopy(guardCase.change)
        #expect(status == 1, "\(printed)")
        #expect(printed.contains("FAIL readme: ") && printed.contains(guardCase.key), "\(printed)")
        #expect(cleaned, "the temporary file outlived the run")
    }

    /// Inputs the check must let through: the copy as it is, a link to a heading of a file, a
    /// picture text chunk with nothing personal in it, a command in a json string, a prompt
    /// before a command, another program's flags after each separator of a chain, and a brew
    /// line that names the formula.
    @Test func theCheckScriptPassesWhatItDoesNotGuard() throws {
        // A fenced block put into the guide just before a heading.
        func block(_ text: String) -> (URL) throws -> Void {
            {
                try Self.replace(
                    "## How it picks", with: text + "\n\n## How it picks", in: Self.guide,
                    under: $0)
            }
        }
        let chain = [
            "agent-balancer status && open -a AgentBalancerBar",
            "agent-balancer refresh || open -a AgentBalancerBar",
            "agent-balancer status; open -a AgentBalancerBar",
            "agent-balancer pick --json | jq -r .label",
            "agent-balancer refresh & open -a AgentBalancerBar",
        ]
        let passes: [(String, (URL) throws -> Void)] = [
            (
                "a command in a json string",
                block(
                    "```json\n{ \"hooks\": { \"command\": \"agent-balancer pick --json\" } }\n```")
            ),
            (
                "a prompt before a command in a code block",
                block("```console\n$ agent-balancer status\n% agent-balancer refresh\n```")
            ),
            (
                "another program's flags after each separator",
                block("```sh\n" + chain.joined(separator: "\n") + "\n```")
            ),
            (
                "a brew line that names the formula with a flag",
                {
                    try Self.replace(
                        "`brew upgrade agent-balancer`",
                        with: "`brew info agent-balancer --json=v2`", in: "README.md", under: $0)
                }
            ),
            ("the copy as it is", { _ in }),
            (
                "a fixture address with one leading hyphen",
                {
                    try Self.replace(
                        "\"spare-b@" + "example.com\"", with: "\"-spare-b@" + "example.com\"",
                        in: "Sources/AgentBalancerBar/Manage/ManageScenes.swift", under: $0)
                }
            ),
            (
                "a link to a heading",
                {
                    try Self.replace(
                        "[ARCHITECTURE.md](ARCHITECTURE.md)",
                        with: "[ARCHITECTURE.md](ARCHITECTURE.md#threat-model)", in: Self.guide,
                        under: $0)
                }
            ),
            (
                "a status transcript with a limited account",
                block(
                    "```text\n$ agent-balancer status --cached\n"
                        + "spare-a [token, pool] limited week 100.0% 5h n/a resets Thu 2:00 PM in use 0\n"
                        + "  limited (weekly) until Thu 2:00 PM\nnext: none\nnext for fable: none\n```"
                )
            ),
            (
                "a plain picture text chunk",
                {
                    try Self.plant(
                        "tEXt", Array("Software".utf8) + [0] + Array("Made up 1.0".utf8),
                        in: "docs/media/menu-light.png", under: $0)
                }
            ),
        ]
        for (what, change) in passes {
            let (status, cleaned, printed) = try Self.checkCopy(change)
            #expect(status == 0 && cleaned, "\(what): \(printed)")
        }
    }

    /// SECURITY.md says that a write cut off part way can leave a temporary copy of a token.
    @Test func securityNamesTheTemporaryCopy() throws {
        let security = Self.flat(try Self.read("SECURITY.md"))
        #expect(
            security.contains(
                "A write cut off part way can also leave a temporary copy in those folders, "
                    + "at mode 0600, until the tool deletes it"))
    }

    /// The gate and the render script both run the README check.
    @Test func theGateAndTheRenderScriptRunTheReadmeCheck() throws {
        for script in ["scripts/check.sh", "scripts/render-views.sh"] {
            let lines = try Self.read(script).split(separator: "\n").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            #expect(lines.contains { $0.hasPrefix("scripts/check-readme.sh") }, "\(script)")
        }
    }

    /// Every guard of the README check has a case above, and each case's words belong to one
    /// guard, so a new or switched-off guard fails a test.
    @Test func everyGuardOfTheCheckScriptHasACase() throws {
        let script = try Self.read("scripts/check-readme.sh")
        let guards = script.matches(of: /bad "([^"]*)"/).map { String($0.output.1) }
        #expect(guards.count >= 28)
        let keys = Set(Self.guardCases().map(\.key))
        for text in guards { #expect(keys.contains { text.contains($0) }, "no case for: \(text)") }
        for key in keys { #expect(guards.filter { $0.contains(key) }.count == 1, "\(key)") }
    }

    /// A fake `swift`: it logs its arguments, prints `FAKE_BIN` for `--show-bin-path`, and for a
    /// build of the CLI links `FAKE_CLI` into `FAKE_BIN` unless `FAKE_BUILD_NOTHING` is set.
    static let fakeSwift = """
        #!/bin/sh
        echo "$*" >> "$FAKE_LOG"
        case " $* " in *" --show-bin-path "*) echo "$FAKE_BIN"; exit 0 ;; esac
        case " $* " in *" --product agent-balancer "*)
          [ -n "${FAKE_BUILD_NOTHING:-}" ] || ln -sf "$FAKE_CLI" "$FAKE_BIN/agent-balancer" ;;
        esac
        exit 0

        """

    /// A fake app: `--render <dir>` copies `FAKE_PICTURES/<name>.png` to
    /// `<dir>/readme-<name>.png` for each name in `FAKE_RENDER`.
    static let fakeApp = """
        #!/bin/sh
        [ "$1" = --render ] || exit 1
        mkdir -p "$2"
        for name in $FAKE_RENDER; do cp "$FAKE_PICTURES/$name.png" "$2/readme-$name.png"; done

        """

    static func writeTool(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// A folder holding the fake `swift`, and the empty folder it names as the build folder.
    static func fakeTools() throws -> (tools: URL, bin: URL) {
        let tools = try Support.makeTempDir()
        let bin = tools.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try writeTool(fakeSwift, to: tools.appendingPathComponent("swift"))
        return (tools, bin)
    }

    /// With no binary given, the check builds the CLI when it is missing and never passes
    /// without it.
    @Test func theCheckScriptBuildsTheCLIWhenItIsMissing() throws {
        let fm = FileManager.default
        let cli = try #require(Support.builtBinary())
        for builds in [true, false] {
            let root = try Support.makeTempDir()
            let temp = try Support.makeTempDir()
            let (tools, bin) = try Self.fakeTools()
            defer { for dir in [root, temp, tools] { try? fm.removeItem(at: dir) } }
            try Self.copyReadmeFiles(to: root)
            let log = tools.appendingPathComponent("swift.log")
            var env = [
                "PATH": "\(tools.path):/usr/bin:/bin", "TMPDIR": temp.path, "FAKE_LOG": log.path,
                "FAKE_BIN": bin.path, "FAKE_CLI": cli.path,
            ]
            if !builds { env["FAKE_BUILD_NOTHING"] = "1" }
            let out = try Support.run(
                root.appendingPathComponent("scripts/check-readme.sh"), [], env: env)
            let printed = Self.masked(out.stderr)
            let calls = try String(contentsOf: log, encoding: .utf8)
            #expect(calls.contains("build --product agent-balancer\n"), "\(builds)")
            if builds {
                #expect(out.status == 0, "\(printed)")
            } else {
                #expect(out.status == 1 && printed.contains("check-readme: no binary at"))
            }
        }
    }

    /// The render script builds the CLI its check needs, as a fresh clone requires, and copies
    /// into docs/media/ only the pictures its own run drew: a scene that stops rendering fails
    /// the run instead of publishing a picture left from an earlier one.
    @Test func theRenderScriptBuildsTheCLIAndCopiesOnlyPicturesItsRunDrew() throws {
        let fm = FileManager.default
        let cli = try #require(Support.builtBinary())
        let names = LeakShapes.picturePaths.map {
            String($0.dropFirst("docs/media/".count).dropLast(".png".count))
        }
        let pictures = Support.root.appendingPathComponent("docs/media")
        for stale in [false, true] {
            let root = try Support.makeTempDir()
            let temp = try Support.makeTempDir()
            let (tools, bin) = try Self.fakeTools()
            defer { for dir in [root, temp, tools] { try? fm.removeItem(at: dir) } }
            try Self.copyReadmeFiles(to: root, extra: ["scripts/render-views.sh"])
            try Self.writeTool(Self.fakeApp, to: bin.appendingPathComponent("AgentBalancerBar"))
            let old = Data("old".utf8)
            for name in names {
                try old.write(to: root.appendingPathComponent("docs/media/\(name).png"))
            }
            var render = names
            if stale {
                // Renders left by an earlier run, and a run that no longer draws the menu.
                let renders = root.appendingPathComponent("build/renders")
                try fm.createDirectory(at: renders, withIntermediateDirectories: true)
                for name in names {
                    try fm.copyItem(
                        at: pictures.appendingPathComponent("\(name).png"),
                        to: renders.appendingPathComponent("readme-\(name).png"))
                }
                render = names.filter { !$0.hasPrefix("menu-") }
            }
            let log = tools.appendingPathComponent("swift.log")
            let out = try Support.run(
                root.appendingPathComponent("scripts/render-views.sh"), [],
                env: [
                    "PATH": "\(tools.path):/usr/bin:/bin", "TMPDIR": temp.path,
                    "FAKE_LOG": log.path, "FAKE_BIN": bin.path, "FAKE_CLI": cli.path,
                    "FAKE_PICTURES": pictures.path, "FAKE_RENDER": render.joined(separator: " "),
                ])
            let printed = Self.masked(out.stderr)
            let calls = try String(contentsOf: log, encoding: .utf8)
            #expect(calls.contains("build --product agent-balancer\n"), "\(stale)")
            for name in names {
                let copied = try Data(
                    contentsOf: root.appendingPathComponent("docs/media/\(name).png"))
                let drawn = try Data(contentsOf: pictures.appendingPathComponent("\(name).png"))
                #expect(copied == (stale ? old : drawn), "\(stale) \(name)")
            }
            if stale {
                #expect(out.status == 1, "\(printed)")
                #expect(printed.contains("missing build/renders/readme-menu-light.png"))
            } else {
                #expect(out.status == 0, "\(printed)")
            }
        }
    }

    // MARK: The fixture

    /// The status documents the README pictures are drawn from, by name, as written.
    static func fixture() throws -> [(name: String, text: String)] {
        let source = try read("Sources/AgentBalancerBar/ReadmeScenes.swift")
        return source.matches(of: /static let (\w+) = """\n([\s\S]*?)\n *"""/).map {
            (String($0.output.1), String($0.output.2))
        }
    }

    static func object(_ text: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    static func code(_ row: [String: Any]) -> String? {
        (row["error"] as? [String: Any])?["code"] as? String
    }

    static func used(_ row: [String: Any], _ window: String) -> Double? {
        (row[window] as? [String: Any])?["usedPercent"] as? Double
    }

    /// The names of the README documents the Manage window draws.
    static func windowDocuments() throws -> [String] {
        let source = try read("Sources/AgentBalancerBar/ReadmeScenes.swift")
        return source.matches(of: /ManageScenes\.window\([^)]*json: (\w+)\)/).map {
            String($0.output.1)
        }
    }

    /// The rules the status writer keeps for one row, as stated here for the document that the
    /// writer check does not rebuild: the menu's.
    static func expectWritable(_ row: [String: Any], generated: Date, in name: String) throws {
        let label = try #require(row["label"] as? String)
        let kind = try #require(row["kind"] as? String)
        let state = try #require(row["state"] as? String)
        let at = "\(name) \(label)"
        #expect((code(row) != nil) == (state == "error" || state == "ended"), "\(at)")

        // A limited row has a reading at or above the limit, and only a limited row has one.
        let weekly = used(row, "weekly") ?? 0
        if state == "limited" {
            let limited = try #require(row["limited"] as? [String: Any], "\(at)")
            let reset = (row["weekly"] as? [String: Any])?["resetsAt"] as? String
            #expect(limited["window"] as? String == "weekly" && weekly >= 95, "\(at)")
            #expect(limited["until"] as? String == reset, "\(at)")
        } else if state == "ok" {
            #expect(weekly < 95, "\(at)")
        }

        // A login end is warned 14 days ahead for a token account and 7 days ahead otherwise.
        let expires = (row["loginExpiresAt"] as? String).flatMap {
            ISO8601DateFormatter().date(from: $0)
        }
        let days = expires.map { $0.timeIntervalSince(generated) / 86_400 }
        let warnings = (row["warnings"] as? [[String: Any]]) ?? []
        let warned = warnings.contains { $0["code"] as? String == "login_expiring" }
        #expect(warned == (days.map { $0 <= (kind == "token" ? 14 : 7) } ?? false), "\(at)")

        switch kind {
        case "token":
            #expect(row["fullLogin"] as? Bool == false, "\(at)")
            #expect(row["planTier"] == nil && row["signInCheck"] == nil, "\(at)")
            // The estimate counts 365 days from a token saved no later than the document.
            if let days {
                #expect(row["loginExpiresSource"] as? String == "estimate" && days <= 365, "\(at)")
            }
        case "folder":
            #expect(row["fullLogin"] as? Bool == true && row.keys.contains("signInCheck"), "\(at)")
            #expect(
                row["configDir"] as? String == "~/.agent-balancer/accounts/\(label)/.claude",
                "\(at)")
            // A plan tier only from a check that placed the expected sign-in, with no doubt since.
            if row["planTier"] != nil {
                #expect(row["signInCheck"] as? String == "signed_in", "\(at)")
                let doubts = ["login_rejected", "check_failed", "wrong_account"]
                #expect(!doubts.contains(code(row) ?? ""), "\(at)")
            }
        default:
            #expect(kind == "login" && row["fullLogin"] as? Bool == true, "\(at)")
        }
    }

    @Test func theReadmePicturesShowMadeUpAccountsInStatesTheWriterCanProduce() throws {
        let docs = try Self.fixture()
        #expect(docs.map { $0.name } == ["hero", "menu", "manageTokens", "manageFolders"])
        let window = try Self.windowDocuments()
        #expect(window == ["manageTokens", "manageFolders"])
        for (name, text) in docs {
            guard case .loaded = StatusSnapshot.parse(Data(text.utf8)) else {
                #expect(Bool(false), "\(name) does not load in the app")
                continue
            }
            let doc = try Self.object(text)
            let generated = try #require(
                (doc["generatedAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) })
            let rows = try #require(doc["accounts"] as? [[String: Any]])
            let labels = name == "hero" ? Array(Self.labels.prefix(3)) : Self.labels
            #expect(rows.compactMap { $0["label"] as? String } == labels, "\(name)")
            for row in rows {
                let label = row["label"] as? String ?? ""
                #expect(row["email"] as? String == "\(label)@example.com", "\(name) \(label)")
            }
            if window.contains(name) {
                // The status writer's own build makes each row the window draws again.
                let problems = try ManageScenesWriterTests.problems(text, name: name)
                #expect(problems == [], "\(name)")
            } else {
                // A pending settings change puts settings_changed on every login and token row.
                if let banner = doc["banner"], !(banner is NSNull) {
                    for row in rows where row["kind"] as? String != "folder" {
                        #expect(Self.code(row) == "settings_changed", "\(name)")
                    }
                }
                for row in rows { try Self.expectWritable(row, generated: generated, in: name) }
            }
            let next = try #require(doc["next"] as? [String: Any])
            for key in ["all", "fable"] {
                let choice = try #require(next[key] as? [String: Any])
                guard let label = choice["label"] as? String else { continue }
                let row = try #require(rows.first { $0["label"] as? String == label })
                #expect(row["state"] as? String == "ok", "\(name) \(key)")
                #expect(Self.used(row, "weekly") != nil, "\(name) \(key)")
            }
        }

        // The first picture is healthy: no banner, three rows, each ok with no error or warning, and
        // one account in use.
        let hero = try #require(docs.first { $0.name == "hero" })
        let heroDoc = try Self.object(hero.text)
        #expect(heroDoc["banner"] is NSNull)
        let heroRows = try #require(heroDoc["accounts"] as? [[String: Any]])
        #expect(heroRows.count == 3)
        for row in heroRows {
            #expect(row["state"] as? String == "ok" && Self.code(row) == nil, "\(row)")
            #expect(((row["warnings"] as? [Any]) ?? []).isEmpty, "\(row)")
        }
        let inUse = heroRows.filter {
            (($0["inUse"] as? [String: Any])?["count"] as? Int ?? 0) > 0
        }
        #expect(inUse.count == 1)

        // The menu shows all three kinds, a limited row, an error row, a warning and the end badges.
        let menu = try #require(docs.first { $0.name == "menu" })
        let rows = try #require(try Self.object(menu.text)["accounts"] as? [[String: Any]])
        #expect(Set(rows.compactMap { $0["kind"] as? String }) == ["login", "token", "folder"])
        #expect(rows.contains { $0["state"] as? String == "limited" })
        #expect(rows.contains { $0["state"] as? String == "error" })
        #expect(rows.contains { !(($0["warnings"] as? [Any]) ?? []).isEmpty })
        #expect(rows.contains { $0["endsAt"] is String })
        #expect(rows.contains { $0["endingSoon"] as? Bool == true })
    }
}
