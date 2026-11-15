import Core
import Foundation
import Testing

@testable import Core

/// Every row of the Manage render scenes is one the status writer can produce: each status
/// document in the scene source goes through the status decoder, then the writer's own build
/// (what `StatusBuilder.rebuild` runs on the files it reads) makes each row again from a config,
/// the sign-in check and probe the row records and the reading it shows, so every rule a row
/// follows is the writer's. The README test runs the same check on the README documents the
/// Manage window draws.
@Suite struct ManageScenesWriterTests {
    static let source = "Sources/AgentBalancerBar/Manage/ManageScenes.swift"
    static let readmeSource = "Sources/AgentBalancerBar/ReadmeScenes.swift"

    /// The status documents of a scene source, by name, as written.
    static func documents(in path: String = source) throws -> [(name: String, text: String)] {
        let text = try String(
            contentsOf: Support.root.appendingPathComponent(path), encoding: .utf8)
        return text.matches(of: /static let (\w+) = """\n([\s\S]*?)\n *"""/).map {
            (String($0.output.1), String($0.output.2))
        }
    }

    static let labels = ["main", "personal", "lab", "spare-a", "spare-b"]

    /// A time as the status document writes it.
    static func date(_ text: String?) -> Date? {
        text.flatMap { ISO8601DateFormatter().date(from: $0) }
    }

    /// The home the scenes show folders under.
    static let home = ToolContext(home: URL(fileURLWithPath: "/Users/example"), ambient: [:])

    /// What a status rebuild reads for one account.
    struct Inputs {
        var account: Account
        var check: AuthObservation?
        var probe: ProbeObservation?
        var token: TokenInfo?
        var folder: FolderInfo?
        var endedByPlan: Bool
        var reading: Reading?
    }

    /// The reading a row shows: its weekly and five-hour use and a probed Fable meter, read
    /// `readingsAge` seconds before the document. Nil when the row shows no use.
    static func reading(_ row: [String: Any], generated: Date) -> Reading? {
        let readAt = generated.addingTimeInterval(-Double(row["readingsAge"] as? Int ?? 0))
        func window(_ key: String) -> WindowReading? {
            guard let shown = row[key] as? [String: Any],
                let used = shown["usedPercent"] as? Double
            else { return nil }
            return WindowReading(
                usedPercent: used, resetsAt: date(shown["resetsAt"] as? String), readAt: readAt)
        }
        var windows: [String: WindowReading] = [:]
        windows[WindowName.sevenDay] = window("weekly")
        windows[WindowName.fiveHour] = window("fiveHour")
        var fable: FableReading?
        if let meter = row["fable"] as? [String: Any],
            meter["source"] as? String == ReadingSource.probe
        {
            fable = FableReading(
                source: ReadingSource.probe, usedPercent: meter["usedPercent"] as? Double,
                resetsAt: date(meter["resetsAt"] as? String), readAt: readAt)
        }
        guard !windows.isEmpty || fable != nil else { return nil }
        let source = (row["weekly"] as? [String: Any])?["source"] as? String
        return Reading(
            source: source ?? ReadingSource.probe, readAt: readAt, windows: windows, fable: fable)
    }

    /// What a sign-in check can find: the sign-in in place, signed out, another account, a
    /// sign-in it could not confirm, and another plan.
    static let checks: [(signedIn: Bool, code: StateCode?)] = [
        (true, nil), (false, .loginRejected), (true, .wrongAccount), (true, .checkFailed),
        (true, .planChanged),
    ]
    /// The codes a probe records. The writer adds the other codes by rules of its own.
    static let probeCodes: [StateCode] = [.loginRejected, .checkFailed]

    /// Every set of inputs a row could come from. A row names its account and its code; whether
    /// the code came from a check or a probe, a token's file, a folder's links, and an end by
    /// plan it does not say, so each is tried every way.
    static func candidates(_ row: [String: Any], generated: Date) throws -> [Inputs] {
        let label = row["label"] as? String ?? ""
        let kind = row["kind"] as? String ?? ""
        let error = row["error"] as? [String: Any]
        let code = error?["code"] as? String
        let text = error?["text"] as? String ?? ""
        let tier = row["planTier"] as? String
        let expires = date(row["loginExpiresAt"] as? String)
        var account = Account(
            label: label, kind: kind, role: row["role"] as? String ?? "",
            email: row["email"] as? String, endsAt: row["endsAt"] as? String,
            endingSoon: row["endingSoon"] as? Bool == true ? true : nil)
        if kind == Kind.token, let expires {
            account.tokenCreatedAt = ISO8601DateFormatter().string(
                from: expires.addingTimeInterval(-Transitions.tokenLifeDays * 86_400))
        }
        func observation(_ check: (signedIn: Bool, code: StateCode?)) -> AuthObservation {
            AuthObservation(
                error: check.code.map { Issue($0, .error, $0.rawValue == code ? text : "Hidden.") },
                planTier: tier, loginExpiresAt: kind == Kind.token ? nil : expires,
                signedIn: check.signedIn)
        }
        // A folder row names what its last check saw; a login row's check is not shown.
        var checks: [AuthObservation?] = [nil]
        if kind == Kind.folder, let seen = row["signInCheck"] as? String {
            checks = Self.checks.map(observation).filter { $0.seen?.rawValue == seen }.map {
                Optional($0)
            }
        } else if kind == Kind.login {
            checks += Self.checks.map { Optional(observation($0)) }
        }
        var probes: [ProbeObservation?] = [nil]
        if let code = code.flatMap(StateCode.init(rawValue:)), probeCodes.contains(code) {
            probes.append(ProbeObservation(error: Issue(code, .error, text)))
        }
        // A token file that is there always has a change time, from which an end is estimated.
        let tokens: [TokenInfo?] =
            kind == Kind.token
            ? [
                TokenInfo(usable: true, modified: generated),
                TokenInfo(usable: false, modified: nil),
            ]
            : [nil]
        var folders: [FolderInfo?] = [nil]
        if kind == Kind.folder {
            let display = home.display(try FolderPaths.configDir(context: home, label: label))
            let verdicts: [FolderVerdict] =
                row["linked"] as? Bool == true ? [.ok] : [.notLinked, .broken("")]
            folders = verdicts.flatMap { verdict in
                [true, false].map {
                    FolderInfo(
                        facts: FolderFacts(verdict: verdict, sharesSettings: $0), display: display)
                }
            }
        }
        let ends = account.endingSoon == true ? [false, true] : [false]
        let read = reading(row, generated: generated)
        var all: [Inputs] = []
        for check in checks {
            for probe in probes {
                for token in tokens {
                    for folder in folders {
                        for end in ends {
                            all.append(
                                Inputs(
                                    account: account, check: check, probe: probe, token: token,
                                    folder: folder, endedByPlan: end, reading: read))
                        }
                    }
                }
            }
        }
        return all
    }

    /// What the writer builds from these inputs at `now`, with `issue` in the settings memory.
    static func build(_ all: [Inputs], issue: String?, now: Date) -> StatusDocument {
        var previous = CurrentFile()
        for inputs in all where inputs.endedByPlan {
            var entry = CurrentEntry(
                accountKey: inputs.account.accountKey, state: "ended", code: "account_ended",
                since: now, endedByPlan: true)
            entry.emailDigest = inputs.account.emailDigest
            previous.accounts[inputs.account.label] = entry
        }
        var observations = StatusObservations(
            settings: SettingsObservation(issue: issue, carriesKey: false))
        var tokens: [String: TokenInfo] = [:]
        var folders: [String: FolderInfo] = [:]
        var readings: [String: Reading] = [:]
        for inputs in all {
            let label = inputs.account.label
            observations.auth[label] = inputs.check
            observations.probe[label] = inputs.probe
            tokens[label] = inputs.token
            folders[label] = inputs.folder
            readings[label] = inputs.reading
        }
        return StatusBuilder.build(
            config: Config(accounts: all.map(\.account)), readings: readings, previous: previous,
            observations: observations, sessions: .empty, tokens: tokens,
            launchExists: { _ in true }, now: now, folders: folders
        ).document
    }

    /// A field as text: null when missing, an issue as its code and text.
    static func shown(_ object: [String: Any]?, _ key: String) -> String {
        guard let value = object?[key], !(value is NSNull) else { return "null" }
        if let issue = value as? [String: Any] {
            return "\(issue["code"] as? String ?? "") \(issue["text"] as? String ?? "")"
        }
        return "\(value)"
    }

    /// A since time as the check reads it. A rebuild that keeps a state keeps the time it began,
    /// so any time up to the document's reads alike.
    static func since(_ value: Any?, generated: Date) -> String {
        guard let value, !(value is NSNull) else { return "null" }
        guard let at = date(value as? String), at <= generated else { return "\(value)" }
        return "up to \(ISO8601DateFormatter().string(from: generated))"
    }

    /// Where the row and the writer's row differ, as "<field> <writer's> / <row's>".
    static func differences(_ row: [String: Any], _ document: StatusDocument) throws -> [String] {
        guard let built = document.accounts.first,
            let made = try JSONSerialization.jsonObject(
                with: StatusDocument.encoder().encode(built)) as? [String: Any]
        else { return ["the writer made no row"] }
        var differ: [String] = []
        func compare(_ field: String, _ writer: String, _ scene: String) {
            if writer != scene { differ.append("\(field) \(writer) / \(scene)") }
        }
        var keys = [
            "state", "error", "planTier", "linked", "endsAt", "loginExpiresAt",
            "loginExpiresSource",
        ]
        // A scene leaves `fullLogin` and `configDir` out at times.
        keys += ["fullLogin", "configDir"].filter { row[$0] != nil }
        for key in keys { compare(key, shown(made, key), shown(row, key)) }
        compare(
            "endingSoon", "\(made["endingSoon"] as? Bool ?? false)",
            "\(row["endingSoon"] as? Bool ?? false)")
        // Only a folder row carries `signInCheck`, null before the first check.
        func check(_ object: [String: Any]) -> String {
            object.keys.contains("signInCheck") ? shown(object, "signInCheck") : "no key"
        }
        compare("signInCheck", check(made), check(row))
        let generated = document.generatedAt
        compare(
            "stateSince", since(made["stateSince"], generated: generated),
            since(row["stateSince"], generated: generated))
        return differ + readingDifferences(row, made, generated: generated)
    }

    /// Where the reading fields differ, compared apart from the rest. The writer is handed the
    /// reading the row shows, so the limit, meters, age and reserve it makes, and its warnings,
    /// must come out as the row has them. Sessions are not read, so `inUse` is the scene's own.
    static func readingDifferences(
        _ row: [String: Any], _ made: [String: Any], generated: Date
    ) -> [String] {
        var differ: [String] = []
        func compare(_ field: String, _ writer: String, _ scene: String) {
            if writer != scene { differ.append("\(field) \(writer) / \(scene)") }
        }
        compare("readingsAge", shown(made, "readingsAge"), shown(row, "readingsAge"))
        let limits = (made["limited"] as? [String: Any], row["limited"] as? [String: Any])
        compare("limited", limits.0 == nil ? "null" : "set", limits.1 == nil ? "null" : "set")
        if let writer = limits.0, let scene = limits.1 {
            for key in ["window", "until"] {
                compare("limited.\(key)", shown(writer, key), shown(scene, key))
            }
            compare(
                "limited.since", since(writer["since"], generated: generated),
                since(scene["since"], generated: generated))
        }
        // A scene leaves out a meter, the reserve, or when a window was read, at times.
        for key in ["weekly", "fiveHour", "fable", "reserve"] {
            guard let scene = row[key] as? [String: Any] else { continue }
            let writer = made[key] as? [String: Any] ?? [:]
            let parts = Set(scene.keys).union(writer.keys.filter { $0 != "readAt" })
            for part in parts.sorted() {
                compare("\(key).\(part)", shown(writer, part), shown(scene, part))
            }
        }
        // A warning's text holds a local date, so the codes are compared.
        func codes(_ value: Any?) -> String {
            ((value as? [[String: Any]]) ?? []).map { $0["code"] as? String ?? "" }
                .joined(separator: " ")
        }
        compare("warnings", codes(made["warnings"]), codes(row["warnings"]))
        return differ
    }

    /// Rules of the scenes themselves: the fixture labels at example.com, one end marker, and a
    /// token saved no later than the document.
    static func sceneRules(_ row: [String: Any], generated: Date, at: String) -> [String] {
        var broken: [String] = []
        let label = row["label"] as? String ?? ""
        if !labels.contains(label) { broken.append("\(at): a label the scenes do not use") }
        // An address `add` takes: one fixture label at example.com, with at most one hyphen first.
        let email = row["email"] as? String ?? ""
        if !["", "-"].map({ $0 + label + "@example.com" }).contains(email) {
            broken.append("\(at): an address the scenes do not use")
        }
        if row["endsAt"] as? String != nil, row["endingSoon"] as? Bool == true {
            broken.append("\(at): two end markers")
        }
        if row["kind"] as? String == Kind.token,
            let expires = date(row["loginExpiresAt"] as? String),
            expires.timeIntervalSince(generated) > Transitions.tokenLifeDays * 86_400
        {
            broken.append("\(at): a token saved after the document")
        }
        return broken
    }

    /// What keeps a scene document from being one the writer writes; nothing when it is one.
    static func problems(_ text: String, name: String) throws -> [String] {
        guard case .loaded(let snapshot) = StatusSnapshot.parse(Data(text.utf8)),
            let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
            let generated = date(object["generatedAt"] as? String),
            let rows = object["accounts"] as? [[String: Any]]
        else { return ["\(name) does not load in the app"] }
        var problems: [String] = []
        if rows.count != snapshot.accounts.count { problems.append("\(name): rows dropped") }
        for row in rows {
            let at = "\(name) \(row["label"] as? String ?? "")"
            problems += sceneRules(row, generated: generated, at: at)
        }
        let banner = object["banner"] as? [String: Any]
        // The settings memory gives the banner and the code of every login and token row.
        var found: [[String]] = []
        let issues: [String?] = banner == nil ? [nil] : ["changed", "missing"]
        for issue in issues {
            var unmade: [String] = []
            var matching: [[Inputs]] = []
            for row in rows {
                let all = try candidates(row, generated: generated)
                let fits = try all.filter {
                    try differences(row, build([$0], issue: issue, now: generated)).isEmpty
                }
                if fits.isEmpty {
                    let first = try all.first.map {
                        try differences(row, build([$0], issue: issue, now: generated))
                    }
                    let what = first?.joined(separator: "; ") ?? "no inputs read as this row"
                    unmade.append("\(name) \(row["label"] as? String ?? ""): \(what)")
                }
                matching.append(fits)
            }
            if unmade.isEmpty {
                // Each row's inputs, with as many and as few folders sharing settings as fit.
                let picks = [matching.compactMap(\.first), matching.compactMap(\.last)]
                let banners = picks.map {
                    shown(bannerObject(build($0, issue: issue, now: generated)), "banner")
                }
                if !banners.contains(shown(object, "banner")) {
                    unmade.append("\(name): banner \(banners[0]) / \(shown(object, "banner"))")
                }
            }
            if unmade.isEmpty { return problems }
            found.append(unmade)
        }
        return problems + (found.min { $0.count < $1.count } ?? [])
    }

    /// The document's banner as the status file holds it.
    static func bannerObject(_ document: StatusDocument) -> [String: Any] {
        guard let banner = document.banner else { return [:] }
        return ["banner": ["code": banner.code, "text": banner.text]]
    }

    @Test func everyManageSceneRowIsOneTheStatusWriterCanProduce() throws {
        let documents = try Self.documents()
        #expect(
            documents.map(\.name)
                == [
                    "tokenAccounts", "folderAccounts", "addedFolder", "statesJson", "emailNoteJson",
                ])
        var rows = 0
        for (name, text) in documents {
            let problems = try Self.problems(text, name: name)
            #expect(problems == [], "\(name)")
            if case .loaded(let snapshot) = StatusSnapshot.parse(Data(text.utf8)) {
                rows += snapshot.accounts.count
            }
        }
        #expect(rows == 19)
    }

    /// One edit of a scene document that leaves a row the writer can never write.
    struct SceneEdit: Sendable, CustomTestStringConvertible {
        let name: String
        let document: String
        let label: String
        let old: String
        let new: String
        var testDescription: String { name }
    }

    static let edits: [SceneEdit] = [
        // The settings memory that makes the banner puts `settings_changed` on every login row,
        // and it ranks above `check_failed`.
        SceneEdit(
            name: "a login row with check_failed under the settings banner",
            document: "statesJson", label: "main",
            old:
                #""code": "settings_changed", "text": "Settings changed. Run `agent-balancer link --accept-source-change` in Terminal." }"#,
            new: #""code": "check_failed", "text": "Check failed: probe timed out after 60 s." }"#
        ),
        // A token row shows an end only while its token is usable, and token_missing only when
        // it is not.
        SceneEdit(
            name: "a token_missing token row that keeps its end",
            document: "tokenAccounts", label: "spare-b",
            old:
                #""code": "login_rejected", "text": "Login rejected, or the plan has ended. Sign in again in Terminal; if it will not sign in, the plan has ended." }"#,
            new:
                #""code": "token_missing", "text": "No token saved. Run `agent-balancer login spare-b` in Terminal." }"#
        ),
        // A row that is not ok, or that has a reading, carries the time its state began.
        SceneEdit(
            name: "a signed-out folder row with no since time",
            document: "folderAccounts", label: "spare-b",
            old: #""stateSince": "2026-11-09T20:40:00Z","#, new: ""),
        // The README rows the Manage window draws follow the same rules.
        SceneEdit(
            name: "a README token row with token_missing that keeps its end",
            document: "manageTokens", label: "spare-b",
            old: #""endingSoon": true, "state": "ok","#,
            new:
                #""endingSoon": true, "state": "error", "error": { "code": "token_missing", "text": "No token saved. Run `agent-balancer login spare-b` in Terminal." },"#
        ),
        SceneEdit(
            name: "a usable README token row with no end",
            document: "manageTokens", label: "lab",
            old:
                #"{ "count": 2 },\#n              "loginExpiresAt": "2027-11-09T20:00:00Z", "loginExpiresSource": "estimate" }"#,
            new: #"{ "count": 2 } }"#),
        SceneEdit(
            name: "a README login row without the warning its end gives",
            document: "manageTokens", label: "main",
            old: #""warnings": [ { "code": "login_expiring", "text": "Login expires Nov 14." } ],"#,
            new: #""warnings": [],"#),
        SceneEdit(
            name: "a README limited row whose limit outlasts its weekly reset",
            document: "manageTokens", label: "spare-a",
            old: #""since": "2026-11-09T20:56:00Z", "until": "2026-11-12T22:00:00Z" }"#,
            new: #""since": "2026-11-09T20:56:00Z", "until": "2026-11-13T22:00:00Z" }"#),
        SceneEdit(
            name: "a README Fable estimate the weekly use does not give",
            document: "manageTokens", label: "spare-a",
            old: #""guaranteedLeftPercentOfCap": 0.0"#,
            new: #""guaranteedLeftPercentOfCap": 40.0"#),
    ]

    @Test(arguments: edits)
    func aSceneRowTheWriterCannotProduceIsFlagged(edit: SceneEdit) throws {
        let documents = try Self.documents() + Self.documents(in: Self.readmeSource)
        let text = try #require(documents.first { $0.name == edit.document }?.text)
        let unedited = try Self.problems(text, name: edit.document)
        #expect(unedited == [])
        #expect(text.components(separatedBy: edit.old).count == 2, "the edit applies once")
        let edited = text.replacingOccurrences(of: edit.old, with: edit.new)
        let problems = try Self.problems(edited, name: edit.document)
        let flagged = "\(edit.document) \(edit.label): "
        #expect(problems.contains { $0.hasPrefix(flagged) }, "\(problems)")
    }
}
