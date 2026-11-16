import Core
import Foundation
import SwiftUI

/// The pictures of the README, drawn from status documents written out in full. Every row,
/// badge and meter the pictures show is a state the status writer can produce at the document's
/// `generatedAt` time. Made-up accounts only: the labels main, personal, lab, spare-a and
/// spare-b, their example.com addresses and their own folders.
enum ReadmeScenes {
    /// The first of the README pictures: the menu half a minute after its last status poll, with
    /// three accounts, all ok, no warnings, and inUse count one on the main account.
    static let hero = """
        {
          "schemaVersion": 1, "generatedAt": "2026-11-09T21:12:30Z", "banner": null,
          "next": {
            "all": { "label": "personal", "reason": "Soonest weekly reset: resets Tue 9:00 AM." },
            "fable": { "label": "lab", "reason": "Soonest weekly reset: resets Wed 6:00 PM. Fable at least 92% of cap left." }
          },
          "accounts": [
            { "label": "main", "email": "main@example.com", "role": "main", "kind": "login",
              "fullLogin": true, "endingSoon": false, "planTier": "max_20x", "state": "ok",
              "warnings": [],
              "weekly": { "usedPercent": 41.0, "resetsAt": "2026-11-13T17:00:00Z", "source": "probe" },
              "fable": { "usedPercent": 12.0, "resetsAt": "2026-11-13T17:00:00Z", "source": "probe" },
              "readingsAge": 210, "inUse": { "count": 1 },
              "loginExpiresAt": "2026-12-04T20:00:00Z", "loginExpiresSource": "auth",
              "reserve": { "linePercent": 65.7, "marginPercent": 5, "launchAllowed": true, "daysLeft": 3.8 } },
            { "label": "personal", "email": "personal@example.com", "role": "pool", "kind": "token",
              "fullLogin": false, "endingSoon": false, "state": "ok", "warnings": [],
              "weekly": { "usedPercent": 47.0, "resetsAt": "2026-11-10T17:00:00Z", "source": "probe" },
              "fable": { "usedPercent": 93.0, "resetsAt": "2026-11-10T17:00:00Z", "source": "probe" },
              "readingsAge": 570, "inUse": { "count": 0 },
              "loginExpiresAt": "2027-10-27T10:00:00Z", "loginExpiresSource": "estimate" },
            { "label": "lab", "email": "lab@example.com", "role": "pool", "kind": "token",
              "fullLogin": false, "endingSoon": false, "state": "ok", "warnings": [],
              "weekly": { "usedPercent": 22.0, "resetsAt": "2026-11-12T02:00:00Z", "source": "probe" },
              "fable": { "usedPercent": 8.0, "resetsAt": "2026-11-12T02:00:00Z", "source": "probe" },
              "readingsAge": 150, "inUse": { "count": 0 },
              "loginExpiresAt": "2027-11-02T10:00:00Z", "loginExpiresSource": "estimate" }
          ]
        }
        """

    /// The menu half a minute after its last status poll: a login account, two token accounts
    /// and two folder accounts. One token account is limited and ends on a set day; one folder
    /// account ends soon and is signed out.
    static let menu = """
        {
          "schemaVersion": 1, "generatedAt": "2026-11-09T21:12:30Z", "banner": null,
          "next": {
            "all": { "label": "personal", "reason": "Soonest weekly reset: resets Tue 9:00 AM." },
            "fable": { "label": "lab", "reason": "Soonest weekly reset: resets Wed 6:00 PM. Fable at least 92% of cap left." }
          },
          "accounts": [
            { "label": "main", "email": "main@example.com", "role": "main", "kind": "login",
              "fullLogin": true, "endingSoon": false, "planTier": "max_20x", "state": "ok",
              "warnings": [ { "code": "login_expiring", "text": "Login expires Nov 14." } ],
              "weekly": { "usedPercent": 41.0, "resetsAt": "2026-11-13T17:00:00Z", "source": "probe" },
              "fable": { "usedPercent": 12.0, "resetsAt": "2026-11-13T17:00:00Z", "source": "probe" },
              "readingsAge": 210, "inUse": { "count": 1 },
              "loginExpiresAt": "2026-11-14T20:00:00Z", "loginExpiresSource": "auth",
              "reserve": { "linePercent": 65.7, "marginPercent": 5, "launchAllowed": true, "daysLeft": 3.8 } },
            { "label": "personal", "email": "personal@example.com", "role": "pool", "kind": "token",
              "fullLogin": false, "endingSoon": false, "state": "ok", "warnings": [],
              "weekly": { "usedPercent": 47.0, "resetsAt": "2026-11-10T17:00:00Z", "source": "probe" },
              "fable": { "usedPercent": 93.0, "resetsAt": "2026-11-10T17:00:00Z", "source": "probe" },
              "readingsAge": 570, "inUse": { "count": 0 },
              "loginExpiresAt": "2027-10-27T10:00:00Z", "loginExpiresSource": "estimate" },
            { "label": "lab", "email": "lab@example.com", "role": "pool", "kind": "folder",
              "fullLogin": true, "configDir": "~/.agent-balancer/accounts/lab/.claude",
              "linked": true, "endingSoon": false, "planTier": "max_20x", "signInCheck": "signed_in",
              "state": "ok", "warnings": [],
              "weekly": { "usedPercent": 22.0, "resetsAt": "2026-11-12T02:00:00Z", "source": "probe" },
              "fable": { "usedPercent": 8.0, "resetsAt": "2026-11-12T02:00:00Z", "source": "probe" },
              "readingsAge": 150, "inUse": { "count": 2 } },
            { "label": "spare-a", "email": "spare-a@example.com", "role": "pool", "kind": "token",
              "fullLogin": false, "endingSoon": false, "endsAt": "2026-11-16", "state": "limited",
              "limited": { "window": "weekly", "since": "2026-11-09T20:56:00Z", "until": "2026-11-12T22:00:00Z" },
              "warnings": [],
              "weekly": { "usedPercent": 100.0, "resetsAt": "2026-11-12T22:00:00Z", "source": "probe" },
              "fable": { "usedPercent": null, "guaranteedLeftPercentOfCap": 0.0, "possibleLeftPercentOfCap": 100.0, "source": "estimate" },
              "readingsAge": 990, "inUse": { "count": 0 },
              "loginExpiresAt": "2027-11-02T10:00:00Z", "loginExpiresSource": "estimate" },
            { "label": "spare-b", "email": "spare-b@example.com", "role": "pool", "kind": "folder",
              "fullLogin": true, "configDir": "~/.agent-balancer/accounts/spare-b/.claude",
              "linked": true, "endingSoon": true, "signInCheck": "signed_out",
              "state": "error", "stateSince": "2026-11-09T20:40:00Z",
              "error": { "code": "login_rejected", "text": "Login rejected, or the plan has ended. Sign in again in Terminal; if it will not sign in, the plan has ended." },
              "warnings": [],
              "weekly": { "usedPercent": null, "resetsAt": null, "source": "none" },
              "fable": { "usedPercent": null, "source": "none" },
              "inUse": { "count": 0 } }
          ]
        }
        """

    /// The Manage accounts window a minute after it ran
    /// `agent-balancer config set spare-b ending-soon true`, with token accounts in the pool.
    static let manageTokens = """
        {
          "schemaVersion": 1, "generatedAt": "2026-11-09T21:12:00Z", "banner": null,
          "next": {
            "all": { "label": "personal", "reason": "Soonest weekly reset: resets Tue 9:00 AM." },
            "fable": { "label": "lab", "reason": "Soonest weekly reset: resets Wed 6:00 PM. Fable at least 92% of cap left." }
          },
          "accounts": [
            { "label": "main", "email": "main@example.com", "role": "main", "kind": "login",
              "fullLogin": true, "endingSoon": false, "planTier": "max_20x", "state": "ok",
              "stateSince": "2026-11-09T20:40:00Z",
              "warnings": [ { "code": "login_expiring", "text": "Login expires Nov 14." } ],
              "weekly": { "usedPercent": 41.0, "resetsAt": "2026-11-13T17:00:00Z", "source": "probe" },
              "fable": { "usedPercent": 12.0, "resetsAt": "2026-11-13T17:00:00Z", "source": "probe" },
              "readingsAge": 180, "inUse": { "count": 1 },
              "loginExpiresAt": "2026-11-14T20:00:00Z", "loginExpiresSource": "auth",
              "reserve": { "linePercent": 65.7, "marginPercent": 5, "launchAllowed": true, "daysLeft": 3.8 } },
            { "label": "personal", "email": "personal@example.com", "role": "pool", "kind": "token",
              "fullLogin": false, "endingSoon": false, "state": "ok", "warnings": [],
              "stateSince": "2026-11-09T20:40:00Z",
              "weekly": { "usedPercent": 47.0, "resetsAt": "2026-11-10T17:00:00Z", "source": "probe" },
              "fable": { "usedPercent": 93.0, "resetsAt": "2026-11-10T17:00:00Z", "source": "probe" },
              "readingsAge": 540, "inUse": { "count": 0 },
              "loginExpiresAt": "2027-10-27T10:00:00Z", "loginExpiresSource": "estimate" },
            { "label": "lab", "email": "lab@example.com", "role": "pool", "kind": "token",
              "fullLogin": false, "endingSoon": false, "state": "ok", "warnings": [],
              "stateSince": "2026-11-09T20:40:00Z",
              "weekly": { "usedPercent": 22.0, "resetsAt": "2026-11-12T02:00:00Z", "source": "probe" },
              "fable": { "usedPercent": 8.0, "resetsAt": "2026-11-12T02:00:00Z", "source": "probe" },
              "readingsAge": 120, "inUse": { "count": 2 },
              "loginExpiresAt": "2027-11-09T20:00:00Z", "loginExpiresSource": "estimate" },
            { "label": "spare-a", "email": "spare-a@example.com", "role": "pool", "kind": "token",
              "fullLogin": false, "endingSoon": false, "endsAt": "2026-11-16", "state": "limited",
              "stateSince": "2026-11-09T20:56:00Z",
              "limited": { "window": "weekly", "since": "2026-11-09T20:56:00Z", "until": "2026-11-12T22:00:00Z" },
              "warnings": [],
              "weekly": { "usedPercent": 100.0, "resetsAt": "2026-11-12T22:00:00Z", "source": "probe" },
              "fable": { "usedPercent": null, "guaranteedLeftPercentOfCap": 0.0, "possibleLeftPercentOfCap": 100.0, "source": "estimate" },
              "readingsAge": 960, "inUse": { "count": 0 },
              "loginExpiresAt": "2027-11-02T10:00:00Z", "loginExpiresSource": "estimate" },
            { "label": "spare-b", "email": "spare-b@example.com", "role": "pool", "kind": "token",
              "fullLogin": false, "endingSoon": true, "state": "ok", "warnings": [],
              "stateSince": "2026-11-09T20:40:00Z",
              "weekly": { "usedPercent": 61.0, "resetsAt": "2026-11-14T05:00:00Z", "source": "probe" },
              "fable": { "usedPercent": 91.0, "resetsAt": "2026-11-14T05:00:00Z", "source": "probe" },
              "readingsAge": 300, "inUse": { "count": 0 },
              "loginExpiresAt": "2027-11-05T10:00:00Z", "loginExpiresSource": "estimate" }
          ]
        }
        """

    /// The same moment with folder accounts in the pool, each linked and signed in.
    static let manageFolders = """
        {
          "schemaVersion": 1, "generatedAt": "2026-11-09T21:12:00Z", "banner": null,
          "next": {
            "all": { "label": "personal", "reason": "Soonest weekly reset: resets Tue 9:00 AM." },
            "fable": { "label": "lab", "reason": "Soonest weekly reset: resets Wed 6:00 PM. Fable at least 92% of cap left." }
          },
          "accounts": [
            { "label": "main", "email": "main@example.com", "role": "main", "kind": "login",
              "fullLogin": true, "endingSoon": false, "planTier": "max_20x", "state": "ok",
              "stateSince": "2026-11-09T20:40:00Z",
              "warnings": [ { "code": "login_expiring", "text": "Login expires Nov 14." } ],
              "weekly": { "usedPercent": 41.0, "resetsAt": "2026-11-13T17:00:00Z", "source": "probe" },
              "fable": { "usedPercent": 12.0, "resetsAt": "2026-11-13T17:00:00Z", "source": "probe" },
              "readingsAge": 180, "inUse": { "count": 1 },
              "loginExpiresAt": "2026-11-14T20:00:00Z", "loginExpiresSource": "auth",
              "reserve": { "linePercent": 65.7, "marginPercent": 5, "launchAllowed": true, "daysLeft": 3.8 } },
            { "label": "personal", "email": "personal@example.com", "role": "pool", "kind": "folder",
              "fullLogin": true, "configDir": "~/.agent-balancer/accounts/personal/.claude",
              "linked": true, "endingSoon": false, "planTier": "max_20x", "signInCheck": "signed_in",
              "state": "ok", "warnings": [],
              "stateSince": "2026-11-09T20:40:00Z",
              "weekly": { "usedPercent": 47.0, "resetsAt": "2026-11-10T17:00:00Z", "source": "probe" },
              "fable": { "usedPercent": 93.0, "resetsAt": "2026-11-10T17:00:00Z", "source": "probe" },
              "readingsAge": 540, "inUse": { "count": 0 } },
            { "label": "lab", "email": "lab@example.com", "role": "pool", "kind": "folder",
              "fullLogin": true, "configDir": "~/.agent-balancer/accounts/lab/.claude",
              "linked": true, "endingSoon": false, "planTier": "max_20x", "signInCheck": "signed_in",
              "state": "ok", "warnings": [],
              "stateSince": "2026-11-09T20:40:00Z",
              "weekly": { "usedPercent": 22.0, "resetsAt": "2026-11-12T02:00:00Z", "source": "probe" },
              "fable": { "usedPercent": 8.0, "resetsAt": "2026-11-12T02:00:00Z", "source": "probe" },
              "readingsAge": 120, "inUse": { "count": 2 } },
            { "label": "spare-a", "email": "spare-a@example.com", "role": "pool", "kind": "folder",
              "fullLogin": true, "configDir": "~/.agent-balancer/accounts/spare-a/.claude",
              "linked": true, "endingSoon": false, "endsAt": "2026-11-16", "planTier": "max_20x",
              "signInCheck": "signed_in", "state": "limited",
              "stateSince": "2026-11-09T20:56:00Z",
              "limited": { "window": "weekly", "since": "2026-11-09T20:56:00Z", "until": "2026-11-12T22:00:00Z" },
              "warnings": [],
              "weekly": { "usedPercent": 100.0, "resetsAt": "2026-11-12T22:00:00Z", "source": "probe" },
              "fable": { "usedPercent": null, "guaranteedLeftPercentOfCap": 0.0, "possibleLeftPercentOfCap": 100.0, "source": "estimate" },
              "readingsAge": 960, "inUse": { "count": 0 } },
            { "label": "spare-b", "email": "spare-b@example.com", "role": "pool", "kind": "folder",
              "fullLogin": true, "configDir": "~/.agent-balancer/accounts/spare-b/.claude",
              "linked": true, "endingSoon": true, "planTier": "max_20x", "signInCheck": "signed_in",
              "state": "ok", "warnings": [],
              "stateSince": "2026-11-09T20:40:00Z",
              "weekly": { "usedPercent": 61.0, "resetsAt": "2026-11-14T05:00:00Z", "source": "probe" },
              "fable": { "usedPercent": 91.0, "resetsAt": "2026-11-14T05:00:00Z", "source": "probe" },
              "readingsAge": 300, "inUse": { "count": 0 } }
          ]
        }
        """

    @MainActor static func all() -> [(String, AnyView)] {
        [
            ("readme-menu", RenderScenes.panel(RenderScenes.screen(menu))),
            ("readme-manage-tokens", ManageScenes.window(folder: false, json: manageTokens)),
            ("readme-manage-folders", ManageScenes.window(folder: true, json: manageFolders)),
        ]
    }

    /// The first of the README pictures, drawn under the menu bar by the render tool.
    @MainActor static func underBar() -> [(String, AnyView)] {
        [("readme-hero", RenderScenes.panel(RenderScenes.screen(hero)))]
    }
}
