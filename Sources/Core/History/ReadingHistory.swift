import Foundation

/// One window of a history line.
public struct HistoryWindow: Codable, Equatable, Sendable {
    public var usedPercent: Double?
    public var resetsAt: Date?

    private enum CodingKeys: String, CodingKey { case usedPercent, resetsAt }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeNullable(usedPercent, forKey: .usedPercent)
        try c.encodeNullable(resetsAt, forKey: .resetsAt)
    }
}

/// One line of `state/history/<label>.jsonl` (docs/ARCHITECTURE.md section 10.4).
public struct HistoryLine: Codable, Equatable, Sendable {
    public var accountKey: String
    public var at: Date
    public var source: String
    public var state: String
    public var weekly: HistoryWindow?
    public var fiveHour: HistoryWindow?
    public var fable: HistoryWindow?

    private enum CodingKeys: String, CodingKey {
        case accountKey, at, source, state, weekly, fiveHour, fable
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(accountKey, forKey: .accountKey)
        try c.encode(at, forKey: .at)
        try c.encode(source, forKey: .source)
        try c.encode(state, forKey: .state)
        try c.encodeNullable(weekly, forKey: .weekly)
        try c.encodeNullable(fiveHour, forKey: .fiveHour)
        try c.encodeNullable(fable, forKey: .fable)
    }

    /// A line whose state or source is not one the tool writes is skipped like an unparseable one.
    var isSound: Bool {
        CurrentFile.stateNames.contains(state)
            && (source == ReadingSource.probe || source == ReadingSource.estimate)
    }

    /// What decides whether a reading is a new line: the numbers, the reset times and the state.
    var signature: String {
        func part(_ w: HistoryWindow?) -> String {
            guard let w else { return "-" }
            let used = w.usedPercent.map { String($0) } ?? "-"
            let reset = w.resetsAt.map { String(Int($0.timeIntervalSince1970 / 60)) } ?? "-"
            return used + "@" + reset
        }
        return [state, source, part(weekly), part(fiveHour), part(fable)].joined(separator: "|")
    }
}

/// What one `ReadingHistory.append` did.
public struct HistoryAppend: Equatable, Sendable {
    /// False when the file's last line already held this reading for the same account: the same
    /// numbers, reset times, state and source.
    public var wrote: Bool
    /// Lines that did not parse, dropped because the file had to be rewritten.
    public var dropped: Int
}

/// The readings over time. The status rebuild is the only writer and holds the history lock.
public struct ReadingHistory: Sendable {
    /// At least this long between two lines of one account unless its state changed.
    public static let minimumGap: TimeInterval = 900
    static let folders = ["state", "history"]
    static let readLimit = 33_554_432

    public let context: ToolContext
    private let reader: NoFollowReader
    private let writer: NoFollowWriter

    public init(context: ToolContext) {
        self.context = context
        self.reader = NoFollowReader(root: context.dataRoot)
        self.writer = NoFollowWriter(root: context.dataRoot)
    }

    static func fileName(_ label: String) -> String { label + ".jsonl" }

    /// The lines that parse, oldest first; whether the file needs a rewrite because its last line
    /// does not parse or does not end in a newline; and how many lines do not parse.
    static func parse(_ data: Data?) -> (lines: [HistoryLine], cutTail: Bool, unreadable: Int) {
        guard let data, !data.isEmpty else { return ([], false, 0) }
        var parts = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        let tail = parts.removeLast()
        var cut = !tail.isEmpty
        if !tail.isEmpty { parts.append(tail) }
        var lines: [HistoryLine] = []
        var unreadable = 0
        let decoder = EventLog.decoder()
        for (index, part) in parts.enumerated() where !part.isEmpty {
            if let line = try? decoder.decode(HistoryLine.self, from: Data(part.utf8)),
                line.isSound
            {
                lines.append(line)
            } else {
                unreadable += 1
                if index == parts.count - 1 { cut = true }
            }
        }
        return (lines, cut, unreadable)
    }

    /// Appends one line to a label's file, unless the file's last line already holds the same
    /// reading for the same account, so a rebuild that runs again after a failed step never
    /// writes a line twice. A last line that does not parse is cut off first: the file is
    /// rewritten with the lines that parse, and the result counts the lines that did not.
    @discardableResult
    public func append(_ line: HistoryLine, label: String) throws -> HistoryAppend {
        guard ConfigValidator.isValidLabel(label) else {
            return HistoryAppend(wrote: false, dropped: 0)
        }
        let name = Self.fileName(label)
        let data = try reader.read(folders: Self.folders, name: name, limit: Self.readLimit)
        let parsed = Self.parse(data)
        let repeated =
            parsed.lines.last.map {
                $0.accountKey == line.accountKey && $0.signature == line.signature
            } ?? false
        let encoded = repeated ? Data() : try EventLog.encoder().encode(line) + Data([0x0A])
        if parsed.cutTail {
            var whole = Data()
            for kept in parsed.lines { whole += try EventLog.encoder().encode(kept) + Data([0x0A]) }
            try writer.put(whole + encoded, folders: Self.folders, name: name)
            return HistoryAppend(wrote: !repeated, dropped: parsed.unreadable)
        }
        if !repeated { try writer.append(encoded, folders: Self.folders, name: name) }
        return HistoryAppend(wrote: !repeated, dropped: 0)
    }

    /// The saved lines of one label, oldest first. A missing file is an empty list.
    public func read(label: String) throws -> [HistoryLine] {
        guard ConfigValidator.isValidLabel(label) else { return [] }
        return Self.parse(
            try reader.read(
                folders: Self.folders, name: Self.fileName(label), limit: Self.readLimit)
        ).lines
    }

    /// The labels that have a history file.
    public func labels() throws -> [String] {
        try writer.listNames(folders: Self.folders).compactMap { name in
            guard name.hasSuffix(".jsonl") else { return nil }
            let label = String(name.dropLast(6))
            return ConfigValidator.isValidLabel(label) ? label : nil
        }
    }

    /// Drops lines older than `retentionDays` before `now` from every file, so every label,
    /// a removed one included, ages out on one clock. The caller picks `now`: the rebuild passes
    /// the earlier of its clock and its newest stored reading with a five-hour or weekly reset
    /// time at most 270 seconds before that reading's own time, or its clock with 0 days, when
    /// every line goes. A rewrite also drops the lines that do not parse, and `dropped` hears
    /// how many, per label, as soon as that file is written.
    public func prune(
        retentionDays: Int, now: Date,
        dropped: (_ label: String, _ count: Int) -> Void = { _, _ in }
    ) throws {
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        for label in try labels() {
            let name = Self.fileName(label)
            guard
                let data = try reader.read(folders: Self.folders, name: name, limit: Self.readLimit)
            else { continue }
            let parsed = Self.parse(data)
            let kept = retentionDays > 0 ? parsed.lines.filter { $0.at >= cutoff } : []
            guard kept.count != parsed.lines.count || parsed.cutTail else { continue }
            var whole = Data()
            for line in kept { whole += try EventLog.encoder().encode(line) + Data([0x0A]) }
            try writer.put(whole, folders: Self.folders, name: name)
            if parsed.unreadable > 0 { dropped(label, parsed.unreadable) }
        }
    }
}
