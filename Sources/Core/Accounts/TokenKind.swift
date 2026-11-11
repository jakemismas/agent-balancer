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

    /// The first other account whose weekly and 5-hour reset times both equal this account's, or
    /// nil. A reset time that is unknown or already past never counts. Reads no file: it works
    /// from the readings it is given. The refresher runs it in the reading cache's `afterProbe`
    /// hook, so it runs on every probe of a token account.
    static func possibleDuplicate(
        of label: String, accounts: [Account], readings: [String: Reading], now: Date
    ) -> String? {
        guard let mine = readings[label] else { return nil }
        func pair(_ reading: Reading) -> (Date, Date)? {
            guard let week = reading.sevenDay?.resetsAt, let five = reading.fiveHour?.resetsAt,
                week > now, five > now
            else { return nil }
            return (week, five)
        }
        guard let own = pair(mine) else { return nil }
        for other in accounts where other.label != label {
            guard let reading = readings[other.label], let theirs = pair(reading) else { continue }
            if abs(theirs.0.timeIntervalSince(own.0)) < 1
                && abs(theirs.1.timeIntervalSince(own.1)) < 1
            {
                return other.label
            }
        }
        return nil
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
