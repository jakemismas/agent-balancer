import Core
import Foundation
import SwiftUI

/// Fixed data for the render tool. Labels and example.com addresses only. The first scene is the
/// mock of design/render.html.
enum RenderScenes {
    static let now = ISO8601DateFormatter().date(from: "2026-11-09T21:13:00Z") ?? Date()

    static let sample = """
        {
          "schemaVersion": 1, "generatedAt": "2026-11-09T21:11:00Z", "banner": null,
          "next": {
            "all": { "label": "personal", "reason": "Soonest weekly reset with room: Tue 9:00 AM, 48% room." },
            "fable": { "label": "lab", "reason": "personal: Fable 93% used; lab resets next." }
          },
          "accounts": [
            { "label": "main", "email": "main@example.com", "role": "main", "state": "ok",
              "weekly": { "usedPercent": 41.0, "resetsAt": "2026-11-13T17:00:00Z", "source": "probe" },
              "fable": { "usedPercent": 12.0, "resetsAt": "2026-11-13T17:00:00Z", "source": "probe" },
              "readingsAge": 120, "inUse": { "count": 1, "sessions": [] },
              "reserve": { "linePercent": 66.0, "marginPercent": 5, "launchAllowed": true, "daysLeft": 3.8 } },
            { "label": "personal", "email": "personal@example.com", "role": "pool", "state": "ok",
              "weekly": { "usedPercent": 47.0, "resetsAt": "2026-11-10T17:00:00Z", "source": "probe" },
              "fable": { "usedPercent": 93.0, "resetsAt": "2026-11-10T17:00:00Z", "source": "probe" },
              "readingsAge": 480, "inUse": { "count": 0, "sessions": [] } },
            { "label": "lab", "email": "lab@example.com", "role": "pool", "state": "ok",
              "weekly": { "usedPercent": 22.0, "resetsAt": "2026-11-12T02:00:00Z", "source": "probe" },
              "fable": { "usedPercent": 8.0, "resetsAt": "2026-11-12T02:00:00Z", "source": "probe" },
              "readingsAge": 60, "inUse": { "count": 2, "sessions": [] } },
            { "label": "spare-a", "email": "spare-a@example.com", "role": "pool", "state": "ok",
              "endsAt": "2026-11-16",
              "weekly": { "usedPercent": 61.0, "resetsAt": "2026-11-12T22:00:00Z", "source": "probe" },
              "fable": { "usedPercent": null, "guaranteedLeftPercentOfCap": 0.0, "possibleLeftPercentOfCap": 78.0, "source": "estimate" },
              "readingsAge": 900, "inUse": { "count": 0, "sessions": [] } },
            { "label": "spare-b", "email": "spare-b@example.com", "role": "pool", "state": "error",
              "endingSoon": true,
              "error": { "code": "login_rejected", "text": "This account's folder is logged out. Run agent-balancer login spare-b in Terminal." },
              "weekly": { "usedPercent": null, "resetsAt": null, "source": "none" },
              "fable": null, "inUse": { "count": 0, "sessions": [] } }
          ]
        }
        """

    static let moreStates = """
        {
          "schemaVersion": 1, "generatedAt": "2026-11-09T21:11:00Z",
          "banner": { "code": "settings_changed", "text": "Settings changed. Run `agent-balancer link --accept-source-change` in Terminal." },
          "next": {
            "all": { "label": null, "reason": "No account has room." },
            "fable": { "label": null, "reason": "No account has room." }
          },
          "accounts": [
            { "label": "main", "email": "main@example.com", "role": "main", "state": "error",
              "error": { "code": "settings_changed", "text": "Settings changed." },
              "weekly": { "usedPercent": 96.0, "resetsAt": "2026-11-13T17:00:00Z", "source": "probe" },
              "fable": { "usedPercent": 40.0, "resetsAt": "2026-11-13T17:00:00Z", "source": "probe" },
              "readingsAge": 20000, "warnings": [ { "code": "login_expiring", "text": "Login expires Dec 7." } ] },
            { "label": "pool-a", "email": "pool-a@example.com", "role": "pool", "state": "limited",
              "limited": { "window": "weekly", "until": "2026-11-11T00:00:00Z" },
              "weekly": { "usedPercent": 82.0, "resetsAt": "2026-11-11T00:00:00Z", "source": "probe" },
              "fable": { "usedPercent": 10.0, "resetsAt": "2026-11-11T00:00:00Z", "source": "probe" },
              "readingsAge": 90, "warnings": [ { "code": "possible_duplicate", "text": "Same reset times as main. If this is the same account, remove one." } ] },
            { "label": "pool-b", "email": "pool-b@example.com", "role": "pool", "state": "error",
              "error": { "code": "not_linked", "text": "Settings not shared. Run agent-balancer link pool-b in Terminal." },
              "weekly": { "usedPercent": null, "source": "none" } }
          ]
        }
        """

    @MainActor static func screen(_ json: String, cli: Bool = true, config: Bool = true)
        -> MenuScreen
    {
        MenuBuilder.screen(
            MenuInputs(
                configExists: config, cliFound: cli,
                cliTried: ["/opt/homebrew/bin/agent-balancer", "/usr/local/bin/agent-balancer"],
                status: StatusSnapshot.parse(Data(json.utf8)), now: now, backgroundMinutes: 60))
    }

    @MainActor static func inputs(
        status: StatusLoad, cli: Bool = true, config: Bool = true
    ) -> MenuScreen {
        MenuBuilder.screen(
            MenuInputs(
                configExists: config, cliFound: cli,
                cliTried: ["/opt/homebrew/bin/agent-balancer", "/usr/local/bin/agent-balancer"],
                status: status, now: now, backgroundMinutes: 60))
    }

    @MainActor
    static func panel(
        _ screen: MenuScreen, refresh: RefreshState = .idle, login: Bool = true,
        steps: Set<String> = []
    ) -> AnyView {
        AnyView(
            PanelView(
                screen: screen, refreshState: refresh, loginItemOn: login, loginItemError: nil,
                actions: PanelActions(), stepsOpen: steps, heightCap: 2000))
    }

    @MainActor static func all() -> [(String, AnyView)] {
        [
            ("menu", panel(screen(sample))),
            ("menu-steps", panel(screen(sample), steps: ["spare-b"])),
            (
                "menu-states",
                panel(
                    screen(moreStates), refresh: .failed("Refresh failed: a probe timed out."),
                    login: false, steps: ["pool-b"])
            ),
            ("menu-refreshing", panel(screen(sample), refresh: .running)),
            ("empty-first-run", panel(inputs(status: .missing, config: false), login: false)),
            ("empty-reading", panel(inputs(status: .missing), login: false)),
            ("empty-cli-missing", panel(inputs(status: .missing, cli: false), login: false)),
            ("empty-update", panel(inputs(status: .newerSchema(2)), login: false)),
        ]
    }
}
