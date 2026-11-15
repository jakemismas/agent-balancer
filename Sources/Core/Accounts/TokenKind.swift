import Foundation

/// The `token` kind: its probe context, the estimate of when its token ends, and the duplicate
/// check of docs/ARCHITECTURE.md section 4A.4.
enum TokenKind {
    /// The time a token's year counts from: `tokenCreatedAt` when the config has it, else the last
    /// change of the token file (an account added before that field existed).
    static func createdAt(_ account: Account, fileModified: Date?) -> Date? {
        if let text = account.tokenCreatedAt, let date = ISO8601DateFormatter().date(from: text) {
            return date
        }
        return fileModified
    }

    /// The first of `possibleDuplicates`, or nil.
    static func possibleDuplicate(
        of label: String, accounts: [Account], readings: [String: Reading], now: Date
    ) -> String? {
        possibleDuplicates(of: label, accounts: accounts, readings: readings, now: now).first
    }

    /// Every other account whose reset times equal this account's. The weekly reset must be known
    /// and still ahead on both sides. The 5-hour reset must match when both sides have one, and an
    /// idle account has none, so the weekly time alone decides then. Reads no file: it works from
    /// the readings it is given. The refresher runs it in the reading cache's `afterProbe` hook,
    /// so it runs on every probe of a token account.
    static func possibleDuplicates(
        of label: String, accounts: [Account], readings: [String: Reading], now: Date
    ) -> [String] {
        guard let mine = readings[label], let ownWeek = future(mine.sevenDay?.resetsAt, now)
        else { return [] }
        let ownFive = future(mine.fiveHour?.resetsAt, now)
        var found: [String] = []
        for other in accounts where other.label != label {
            guard let reading = readings[other.label],
                let week = future(reading.sevenDay?.resetsAt, now),
                abs(week.timeIntervalSince(ownWeek)) < 1
            else { continue }
            if let ownFive, let five = future(reading.fiveHour?.resetsAt, now),
                abs(five.timeIntervalSince(ownFive)) >= 1
            {
                continue
            }
            found.append(other.label)
        }
        return found
    }

    private static func future(_ date: Date?, _ now: Date) -> Date? {
        guard let date, date > now else { return nil }
        return date
    }

    static func duplicateText(_ other: String) -> String {
        "Same reset times as \(Display.safe(other, limit: 32)). If this is the same account, remove one."
    }

    /// A token account is probed with its token file named in `--settings`, and no
    /// `CLAUDE_CONFIG_DIR` is set. The `Tokens` module first checks that the file is private and
    /// parses; only a yes or no comes back, and the probe gets the path, never the token.
    static func probeContext(account: Account, context: ToolContext) throws -> ProbeContext {
        let facts = try TokenPaths.facts(context: context, label: account.label)
        // A file that is absent, not private or does not parse counts as no token, as in pick.
        guard facts.isPrivate, TokenStore.isUsable(context: context, label: account.label) else {
            throw ToolError(Messages.tokenMissing(account.label), code: .tokenMissing)
        }
        let path = try TokenPaths.fileURL(context: context, label: account.label).path
        return ProbeContext(
            extraArguments: ["--settings", path], configDir: nil, callsAfterProbeHook: true)
    }
}
