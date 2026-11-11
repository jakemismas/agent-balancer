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

    /// The lines that parse, oldest first, and whether the file needs its tail cut.
    static func parse(_ data: Data?) -> (lines: [HistoryLine], cutTail: Bool) {
        guard let data, !data.isEmpty else { return ([], false) }
        var parts = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        let tail = parts.removeLast()
        var cut = !tail.isEmpty
        var lines: [HistoryLine] = []
        let decoder = EventLog.decoder()
        for (index, part) in parts.enumerated() where !part.isEmpty {
            if let line = try? decoder.decode(HistoryLine.self, from: Data(part.utf8)),
                line.isSound
            {
                lines.append(line)
            } else if index == parts.count - 1 && tail.isEmpty {
                cut = true
            }
        }
        return (lines, cut)
    }

    /// Appends one line to a label's file. A last line that does not parse is cut off first.
    /// Returns true when it had to be cut.
    @discardableResult
    public func append(_ line: HistoryLine, label: String) throws -> Bool {
        guard ConfigValidator.isValidLabel(label) else { return false }
        let name = Self.fileName(label)
        let encoded = try EventLog.encoder().encode(line) + Data([0x0A])
        let data = try reader.read(folders: Self.folders, name: name, limit: Self.readLimit)
        let parsed = Self.parse(data)
        if parsed.cutTail {
            var whole = Data()
            for kept in parsed.lines { whole += try EventLog.encoder().encode(kept) + Data([0x0A]) }
            try writer.put(whole + encoded, folders: Self.folders, name: name)
            return true
        }
        try writer.append(encoded, folders: Self.folders, name: name)
        return false
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

    /// Drops lines older than `retentionDays` from every file. With 0 days every line goes.
    public func prune(retentionDays: Int, now: Date) throws {
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
        }
    }
}
