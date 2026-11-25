import Foundation
import Testing

@testable import Core

/// Every number in `config.json` has an upper bound, so a hand-edited value never reaches
/// arithmetic that cannot hold it, and the bounds are the ones docs/ARCHITECTURE.md 7.1 lists.
@Suite struct ConfigBoundsTests {
    /// Each numeric field by its path in `config.json`, an index for an array entry, with the
    /// name its refusal gives.
    static let fields: [(path: String, name: String)] = [
        ("schemaVersion", "schemaVersion"),
        ("probe.timeoutSeconds", "probe.timeoutSeconds"),
        ("refresh.backgroundMinutes", "refresh.backgroundMinutes"),
        ("fable.capPercentOfWeekly", "fable.capPercentOfWeekly"),
        ("fable.probeBudgetUsd", "fable.probeBudgetUsd"),
        ("fable.probeTimeoutSeconds", "fable.probeTimeoutSeconds"),
        ("fable.minRoomPercentOfCap", "fable.minRoomPercentOfCap"),
        ("fable.recheckAfterWeeklyRisePercent", "fable.recheckAfterWeeklyRisePercent"),
        ("picker.limitedAtPercent", "picker.limitedAtPercent"),
        ("picker.minRoomPercent", "picker.minRoomPercent"),
        ("picker.maxReadingAgeMinutes", "picker.maxReadingAgeMinutes"),
        ("picker.deadlineSeconds", "picker.deadlineSeconds"),
        ("picker.leaseMinutes", "picker.leaseMinutes"),
        ("picker.expectedRunPercent", "picker.expectedRunPercent"),
        ("picker.endingSoonAssumeDays", "picker.endingSoonAssumeDays"),
        ("launch.keepDays", "launch.keepDays"),
        ("history.retentionDays", "history.retentionDays"),
        ("accounts.0.reserve.points.0.daysLeft", "daysLeft"),
        ("accounts.0.reserve.points.0.maxUsedPercent", "maxUsedPercent"),
        ("accounts.0.reserve.marginPercent", "marginPercent"),
    ]

    /// A valid config with a main account that carries the standard reserve, as JSON objects.
    func validObject() throws -> [String: Any] {
        let main = Account(
            label: "main", kind: Kind.login, role: Role.main, email: "main@example.com",
            reserve: .standard)
        let data = try JSONEncoder().encode(Config(accounts: [main]))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// `value` with `path` set to `new`; a number in the path indexes an array.
    func setting(_ value: Any, _ path: ArraySlice<Substring>, to new: Any) -> Any {
        guard let key = path.first else { return new }
        if let index = Int(key), var list = value as? [Any], list.indices.contains(index) {
            list[index] = setting(list[index], path.dropFirst(), to: new)
            return list
        }
        var object = value as? [String: Any] ?? [:]
        object[String(key)] = setting(object[String(key)] ?? [:], path.dropFirst(), to: new)
        return object
    }

    /// The message `load()` refuses `object` with, or nil when it loads.
    func loadMessage(_ object: Any) throws -> String? {
        let t = try TestHome()
        let data = try JSONSerialization.data(withJSONObject: object)
        try NoFollowWriter(root: t.context.dataRoot).put(data, folders: [], name: "config.json")
        do {
            _ = try ConfigStore(context: t.context).load()
            return nil
        } catch let error as ToolError {
            return error.message
        }
    }

    @Test(arguments: fields.map(\.path))
    func theLargestIntInANumericFieldIsRefusedWithItsName(path: String) throws {
        let name = try #require(Self.fields.first { $0.path == path }?.name)
        let object = setting(
            try validObject(), path.split(separator: ".")[...], to: NSNumber(value: Int.max))
        let message = try #require(try loadMessage(object), "\(path) loaded")
        #expect(message.contains(name), "\(path): \(message)")
    }

    @Test func theListHoldsEveryNumericFieldOfAConfig() throws {
        func numbers(_ value: Any, _ path: String) -> [String] {
            if let object = value as? [String: Any] {
                return object.flatMap {
                    numbers($0.value, path.isEmpty ? $0.key : path + "." + $0.key)
                }
            }
            if let list = value as? [Any] {
                return list.isEmpty ? [] : numbers(list[0], path + ".0")
            }
            if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                return [path]
            }
            return []
        }
        let found = Set(numbers(try validObject(), ""))
        #expect(found == Set(Self.fields.map(\.path)))
    }

    /// A week for every span, the refresh interval's range in `config set`, a hundred years for
    /// every count of days, and 100 for every percent.
    @Test func eachBoundIsAcceptedAndOneMoreIsRefused() throws {
        let bounds: [(path: String, bound: Int)] = [
            ("refresh.backgroundMinutes", 10_080), ("picker.maxReadingAgeMinutes", 10_080),
            ("picker.leaseMinutes", 10_080), ("probe.timeoutSeconds", 604_800),
            ("fable.probeTimeoutSeconds", 604_800), ("picker.deadlineSeconds", 604_800),
            ("picker.endingSoonAssumeDays", 36_500), ("history.retentionDays", 36_500),
            ("launch.keepDays", 36_500), ("accounts.0.reserve.points.0.daysLeft", 36_500),
            ("fable.capPercentOfWeekly", 100), ("fable.minRoomPercentOfCap", 100),
            ("fable.recheckAfterWeeklyRisePercent", 100), ("picker.limitedAtPercent", 100),
            ("picker.minRoomPercent", 100), ("picker.expectedRunPercent", 100),
            ("accounts.0.reserve.points.0.maxUsedPercent", 100),
            ("accounts.0.reserve.marginPercent", 100),
        ]
        // A main account's reserve point above 90 percent needs allowAbove90.
        let valid = setting(
            try validObject(), "accounts.0.reserve.allowAbove90".split(separator: ".")[...],
            to: true)
        for (path, bound) in bounds {
            let keys = path.split(separator: ".")[...]
            let at = setting(valid, keys, to: NSNumber(value: bound))
            #expect(try loadMessage(at) == nil, "\(path) at \(bound)")
            let past = setting(valid, keys, to: NSNumber(value: bound + 1))
            let message = try loadMessage(past)
            #expect(message?.contains("to \(bound).") == true, "\(path): \(message ?? "loaded")")
        }
        for path in ["fable.capPercentOfWeekly", "picker.limitedAtPercent"] {
            let zero = setting(valid, path.split(separator: ".")[...], to: NSNumber(value: 0))
            let message = try loadMessage(zero)
            #expect(message?.contains("from 1 to 100.") == true, "\(path): \(message ?? "loaded")")
        }
    }

    @Test func aReservePointNamesTheAccountAndTheField() {
        let low = Reserve(
            points: [ReservePoint(daysLeft: -1, maxUsedPercent: 50)], marginPercent: 5)
        let account = Account(label: "pool-a", kind: Kind.token, role: Role.pool, reserve: low)
        #expect(
            throws: ToolError(
                "Account 'pool-a': a reserve point's daysLeft must be from 0 to 36500.")
        ) {
            try ConfigValidator.validate(Config(accounts: [account]))
        }
    }
}
