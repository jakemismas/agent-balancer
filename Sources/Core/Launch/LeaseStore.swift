import Foundation

/// One open pick: an internal id, the label, the model and the time.
public struct Lease: Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var model: String
    public var at: Date

    public init(id: String, label: String, model: String, at: Date) {
        self.id = id
        self.label = label
        self.model = model
        self.at = at
    }
}

struct LeaseFile: Codable {
    var schemaVersion: Int
    var leases: [Lease]
}

/// `state/leases.json`. Callers hold `locks/pick.lock` while they load and save.
public struct LeaseStore: Sendable {
    public let context: ToolContext
    private let reader: NoFollowReader
    private let writer: NoFollowWriter

    public init(context: ToolContext) {
        self.context = context
        self.reader = NoFollowReader(root: context.dataRoot)
        self.writer = NoFollowWriter(root: context.dataRoot)
    }

    /// The open leases: those younger than `leaseMinutes`, with any dated in the future dropped.
    /// A file that does not decode reads as no leases.
    public func current(now: Date, leaseMinutes: Int) throws -> [Lease] {
        guard let data = try reader.read(folders: Layout.stateFolders, name: Layout.leasesName),
            let file = try? Reading.decoder().decode(LeaseFile.self, from: data)
        else { return [] }
        return Self.openOnes(file.leases, now: now, leaseMinutes: leaseMinutes)
    }

    /// The open leases as `current` reads them, or nil when the lease file is there but cannot be
    /// read, does not decode or has another schema version. `uninstall` then keeps every launch
    /// file, since it cannot tell which leases are open.
    public func currentIfReadable(now: Date, leaseMinutes: Int) -> [Lease]? {
        let data: Data?
        do {
            data = try reader.read(folders: Layout.stateFolders, name: Layout.leasesName)
        } catch {
            return nil
        }
        guard let data else { return [] }
        guard let file = try? Reading.decoder().decode(LeaseFile.self, from: data),
            file.schemaVersion == 1
        else { return nil }
        return Self.openOnes(file.leases, now: now, leaseMinutes: leaseMinutes)
    }

    private static func openOnes(_ leases: [Lease], now: Date, leaseMinutes: Int) -> [Lease] {
        let span = Double(leaseMinutes) * 60
        return leases.filter {
            $0.at <= now && now.timeIntervalSince($0.at) < span
                && ConfigValidator.isValidLabel($0.label)
        }
    }

    public func save(_ leases: [Lease]) throws {
        let file = LeaseFile(schemaVersion: 1, leases: leases)
        let data = try Reading.encoder().encode(file) + Data([0x0A])
        try writer.put(data, folders: Layout.stateFolders, name: Layout.leasesName)
    }

    /// Open leases per label.
    public static func counts(_ leases: [Lease]) -> [String: Int] {
        var out: [String: Int] = [:]
        for lease in leases { out[lease.label, default: 0] += 1 }
        return out
    }
}
