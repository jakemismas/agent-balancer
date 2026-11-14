import Foundation
import Testing

@testable import Core

/// The row, header and empty-state models of the menu app.
@Suite(.localZone("America/Los_Angeles")) struct ViewModelTests {
    static let now = ISO8601DateFormatter().date(from: "2026-11-09T21:13:00Z")!

    static func json(_ account: String, next: String? = nil, banner: String = "null") -> String {
        let nextJson =
            next
                ?? """
                { "all": { "label": "a", "reason": "r1" }, "fable": { "label": null, "reason": "r2" } }
                """
        return """
            { "schemaVersion": 1, "generatedAt": "2026-11-09T21:11:00Z", "banner": \(banner),
              "next": \(nextJson), "accounts": [ \(account) ] }
            """
    }

    static func screen(
        _ text: String, cli: Bool = true, config: Bool = true, minutes: Int = 60
    ) -> MenuScreen {
        LocalTime.zone = TimeZone(identifier: "America/Los_Angeles")!
        return MenuBuilder.screen(
            MenuInputs(
                configExists: config, cliFound: cli, cliTried: ["/x/agent-balancer"],
                status: StatusSnapshot.parse(Data(text.utf8)), now: now, backgroundMinutes: minutes)
        )
    }

    static func rows(_ text: String) -> [RowModel] {
        guard case .accounts(let a) = screen(text) else { return [] }
        return a.rows
    }

    static let okAccount = """
        { "label": "main", "email": "main@example.com", "role": "main", "state": "ok",
          "weekly": { "usedPercent": 41.0, "resetsAt": "2026-11-13T17:00:00Z", "source": "probe" },
          "fable": { "usedPercent": 12.0, "resetsAt": "2026-11-13T17:00:00Z", "source": "probe" },
          "readingsAge": 120, "inUse": { "count": 2, "sessions": [ { "id": "1a2b3c4d", "name": "secret-session" } ] },
          "reserve": { "linePercent": 66.0, "marginPercent": 5, "launchAllowed": true, "daysLeft": 3.8 } }
        """

    @Test func rowShowsLabelEmailBadgeInUseMetersAndReset() throws {
        let row = try #require(Self.rows(Self.json(Self.okAccount)).first)
        #expect(row.label == "main")
        #expect(row.email == "main@example.com")
        #expect(row.roleBadge == "main")
        #expect(row.isMain)
        #expect(row.inUseText == "2 in use")
        guard case .meters(let m) = row.body else {
            Issue.record("expected meters")
            return
        }
        #expect(m.all.valueText == "41% used")
        #expect(m.all.kind == .solid(0.41))
        #expect(m.fable?.valueText == "12% used")
        #expect(m.fable?.kind == .solid(0.12))
        #expect(m.resetText == "Resets Fri 9:00 AM")
        #expect(row.notes.isEmpty)
        #expect(!row.dimmed)
    }

    @Test func rowEndsAtResetTimeWithNoAgeAndNoSource() throws {
        let row = try #require(Self.rows(Self.json(Self.okAccount)).first)
        let flat = String(describing: row)
        #expect(!flat.contains("probe"))
        #expect(!flat.contains("secret-session"))
        #expect(!flat.contains("main@example.com ago"))
        guard case .meters(let m) = row.body else { return }
        #expect(m.resetText?.hasPrefix("Resets ") == true)
    }

    @Test func rowDoesNotShowTheKindOrTheReserveLine() throws {
        let row = try #require(Self.rows(Self.json(Self.okAccount)).first)
        let flat = String(describing: row).lowercased()
        #expect(!flat.contains("reserve"))
        #expect(!flat.contains("token"))
        #expect(!flat.contains("folder"))
    }

    @Test func meterToneFollowsUse() throws {
        func tone(_ used: Double) throws -> MeterTone {
            let a = Self.okAccount.replacingOccurrences(of: "41.0", with: "\(used)")
            let row = try #require(Self.rows(Self.json(a)).first)
            guard case .meters(let m) = row.body else { return .normal }
            return m.all.tone
        }
        #expect(try tone(79.9) == .normal)
        #expect(try tone(80) == .warn)
        #expect(try tone(95) == .crit)
    }

    @Test func fableEstimateBeforeFirstReading() throws {
        let a = """
            { "label": "spare-a", "email": "spare-a@example.com", "role": "pool", "state": "ok",
              "endsAt": "2026-11-16",
              "weekly": { "usedPercent": 61.0, "resetsAt": "2026-11-12T22:00:00Z", "source": "probe" },
              "fable": { "usedPercent": null, "guaranteedLeftPercentOfCap": 22.0, "possibleLeftPercentOfCap": 78.0, "source": "estimate" } }
            """
        let row = try #require(Self.rows(Self.json(a)).first)
        #expect(row.endBadge == "ends Nov 16")
        #expect(row.roleBadge == "pool")
        guard case .meters(let m) = row.body, let f = m.fable else {
            Issue.record("expected a fable meter")
            return
        }
        #expect(f.valueText == "up to 78% used (est.)")
        #expect(f.kind == .estimate(free: 0.22, possible: 0.78))
    }

    @Test func fableIsSolidOnceReadAndNeverBothKinds() throws {
        let a = """
            { "label": "p", "role": "pool", "state": "ok",
              "weekly": { "usedPercent": 10, "resetsAt": "2026-11-12T22:00:00Z", "source": "probe" },
              "fable": { "usedPercent": 93.0, "guaranteedLeftPercentOfCap": 5.0, "source": "probe" } }
            """
        let row = try #require(Self.rows(Self.json(a)).first)
        guard case .meters(let m) = row.body else { return }
        #expect(m.fable?.kind == .solid(0.93))
        #expect(m.fable?.valueText == "93% used")
    }

    @Test func meterAccessibilityNamesAccountBudgetValueAndReset() throws {
        let row = try #require(Self.rows(Self.json(Self.okAccount)).first)
        guard case .meters(let m) = row.body else { return }
        #expect(m.all.accessibilityLabel == "main, all models, resets Fri 9:00 AM")
        #expect(m.all.accessibilityValue == "41% used")
        #expect(m.fable?.accessibilityLabel == "main, Fable, resets Fri 9:00 AM")
        #expect(m.fable?.accessibilityValue == "12% of the Fable cap used")
    }

    @Test func errorRowCarriesCodeTextAndFixCommand() throws {
        func error(_ code: String, label: String = "pool-b") throws -> ErrorModel {
            let a = """
                { "label": "\(label)", "role": "pool", "state": "error",
                  "error": { "code": "\(code)", "text": "Some text." },
                  "weekly": { "usedPercent": null, "source": "none" } }
                """
            let row = try #require(Self.rows(Self.json(a)).first)
            guard case .error(let e) = row.body else {
                Issue.record("expected an error body")
                return ErrorModel(
                    title: "", text: "", steps: StepsModel(steps: [], command: nil))
            }
            return e
        }
        let rejected = try error("login_rejected")
        #expect(rejected.title == "Login rejected")
        #expect(rejected.text == "Some text.")
        #expect(rejected.steps.command == "agent-balancer login pool-b")
        #expect(try error("token_missing").steps.command == "agent-balancer login pool-b")
        #expect(try error("not_linked").steps.command == "agent-balancer link pool-b")
        #expect(try error("check_failed").steps.command == nil)
        #expect(try error("login_rejected", label: "a b; rm").steps.command == nil)
    }

    @Test func warningRowsShowTheirTextAndStaleShowsOnOldReadings() throws {
        let a = """
            { "label": "p", "role": "pool", "state": "ok",
              "weekly": { "usedPercent": 10, "resetsAt": "2026-11-12T22:00:00Z", "source": "probe" },
              "fable": null, "readingsAge": 7500,
              "warnings": [ { "code": "login_expiring", "text": "Login expires Dec 7." },
                            { "code": "possible_duplicate", "text": "Same reset times as pool-a." },
                            { "code": "key_in_settings", "text": "Settings carry an API key." } ] }
            """
        let row = try #require(Self.rows(Self.json(a)).first)
        let texts = row.notes.map(\.text)
        #expect(texts.contains("Login expires Dec 7."))
        #expect(texts.contains("Same reset times as pool-a."))
        #expect(!texts.contains("Settings carry an API key."))
        #expect(texts.contains("Last read 2 h ago."))
        #expect(row.dimmed)
    }

    @Test func aFreshReadingShowsNoStaleWarning() throws {
        let row = try #require(Self.rows(Self.json(Self.okAccount)).first)
        #expect(row.notes.isEmpty)
    }

    @Test func limitedAccountShowsUntilTime() throws {
        let a = """
            { "label": "p", "role": "pool", "state": "limited",
              "limited": { "window": "weekly", "until": "2026-11-11T00:00:00Z" },
              "weekly": { "usedPercent": 100, "resetsAt": "2026-11-11T00:00:00Z", "source": "probe" } }
            """
        let row = try #require(Self.rows(Self.json(a)).first)
        #expect(row.notes.first?.text == "Limited until Tue 4:00 PM.")
    }

    @Test func accountWithNoReadingSaysReadingAccounts() throws {
        let a = """
            { "label": "p", "role": "pool", "state": "ok", "weekly": { "usedPercent": null, "source": "none" } }
            """
        let row = try #require(Self.rows(Self.json(a)).first)
        #expect(row.body == .note("Reading accounts"))
    }

    @Test func endingSoonBadge() throws {
        let a = """
            { "label": "p", "role": "pool", "state": "ok", "endingSoon": true,
              "weekly": { "usedPercent": 1, "resetsAt": "2026-11-12T22:00:00Z", "source": "probe" } }
            """
        let row = try #require(Self.rows(Self.json(a)).first)
        #expect(row.endBadge == "ending soon")
    }

    @Test func headerShowsNextLaunchAndNextFable() throws {
        guard case .accounts(let a) = Self.screen(Self.json(Self.okAccount)) else {
            Issue.record("expected accounts")
            return
        }
        #expect(a.next?.allLabel == "a")
        #expect(a.next?.allReason == "r1")
        #expect(a.next?.fableLabel == "none")
        #expect(a.next?.fableReason == "r2")
        #expect(a.updatedText == "Updated 2 min ago")
    }

    @Test func settingsChangedIsOneBannerAndNoErrorRows() throws {
        let accounts = ["main", "pool-a"].map {
            """
            { "label": "\($0)", "role": "pool", "state": "error",
              "error": { "code": "settings_changed", "text": "Settings changed." },
              "weekly": { "usedPercent": null, "source": "none" } }
            """
        }.joined(separator: ",")
        let banner = """
            { "code": "settings_changed", "text": "Settings changed. Run `agent-balancer link --accept-source-change` in Terminal." }
            """
        guard case .accounts(let a) = Self.screen(Self.json(accounts, banner: banner)) else {
            Issue.record("expected accounts")
            return
        }
        #expect(a.banner?.command == "agent-balancer link --accept-source-change")
        #expect(a.banner?.text.contains("`") == false)
        for row in a.rows {
            if case .error = row.body {
                Issue.record("a settings_changed row must not be an error row")
            }
        }
    }

    @Test func bannerComesFromAnAccountWhenTheDocumentHasNone() throws {
        let account = """
            { "label": "main", "role": "main", "state": "error",
              "error": { "code": "settings_changed", "text": "Settings changed. Run `agent-balancer doctor` in Terminal." },
              "weekly": { "usedPercent": null, "source": "none" } }
            """
        guard case .accounts(let a) = Self.screen(Self.json(account)) else { return }
        #expect(a.banner?.command == "agent-balancer doctor")
    }

    @Test func bannerCommandAcceptsOnlyAllowlistedForms() {
        let bad = [
            "agent-balancer link x; rm y", "agent-balancer link x\ny", "agent-balancer rm -rf",
            "agent-balancer login", "agent-balancer link --other", "agent-balancer init now",
            "agent-balancer login a b", "agent-balancer link $(x)",
        ]
        for c in bad { #expect(MenuBuilder.command(in: "Run `\(c)` now") == nil) }
        for c in ["agent-balancer init", "agent-balancer login work-1", "agent-balancer link a.b"] {
            #expect(MenuBuilder.command(in: "Run `\(c)` now") == c)
        }
    }

    @Test func noConfigShowsTheInitCard() {
        let s = MenuBuilder.screen(
            MenuInputs(
                configExists: false, cliFound: true, cliTried: [], status: .missing, now: Self.now,
                backgroundMinutes: 60))
        guard case .card(let c) = s else {
            Issue.record("expected a card")
            return
        }
        #expect(c.command == "agent-balancer init")
    }

    @Test func missingCLIListsThePathsTried() {
        let s = MenuBuilder.screen(
            MenuInputs(
                configExists: true, cliFound: false,
                cliTried: ["/opt/homebrew/bin/agent-balancer", "/usr/local/bin/agent-balancer"],
                status: .missing, now: Self.now, backgroundMinutes: 60))
        guard case .card(let c) = s else {
            Issue.record("expected a card")
            return
        }
        #expect(c.title == "agent-balancer not found")
        #expect(c.lines == ["/opt/homebrew/bin/agent-balancer", "/usr/local/bin/agent-balancer"])
    }

    @Test func configButNoStatusSaysReadingAccounts() {
        let s = MenuBuilder.screen(
            MenuInputs(
                configExists: true, cliFound: true, cliTried: [], status: .missing, now: Self.now,
                backgroundMinutes: 60))
        guard case .card(let c) = s else { return }
        #expect(c.title == "Reading accounts")
    }

    @Test func newerSchemaSaysUpdate() {
        let text = #"{ "schemaVersion": 2, "accounts": 5 }"#
        let s = Self.screen(text)
        guard case .card(let c) = s else {
            Issue.record("expected a card")
            return
        }
        #expect(c.title == "Update agent-balancer")
    }

    @Test func aDamagedStatusFileIsACardNotAnEmptyWindow() {
        for text in ["not json", "{}", #"{ "schemaVersion": 1, "accounts": "x" }"#] {
            if case .accounts = Self.screen(text) { Issue.record("damaged status became rows") }
        }
        if case .card = Self.screen("not json") {} else { Issue.record("expected a card") }
    }

    @Test func everyPathEndsInRowsOrACard() {
        let statuses: [StatusLoad] = [.missing, .unreadable("x"), .newerSchema(3)]
        for status in statuses {
            for cli in [true, false] {
                for config in [true, false] {
                    let s = MenuBuilder.screen(
                        MenuInputs(
                            configExists: config, cliFound: cli, cliTried: ["a"], status: status,
                            now: Self.now, backgroundMinutes: 60))
                    if case .accounts = s { Issue.record("no rows expected") }
                }
            }
        }
    }

    @Test func tipsAreAtMostTwoSentences() {
        #expect(!MenuTips.all.isEmpty)
        for tip in MenuTips.all {
            let sentences = tip.split(whereSeparator: { ".!?".contains($0) }).filter {
                !$0.trimmingCharacters(in: .whitespaces).isEmpty
            }
            #expect(sentences.count <= 2, "\(tip)")
        }
    }

    @Test func timeAndPercentFormats() {
        #expect(MenuFormat.percent(41) == "41%")
        #expect(MenuFormat.percent(12.5) == "12.5%")
        #expect(MenuFormat.ago(seconds: 30) == "just now")
        #expect(MenuFormat.ago(seconds: 120 * 60) == "2 h ago")
        #expect(MenuFormat.ago(seconds: 120) == "2 min ago")
        #expect(MenuFormat.day("2026-11-16") == "Nov 16")
        #expect(MenuFormat.day("garbage") == "garbage")
    }
}
