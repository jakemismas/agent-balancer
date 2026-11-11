import Foundation
import Testing

/// Canaries are built at runtime from split strings so no whole token, email or id is stored.
struct Canary: Sendable {
    let name: String
    let value: String

    static func randomTail(_ count: Int = 24) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<count).map { _ in alphabet.randomElement()! })
    }

    /// A setup-token in the shape recorded for a real one: 108 characters, the prefix, then upper,
    /// lower, digit and dash.
    static func realShapeToken() -> String {
        "sk-" + "ant-" + "oat01-" + "Aa0" + randomTail(27) + "-" + randomTail(30) + "-"
            + randomTail(33)
    }

    static func all() -> [Canary] {
        [
            Canary(name: "oauth-token", value: "sk-" + "ant-" + "oat01-" + randomTail(40)),
            Canary(name: "api-key", value: "sk-" + "ant-" + "api03-" + randomTail(40)),
            Canary(
                name: "email",
                value: "pat." + randomTail(6).lowercased() + "@" + "contoso" + ".test"),
            Canary(name: "org-id", value: UUID().uuidString.lowercased()),
            Canary(name: "org-name", value: "Northwind " + randomTail(6) + " Traders"),
            Canary(
                name: "home-path", value: "/Users/" + "pat" + randomTail(4).lowercased() + "/work"),
            Canary(name: "oauth-token-real-shape", value: realShapeToken()),
        ]
    }
}

/// Where a later slice plants a canary. Each case is one input the tool reads.
enum Channel: String, CaseIterable, Sendable {
    case fakeClaudeStdout
    case fakeClaudeStderr
    case authStatusExtraField
    case probeResultErrorText
    case settingsEnvValue
    case parentEnvironment
    case tokenFileValue
    case setupTokenOutput
    case pastedToken
    case callerSettingsJSON
}

/// Everything a run is given: environment, files under the home folder, and fake-claude behavior.
struct PlantedInputs {
    var env: [String: String] = [:]
    var files: [String: String] = [:]
    var fakeClaudeStdout = ""
    var fakeClaudeStderr = ""
    var pastedInput = ""

    /// Plants one canary in one channel. Paths are relative to the home folder.
    mutating func plant(_ canary: Canary, in channel: Channel) {
        let v = canary.value
        switch channel {
        case .fakeClaudeStdout: fakeClaudeStdout += "noise \(v) noise\n"
        case .fakeClaudeStderr: fakeClaudeStderr += "noise \(v) noise\n"
        case .authStatusExtraField:
            fakeClaudeStdout += "{\"loggedIn\":true,\"extra\":\"\(v)\"}\n"
        case .probeResultErrorText:
            fakeClaudeStdout += "{\"is_error\":true,\"result\":\"failed for \(v)\"}\n"
        case .settingsEnvValue:
            files["." + "cla" + "ude/set" + "tings.json"] = "{\"env\":{\"AB_PLANTED\":\"\(v)\"}}"
        case .parentEnvironment: env["AB_PLANTED"] = v
        case .tokenFileValue: files[".agent-balancer/" + "tok" + "ens/planted"] = v
        case .setupTokenOutput: fakeClaudeStdout += "Your token is \(v)\n"
        case .pastedToken: pastedInput = v + "\n"
        case .callerSettingsJSON: files["caller-settings.json"] = "{\"env\":{\"K\":\"\(v)\"}}"
        }
    }

    /// Plants every canary in every channel, one pair at a time, yielding each combination.
    static func everyCombination(canaries: [Canary] = Canary.all()) -> [(Canary, Channel, Self)] {
        var out: [(Canary, Channel, Self)] = []
        for canary in canaries {
            for channel in Channel.allCases {
                var inputs = Self()
                inputs.plant(canary, in: channel)
                out.append((canary, channel, inputs))
            }
        }
        return out
    }

    /// Writes the planted files under `home` and returns the environment to run with.
    func materialize(home: URL, base: [String: String]) throws -> [String: String] {
        for (rel, body) in files {
            let url = home.appendingPathComponent(rel)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: url, atomically: true, encoding: .utf8)
        }
        return base.merging(env) { _, new in new }
    }
}

/// Finds canaries in a byte stream, including one split across two reads.
struct LeakDetector {
    private let needles: [Data]
    private var carry = Data()

    init(canaries: [Canary]) {
        needles = canaries.map { Data($0.value.utf8) }
    }

    /// Feeds one read. Returns true when any canary is now fully present.
    mutating func feed(_ chunk: Data) -> Bool {
        let window = carry + chunk
        let longest = needles.map(\.count).max() ?? 0
        carry = window.suffix(max(longest - 1, 0))
        return needles.contains { window.range(of: $0) != nil }
    }

    static func contains(_ data: Data, canaries: [Canary]) -> Bool {
        var detector = LeakDetector(canaries: canaries)
        return detector.feed(data)
    }
}

/// Collects every byte a run produced: stdout, stderr and every file under the home folder.
struct Collected {
    var streams: [String: Data] = [:]

    mutating func addFiles(under home: URL) throws {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard
            let walker = FileManager.default.enumerator(
                at: home, includingPropertiesForKeys: keys)
        else { return }
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isRegularFile == true {
                streams[url.path] = try Data(contentsOf: url)
            }
        }
    }

    /// Streams that hold a canary. `allowed` names path fragments a canary may legitimately sit in
    /// (a token file and that label's launch files, for the token canary only).
    func leaks(of canaries: [Canary], allowedPathFragments: [String] = []) -> [String] {
        streams.compactMap { key, data in
            if allowedPathFragments.contains(where: { key.contains($0) }) { return nil }
            return LeakDetector.contains(data, canaries: canaries) ? key : nil
        }.sorted()
    }

    /// Streams that hold a canary, apart from those whose key matches one of `allowedPathPatterns`,
    /// regular expressions on the whole key.
    func leaks(of canaries: [Canary], allowedPathPatterns: [String]) -> [String] {
        streams.compactMap { key, data in
            let allowed = allowedPathPatterns.contains {
                key.range(of: $0, options: .regularExpression) != nil
            }
            if allowed { return nil }
            return LeakDetector.contains(data, canaries: canaries) ? key : nil
        }.sorted()
    }
}

@Suite struct LeakTests {
    @Test func positiveControlFiresOnEveryShape() {
        for canary in Canary.all() {
            let data = Data(("noise " + canary.value + " noise").utf8)
            #expect(LeakDetector.contains(data, canaries: [canary]), "missed \(canary.name)")
        }
    }

    @Test func detectorStaysQuietOnCleanText() {
        let data = Data("agent-balancer 0.1.0 and nothing else".utf8)
        #expect(!LeakDetector.contains(data, canaries: Canary.all()))
    }

    @Test func canarySplitAcrossTwoReadsIsCaught() {
        for canary in Canary.all() {
            let bytes = Data(canary.value.utf8)
            let filler = Data(repeating: UInt8(ascii: "."), count: 4096 - bytes.count / 2)
            let stream = filler + bytes
            let first = stream.prefix(4096)
            let second = stream.dropFirst(4096)
            var detector = LeakDetector(canaries: [canary])
            let seenInFirst = detector.feed(Data(first))
            let seenInSecond = detector.feed(Data(second))
            #expect(!seenInFirst, "\(canary.name) split should not show in the first read")
            #expect(seenInSecond, "\(canary.name) split across reads was missed")
        }
    }

    @Test func everyPlantingChannelIsListed() {
        #expect(Channel.allCases.count == 10)
    }

    @Test func everyCanaryPlantsInEveryChannel() {
        let combos = PlantedInputs.everyCombination()
        #expect(combos.count == Canary.all().count * Channel.allCases.count)
        for (canary, channel, inputs) in combos {
            let planted =
                inputs.env.values.joined() + inputs.files.values.joined()
                + inputs.fakeClaudeStdout + inputs.fakeClaudeStderr + inputs.pastedInput
            #expect(planted.contains(canary.value), "\(canary.name) not planted in \(channel)")
        }
    }

    @Test func versionRunLeaksNoCanaryFromAnyPlantedInput() throws {
        let exe = try #require(Support.builtBinary(), "build the package before running tests")
        // One set of canaries, so the scan looks for exactly the values that were planted.
        let canaries = Canary.all()
        for (_, channel, inputs) in PlantedInputs.everyCombination(canaries: canaries) {
            let home = try Support.makeTempDir()
            defer { try? FileManager.default.removeItem(at: home) }
            let env = try inputs.materialize(
                home: home, base: ["HOME": home.path, "PATH": "/usr/bin:/bin"])
            let result = try Support.run(exe, ["--version"], env: env)
            var collected = Collected()
            collected.streams["stdout"] = result.stdout
            collected.streams["stderr"] = result.stderr
            try collected.addFiles(under: home)
            // Planted files are inputs; the run must not copy a canary anywhere else.
            let allowed = Array(inputs.files.keys)
            #expect(result.status == 0, "channel \(channel)")
            #expect(
                collected.leaks(of: canaries, allowedPathFragments: allowed).isEmpty,
                "leak with \(channel)")
        }
    }

    @Test func versionRunLeaksNoCanary() throws {
        let exe = try #require(Support.builtBinary(), "build the package before running tests")
        let home = try Support.makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let canaries = Canary.all()

        // The parent environment is the one channel that exists in slice 0: plant every canary.
        var env = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        for (index, canary) in canaries.enumerated() { env["AB_CANARY_\(index)"] = canary.value }

        let result = try Support.run(exe, ["--version"], env: env)
        var collected = Collected()
        collected.streams["stdout"] = result.stdout
        collected.streams["stderr"] = result.stderr
        try collected.addFiles(under: home)

        #expect(result.status == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self).contains("0.1.0"))
        #expect(collected.leaks(of: canaries).isEmpty)
    }
}
