import Foundation

/// The reading cache: one file per account under `state/readings/`, merged by the rule of
/// docs/ARCHITECTURE.md section 6.3. Callers hold the account's lock while they record.
public struct ReadingStore: Sendable {
    public let context: ToolContext
    private let reader: NoFollowReader
    private let writer: NoFollowWriter

    /// Called once after each probe of a token account that gave a reading. It does nothing in
    /// this version; the duplicate check of section 4A.4 fills it in.
    public var afterProbe: @Sendable (_ label: String, _ reading: Reading) -> Void = { _, _ in }

    public init(context: ToolContext) {
        self.context = context
        self.reader = NoFollowReader(root: context.dataRoot)
        self.writer = NoFollowWriter(root: context.dataRoot)
    }

    /// The saved reading, or nil when there is none or the file does not decode. Nil is the
    /// fail-safe: the account then shows no reading and the next good probe writes a new file. A
    /// reset time that does not decode reads as unknown, and a window with a use outside 0 to 100
    /// is dropped, so one bad value never erases the rest.
    public func load(label: String) throws -> Reading? {
        guard
            let data = try reader.read(
                folders: Layout.readingsFolders, name: Layout.readingName(label))
        else { return nil }
        return (try? Reading.decoder().decode(Reading.self, from: data))?.sanitized()
    }

    public func save(_ reading: Reading, label: String) throws {
        let data = try Reading.encoder().encode(reading) + Data([0x0A])
        try writer.put(data, folders: Layout.readingsFolders, name: Layout.readingName(label))
    }

    /// Merges a probe reading into the stored one and saves it. `callsHook` is true for a token
    /// account.
    @discardableResult
    public func record(
        _ incoming: Reading, label: String, callsHook: Bool, fable: FableSettings, now: Date
    ) throws -> Reading {
        let merged = ReadingMerge.merge(
            stored: try load(label: label), incoming: incoming, fableSettings: fable, now: now)
        try save(merged, label: label)
        if callsHook { afterProbe(label, merged) }
        return merged
    }

    /// Notes that a Fable probe was tried now, so the once-a-day limit holds when it fails.
    public func noteFableAttempt(label: String, at time: Date) throws {
        guard var stored = try load(label: label) else { return }
        stored.fableProbedAt = time
        try save(stored, label: label)
    }
}
