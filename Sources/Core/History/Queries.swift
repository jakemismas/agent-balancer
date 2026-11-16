import Foundation

/// Parsing and validation shared by `events` and `history`.
public enum QueryInput {
    /// A time as ISO 8601 text, or a span back from now such as `30m`, `24h` or `7d`.
    public static func time(_ text: String, now: Date) throws -> Date {
        let bad = ToolError("--since needs a time like 2026-11-09T21:10:00Z, or a span like 24h.")
        if let date = parseISO(text) { return date }
        guard let unit = text.last, "mhd".contains(unit), let amount = Int(text.dropLast()),
            amount >= 0, amount <= 100_000
        else { throw bad }
        let seconds: Double = unit == "m" ? 60 : unit == "h" ? 3_600 : 86_400
        return now.addingTimeInterval(-Double(amount) * seconds)
    }

    private static func parseISO(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return plain.date(from: text) ?? fractional.date(from: text)
    }

    public static func label(_ text: String?) throws -> String? {
        guard let text else { return nil }
        guard ConfigValidator.isValidLabel(text) else {
            throw ToolError(
                "--label must be 1 to 32 lowercase letters, digits or hyphens, starting with a letter or digit."
            )
        }
        return text
    }

    public static func limit(_ value: Int?, default fallback: Int) throws -> Int {
        guard let value else { return fallback }
        guard value >= 1, value <= 1000 else { throw ToolError("--limit must be from 1 to 1000.") }
        return value
    }
}

public struct EventsQuery: Sendable {
    public var after: Int?
    public var since: String?
    public var label: String?
    public var type: String?
    public var limit: Int?

    public init(
        after: Int? = nil, since: String? = nil, label: String? = nil, type: String? = nil,
        limit: Int? = nil
    ) {
        self.after = after
        self.since = since
        self.label = label
        self.type = type
        self.limit = limit
    }
}

/// An event as `events --json` prints it. It never holds an email, an id, a session name or a path.
public struct EventOut: Encodable, Equatable, Sendable {
    public var seq: Int
    public var at: Date
    public var notBefore: Date?
    public var label: String
    public var type: String
    public var code: String?
    public var window: String?
    public var resetsAt: Date?
    public var text: String

    private enum CodingKeys: String, CodingKey {
        case seq, at, notBefore, label, type, code, window, resetsAt, text
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(seq, forKey: .seq)
        try c.encode(at, forKey: .at)
        try c.encodeNullable(notBefore, forKey: .notBefore)
        try c.encode(label, forKey: .label)
        try c.encode(type, forKey: .type)
        if let code { try c.encode(code, forKey: .code) }
        try c.encodeNullable(window, forKey: .window)
        try c.encodeNullable(resetsAt, forKey: .resetsAt)
        try c.encode(text, forKey: .text)
    }
}

/// `events --json` (docs/ARCHITECTURE.md section 10.3).
public struct EventsAnswer: Encodable, Equatable, Sendable {
    public var generatedAt: Date
    public var recordId: String?
    public var cursor: Int
    public var oldestSeq: Int?
    public var gap: Bool
    public var more: Bool
    public var events: [EventOut]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, generatedAt, recordId, cursor, oldestSeq, gap, more, events
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(1, forKey: .schemaVersion)
        try c.encode(generatedAt, forKey: .generatedAt)
        try c.encodeNullable(recordId, forKey: .recordId)
        try c.encode(cursor, forKey: .cursor)
        try c.encodeNullable(oldestSeq, forKey: .oldestSeq)
        try c.encode(gap, forKey: .gap)
        try c.encode(more, forKey: .more)
        try c.encode(events, forKey: .events)
    }
}

extension EventLog {
    public func answer(_ query: EventsQuery, now: Date = Date()) throws -> EventsAnswer {
        let label = try QueryInput.label(query.label)
        let limit = try QueryInput.limit(query.limit, default: 200)
        let since = try query.since.map { try QueryInput.time($0, now: now) }
        if let type = query.type,
            type.range(of: "^[a-z_]{1,32}$", options: .regularExpression) == nil
        {
            throw ToolError("--type must be an event type such as limited.")
        }
        if let after = query.after, after < 0 { throw ToolError("--after must not be negative.") }

        let parsed = try read()
        let highest = parsed.events.last?.seq ?? 0
        let oldest = parsed.events.first?.seq
        let matching = parsed.events.filter { event in
            (query.after.map { event.seq > $0 } ?? true)
                && (label.map { event.label == $0 } ?? true)
                && (query.type.map { event.type == $0 } ?? true)
                && (since.map { event.at >= $0 } ?? true)
        }
        let shown = Array(matching.prefix(limit))
        let more = matching.count > shown.count
        var gap = false
        if let after = query.after {
            if let oldest, after < oldest - 1 { gap = true }
            if after > highest { gap = true }
        }
        return EventsAnswer(
            generatedAt: now, recordId: parsed.recordId,
            cursor: more ? (shown.last?.seq ?? highest) : highest, oldestSeq: oldest, gap: gap,
            more: more,
            events: shown.map {
                EventOut(
                    seq: $0.seq, at: $0.at, notBefore: $0.notBefore, label: $0.label,
                    type: $0.type, code: $0.code, window: $0.window, resetsAt: $0.resetsAt,
                    text: Display.safe(Scrubber.scrubText($0.text), limit: 300))
            })
    }
}

public struct HistoryQuery: Sendable {
    public var label: String?
    public var since: String?
    public var limit: Int?

    public init(label: String? = nil, since: String? = nil, limit: Int? = nil) {
        self.label = label
        self.since = since
        self.limit = limit
    }
}

/// One reading in `history --json`.
public struct HistoryReadingOut: Encodable, Equatable, Sendable {
    public var at: Date
    public var source: String
    public var state: String
    public var weekly: HistoryWindow?
    public var fiveHour: HistoryWindow?
    public var fable: HistoryWindow?

    private enum CodingKeys: String, CodingKey {
        case at, source, state, weekly, fiveHour, fable
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(at, forKey: .at)
        try c.encode(source, forKey: .source)
        try c.encode(state, forKey: .state)
        try c.encodeNullable(weekly, forKey: .weekly)
        try c.encodeNullable(fiveHour, forKey: .fiveHour)
        try c.encodeNullable(fable, forKey: .fable)
    }
}

public struct HistoryAccountOut: Encodable, Equatable, Sendable {
    public var label: String
    public var readings: [HistoryReadingOut]
}

/// `history --json` (docs/ARCHITECTURE.md section 10.4).
public struct HistoryAnswer: Encodable, Equatable, Sendable {
    public var generatedAt: Date
    public var accounts: [HistoryAccountOut]

    private enum CodingKeys: String, CodingKey { case schemaVersion, generatedAt, accounts }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(1, forKey: .schemaVersion)
        try c.encode(generatedAt, forKey: .generatedAt)
        try c.encode(accounts, forKey: .accounts)
    }
}

extension ReadingHistory {
    /// The readings of every configured account (or one label), oldest first. `--limit` keeps the
    /// newest readings of each account. With retention 0 no line was kept, so the lists are empty.
    public func answer(_ query: HistoryQuery, config: Config?, now: Date = Date()) throws
        -> HistoryAnswer
    {
        let label = try QueryInput.label(query.label)
        let limit = try QueryInput.limit(query.limit, default: 500)
        var since = now.addingTimeInterval(-86_400)
        if let text = query.since { since = try QueryInput.time(text, now: now) }
        let onDisk = try self.labels()
        var labels = config?.accounts.map(\.label) ?? onDisk
        if let label {
            labels = labels.contains(label) || onDisk.contains(label) ? [label] : []
        }
        // A configured account's lines follow its key across every label it held, so a rename
        // keeps them and another account's lines under the same label never show.
        var byKey: [String: [(at: Date, order: Int, line: HistoryLine)]] = [:]
        var refused: [(label: String, error: Error)] = []
        if let config, labels.contains(where: { config.account($0) != nil }) {
            var order = 0
            for name in onDisk {
                let lines: [HistoryLine]
                do { lines = try read(label: name) } catch {
                    refused.append((name, error))
                    continue
                }
                for line in lines {
                    byKey[line.accountKey, default: []].append((line.at, order, line))
                    order += 1
                }
            }
        }
        var accounts: [HistoryAccountOut] = []
        for name in labels {
            let all: [HistoryLine]
            if let account = config?.account(name) {
                // An unread file may hide lines of its label's account or a renamed login one.
                if let failed = refused.first(where: {
                    $0.label == name || account.kind == Kind.login
                }) {
                    throw failed.error
                }
                all = (byKey[account.accountKey] ?? [])
                    .sorted { ($0.at, $0.order) < ($1.at, $1.order) }.map(\.line)
            } else {
                all = try read(label: name)
            }
            let lines = all.filter { $0.at >= since }
            accounts.append(
                HistoryAccountOut(
                    label: name,
                    readings: lines.suffix(limit).map {
                        HistoryReadingOut(
                            at: $0.at, source: $0.source, state: $0.state, weekly: $0.weekly,
                            fiveHour: $0.fiveHour, fable: $0.fable)
                    }))
        }
        return HistoryAnswer(generatedAt: now, accounts: accounts)
    }
}
