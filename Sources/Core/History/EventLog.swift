import Foundation

/// The eight event types of docs/ARCHITECTURE.md section 10.3.
public enum EventType {
    public static let limited = "limited"
    public static let limitCleared = "limit_cleared"
    public static let error = "error"
    public static let recovered = "recovered"
    public static let loginExpiring = "login_expiring"
    public static let accountAdded = "account_added"
    public static let accountRemoved = "account_removed"
    public static let tokenReplaced = "token_replaced"
}

/// One event before it gets its number.
public struct EventDraft: Equatable, Sendable {
    public var label: String
    public var accountKey: String
    public var type: String
    public var code: String?
    public var window: String?
    public var resetsAt: Date?
    public var notBefore: Date?
    public var text: String
}

/// One line of `state/events.jsonl`. It holds labels, times, states and scrubbed texts only.
public struct EventRecord: Codable, Equatable, Sendable {
    public var seq: Int
    public var at: Date
    public var notBefore: Date?
    public var label: String
    public var accountKey: String
    public var type: String
    public var code: String?
    public var window: String?
    public var resetsAt: Date?
    public var text: String
}

extension EventRecord {
    static let maxSeq = 1_000_000_000_000

    /// Whether every value that reaches a terminal or the events JSON has a shape the tool writes.
    /// A `seq` this large could only come from editing, and would trap later arithmetic.
    var isSound: Bool {
        seq > 0 && seq < Self.maxSeq && ConfigValidator.isValidLabel(label)
            && [
                EventType.limited, EventType.limitCleared, EventType.error, EventType.recovered,
                EventType.loginExpiring, EventType.accountAdded, EventType.accountRemoved,
                EventType.tokenReplaced,
            ].contains(type)
            && (code.map { StateCode(rawValue: $0) != nil } ?? true)
            && (window.map(CurrentFile.windowNames.contains) ?? true)
    }
}

struct EventHeader: Codable {
    var header: Bool
    var recordId: String
    var createdAt: Date

    /// The shape `EventLog` writes: `r-` and six lowercase hex digits.
    static func isValidRecordId(_ id: String) -> Bool {
        id.range(of: #"\Ar-[0-9a-f]{6}\z"#, options: .regularExpression) != nil
    }
}

/// `state/events.jsonl`: a header line with the record id, then one numbered line per event. The
/// status rebuild is the only writer and holds `locks/history.lock` while it writes.
public struct EventLog: Sendable {
    public static let fileName = "events.jsonl"
    static let readLimit = 33_554_432

    public let context: ToolContext
    private let reader: NoFollowReader
    private let writer: NoFollowWriter

    public init(context: ToolContext) {
        self.context = context
        self.reader = NoFollowReader(root: context.dataRoot)
        self.writer = NoFollowWriter(root: context.dataRoot)
    }

    /// What one pass over the file found.
    public struct Parsed: Equatable, Sendable {
        public var recordId: String?
        public var createdAt: Date?
        public var events: [EventRecord] = []
        /// The last line does not parse, or the file does not end in a newline.
        public var cutTail = false
        /// A line in the middle does not parse, a number does not rise, or the header is missing.
        public var damaged = false
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func parse(_ data: Data?) -> Parsed {
        var out = Parsed()
        guard let data, !data.isEmpty else { return out }
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.components(separatedBy: "\n")
        let last = lines.removeLast()
        if !last.isEmpty { out.cutTail = true }
        var all = lines
        if !last.isEmpty { all.append(last) }
        var lastSeq = 0
        let decoder = Self.decoder()
        for (index, line) in all.enumerated() where !line.isEmpty {
            let isLast = index == all.count - 1
            let bytes = Data(line.utf8)
            // A header with an id of another shape is handled like one that does not parse.
            if out.recordId == nil, out.events.isEmpty,
                let header = try? decoder.decode(EventHeader.self, from: bytes), header.header,
                EventHeader.isValidRecordId(header.recordId)
            {
                out.recordId = header.recordId
                out.createdAt = header.createdAt
                continue
            }
            if let event = try? decoder.decode(EventRecord.self, from: bytes), event.isSound,
                event.seq > lastSeq
            {
                out.events.append(event)
                lastSeq = event.seq
                continue
            }
            // An unparseable last line is cut off; anywhere else it marks the file damaged.
            if isLast { out.cutTail = true } else { out.damaged = true }
        }
        if out.recordId == nil && !out.events.isEmpty { out.damaged = true }
        return out
    }

    /// The record as saved, for `events`. A file that is missing reads as an empty, unnamed record.
    public func read() throws -> Parsed {
        Self.parse(
            try reader.read(
                folders: Layout.stateFolders, name: Self.fileName, limit: Self.readLimit))
    }

    private func line(_ value: some Encodable) throws -> Data {
        try Self.encoder().encode(value) + Data([0x0A])
    }

    private func newRecordId() -> String { "r-" + Paths.randomHex(3) }

    private func header(now: Date) throws -> Data {
        try line(EventHeader(header: true, recordId: newRecordId(), createdAt: now))
    }

    private func body(_ parsed: Parsed) throws -> Data {
        var data = Data()
        if let id = parsed.recordId {
            data += try line(
                EventHeader(header: true, recordId: id, createdAt: parsed.createdAt ?? Date()))
        }
        for event in parsed.events { data += try line(event) }
        return data
    }

    /// Writes the header when the file does not exist yet. Cheap: one `lstat`.
    public func ensureExists(now: Date) throws {
        if try writer.info(folders: Layout.stateFolders, name: Self.fileName) != nil { return }
        try writer.put(try header(now: now), folders: Layout.stateFolders, name: Self.fileName)
    }

    /// Numbers the drafts and appends them. A damaged file is set aside and a new record, with a
    /// new id, starts at 1. A last line that does not parse is cut off first. The caller holds the
    /// history lock. Returns what was cut or set aside, for the log.
    @discardableResult
    public func append(_ drafts: [EventDraft], now: Date) throws -> [String] {
        guard !drafts.isEmpty else {
            try ensureExists(now: now)
            return []
        }
        var notes: [String] = []
        let data = try reader.read(
            folders: Layout.stateFolders, name: Self.fileName, limit: Self.readLimit)
        var parsed = Self.parse(data)
        var rewrite = false
        if data != nil && (parsed.damaged || parsed.recordId == nil) {
            let stamp = String(Int(now.timeIntervalSince1970))
            try writer.put(
                data ?? Data(), folders: Layout.stateFolders,
                name: "events-damaged-\(stamp)-\(Paths.randomHex(2)).jsonl")
            parsed = Parsed(recordId: newRecordId(), createdAt: now)
            rewrite = true
            notes.append("events record was damaged and set aside")
        } else if data == nil {
            parsed = Parsed(recordId: newRecordId(), createdAt: now)
            rewrite = true
        } else if parsed.cutTail {
            rewrite = true
            notes.append("cut a last events line that did not parse")
        }
        var seq = parsed.events.last?.seq ?? 0
        var added = Data()
        var fresh: [EventRecord] = []
        for draft in drafts {
            seq += 1
            let record = EventRecord(
                seq: seq, at: now, notBefore: draft.notBefore, label: draft.label,
                accountKey: draft.accountKey, type: draft.type, code: draft.code,
                window: draft.window, resetsAt: draft.resetsAt, text: draft.text)
            fresh.append(record)
            added += try line(record)
        }
        if rewrite {
            parsed.events += fresh
            try writer.put(try body(parsed), folders: Layout.stateFolders, name: Self.fileName)
        } else {
            try writer.append(added, folders: Layout.stateFolders, name: Self.fileName)
        }
        return notes
    }

    /// Drops lines older than `retentionDays`, except the newest line of each label. With 0 days
    /// only each label's newest line stays. Returns true when the file changed.
    @discardableResult
    public func prune(retentionDays: Int, now: Date) throws -> Bool {
        guard
            let data = try reader.read(
                folders: Layout.stateFolders, name: Self.fileName, limit: Self.readLimit)
        else { return false }
        var parsed = Self.parse(data)
        guard !parsed.damaged, parsed.recordId != nil else { return false }
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        var newest: [String: Int] = [:]
        for event in parsed.events { newest[event.label] = event.seq }
        let kept = parsed.events.filter {
            retentionDays > 0 && $0.at >= cutoff || newest[$0.label] == $0.seq
        }
        guard kept.count != parsed.events.count else { return false }
        parsed.events = kept
        try writer.put(try body(parsed), folders: Layout.stateFolders, name: Self.fileName)
        return true
    }
}
