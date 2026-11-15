import Foundation
import Testing

/// Accepted residual: the launch file hands a token account's setup-token to the launched session
/// through settings `env`. That session exports it to its own subprocesses (shell tools, hooks,
/// status line, MCP servers), and a misbehaving session could print it into its own transcript.
/// The tool cannot scrub a session it does not run, and this suite checks only the tool's own
/// outputs and the two homes it writes. Whether Claude Code removes the variable from subprocess
/// environments was not measured.
///
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

struct LeakShapeError: Error, CustomStringConvertible {
    let description: String
}

/// The leak shapes as patterns, for files that hold no planted canary: the text chunks of the
/// README pictures and the scene sources they are drawn from. A hit names the shape, never the
/// text, so a real value never reaches a log.
enum LeakShapes {
    static let labels = ["main", "personal", "lab", "spare-a", "spare-b"]
    /// The paths the made-up accounts own, the made-up home and the app's two CLI paths.
    static let fixturePaths = Set(labels.map { "~/.agent-balancer/accounts/\($0)/.claude" })
        .union([
            "/Users/example", "/opt/homebrew/bin/agent-balancer", "/usr/local/bin/agent-balancer",
        ])
    static let picturePaths = ["menu", "manage-tokens", "manage-folders"].flatMap { scene in
        ["light", "dark"].map { "docs/media/\(scene)-\($0).png" }
    }
    static let sceneSources = [
        "Sources/AgentBalancerBar/ReadmeScenes.swift",
        "Sources/AgentBalancerBar/Manage/ManageScenes.swift",
        "Sources/AgentBalancerBar/RenderScenes.swift",
    ]

    static func matches(_ pattern: String, in text: String, caseless: Bool = false) -> [String] {
        guard
            let regex = try? NSRegularExpression(
                pattern: pattern, options: caseless ? [.caseInsensitive] : [])
        else { return ["unreadable pattern"] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: match.numberOfRanges - 1), in: text).map { String(text[$0]) }
        }
    }

    /// A run of 32 or more token characters with more than 4 bits of entropy per character.
    static func hasTokenLikeRun(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        func isRun(_ b: UInt8) -> Bool {
            (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 95
                || b == 45
        }
        var i = 0
        while i < bytes.count {
            guard isRun(bytes[i]) else {
                i += 1
                continue
            }
            var j = i
            while j < bytes.count && isRun(bytes[j]) { j += 1 }
            if j - i >= 32 {
                var counts = [Int](repeating: 0, count: 256)
                for b in bytes[i..<j] { counts[Int(b)] += 1 }
                let n = Double(j - i)
                let bits = counts.filter { $0 > 0 }.reduce(0.0) {
                    $0 - Double($1) / n * log2(Double($1) / n)
                }
                if bits > 4.0 { return true }
            }
            i = j
        }
        return false
    }

    /// The names of the leak shapes in `text`: a token or a token-like run, an org id or an org
    /// field, an address other than a made-up account's at example.com, a path the fixture does
    /// not own, and a session with a name.
    static func found(in text: String) -> [String] {
        var shapes: [String] = []
        if text.contains("sk-" + "ant-") { shapes.append("token") }
        if hasTokenLikeRun(text) { shapes.append("token-like run") }
        let orgId = #"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#
        if !matches(orgId, in: text, caseless: true).isEmpty { shapes.append("org id") }
        if !matches(#"\\?"(?:org|organization)[A-Za-z]*\\?"\s*:"#, in: text, caseless: true).isEmpty
        {
            shapes.append("org field")
        }
        // As in scripts/check-readme.sh, one leading hyphen before a made-up account is allowed.
        let addresses = matches(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+"#, in: text)
        if addresses.contains(where: { address in
            !labels.contains { label in
                ["", "-"].contains { address == $0 + label + "@example.com" }
            }
        }) {
            shapes.append("email")
        }
        // The path rule of scripts/check-readme.sh: an absolute path of two or more parts, also
        // right after a URL's scheme and host, and a home path (~/, ~user/ or $HOME/).
        let path =
            #"(?:(?<![A-Za-z0-9._~/-])|[A-Za-z][A-Za-z0-9+.-]*://[^/\s]*)"#
            + #"((?:~[A-Za-z0-9._-]*/|\$HOME/|/[A-Za-z0-9._-]+/)[A-Za-z0-9._-][^\s"'`),\\]*)"#
        let paths = matches(path, in: text)
        if paths.contains(where: { !fixturePaths.contains($0) }) { shapes.append("path") }
        let named = #"\\?"sessions\\?"\s*:\s*\[\s*[^\]\s]|\\?"name\\?"\s*:"#
        if !matches(named, in: text).isEmpty { shapes.append("session name") }
        return shapes
    }

    /// Inflates a zlib stream: a 2-byte header, raw DEFLATE data and a 4-byte checksum.
    /// Foundation reads the raw DEFLATE part.
    static func inflate(_ stream: ArraySlice<UInt8>) throws -> [UInt8] {
        guard stream.count > 6 else { throw LeakShapeError(description: "short compressed text") }
        let raw = Data(stream.dropFirst(2).dropLast(4))
        return [UInt8](try (raw as NSData).decompressed(using: .zlib) as Data)
    }

    /// A zlib stream of `bytes`, for planting compressed text.
    static func deflate(_ bytes: [UInt8]) throws -> [UInt8] {
        let raw = [UInt8](try (Data(bytes) as NSData).compressed(using: .zlib) as Data)
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in bytes {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        let sum = b << 16 | a
        return [0x78, 0x9C] + raw + [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: sum >> $0) }
    }

    /// The PNG `png` with one more chunk right after its signature and IHDR.
    static func png(_ png: Data, adding type: String, _ body: [UInt8]) -> Data {
        var chunk = Data(
            [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: UInt32(body.count) >> $0) })
        chunk.append(Data(type.utf8))
        chunk.append(Data(body))
        chunk.append(contentsOf: [0, 0, 0, 0])
        var out = png
        out.insert(contentsOf: chunk, at: out.startIndex + 33)
        return out
    }

    /// The text of every chunk of a PNG but its pixel data: compressed text read in full and any
    /// bytes after the end chunk. A file that is not a PNG, a chunk that runs past the end or
    /// compressed text that does not inflate throws, so a check over it fails closed.
    static func pngTexts(_ data: Data) throws -> [String] {
        let bytes = [UInt8](data)
        func text(_ part: ArraySlice<UInt8>) -> String { String(decoding: part, as: UTF8.self) }
        guard bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else {
            throw LeakShapeError(description: "not a PNG")
        }
        var texts: [String] = []
        var offset = 8
        while offset < bytes.count {
            guard offset + 12 <= bytes.count else {
                throw LeakShapeError(description: "a chunk is cut short")
            }
            let length = bytes[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
            let type = text(bytes[offset + 4..<offset + 8])
            let start = offset + 8
            guard start + length + 4 <= bytes.count else {
                throw LeakShapeError(description: "a chunk runs past the end")
            }
            let body = bytes[start..<start + length]
            offset = start + length + 4
            switch type {
            case "IDAT": continue
            case "IEND":
                texts.append(text(bytes[offset...]))
                return texts
            case "zTXt", "iCCP":
                let name = body.firstIndex(of: 0) ?? body.endIndex
                texts.append(text(body[..<name]))
                guard name + 2 <= body.endIndex else {
                    throw LeakShapeError(description: "\(type) is cut short")
                }
                texts.append(text(try inflate(body[(name + 2)...])[...]))
            case "iTXt":
                guard let name = body.firstIndex(of: 0), name + 3 <= body.endIndex,
                    let language = body[(name + 3)...].firstIndex(of: 0),
                    let translated = body[(language + 1)...].firstIndex(of: 0)
                else { throw LeakShapeError(description: "iTXt is cut short") }
                texts += [
                    body[..<name], body[(name + 3)..<language], body[(language + 1)..<translated],
                ]
                .map(text)
                let content = body[(translated + 1)...]
                texts.append(body[name + 1] == 1 ? text(try inflate(content)[...]) : text(content))
            default: texts.append(text(body))
            }
        }
        throw LeakShapeError(description: "no end chunk")
    }
}

extension LeakTests {
    /// Each shape fires on its canary, and on an org id planted in each kind of picture chunk,
    /// compressed text included. Each planted text fires its own shape and no other, so no shape
    /// is pinned only by another. An organization name has no shape to match; the documents carry
    /// no org field, which the org field shape checks. Token-shaped text is built here in pieces
    /// and never printed: a failure shows only shape names.
    @Test func theLeakShapesFireOnEveryCanaryAndInEveryPictureChunk() throws {
        for canary in Canary.all() where canary.name != "org-name" {
            #expect(
                !LeakShapes.found(in: "noise " + canary.value + " noise").isEmpty, "\(canary.name)")
        }
        // Forty different characters with no prefix: more than 4 bits each.
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let run = String(alphabet.shuffled().prefix(40))
        let planted = [
            ("a path outside the fixture", "/Vol" + "umes/Someone/Desktop/shot.png", "path"),
            ("a home path", "~/Desk" + "top/shot.png", "path"),
            ("a path in a file URL", "file://" + "/Users/" + "someone/Desktop/shot.png", "path"),
            ("a path in a file URL with a host", "file://host" + "/Vol" + "umes/x/y.png", "path"),
            ("a home path of another user", "~some" + "one/Desktop/shot.png", "path"),
            ("a path in a URL with another scheme", "smb://host" + "/share/some" + "one/x", "path"),
            ("a home path written with $HOME", "$HO" + "ME/Desktop/shot.png", "path"),
            ("an address with an upper-case domain", "someone@" + "EXAMPLE.ORG", "email"),
            ("a made-up address with two leading hyphens", "--lab@" + "example.com", "email"),
            ("a hyphen before no made-up account", "-x@" + "example.com", "email"),
            ("a token-like run with no prefix", run, "token-like run"),
            ("a token prefix with no run", "sk-" + "ant-" + "x", "token"),
            (
                "a named session", "\"sessions\": [ { \"id\": \"abcd1234\", \"name\": \"x\" } ]",
                "session name"
            ),
            ("an org field", "\"org" + "Name\": \"x\"", "org field"),
        ]
        for (what, text, shape) in planted {
            let shapes = LeakShapes.found(in: "noise " + text + " noise")
            #expect(shapes == [shape], "\(what): \(shapes)")
        }
        for clean in [
            "lab@example.com", "-lab@example.com", "~/.agent-balancer/accounts/lab/.claude",
            "\"sessions\": []", String(repeating: "ab", count: 20), "https://example.com",
        ] {
            #expect(LeakShapes.found(in: clean).isEmpty, "\(clean)")
        }

        let png = try Data(
            contentsOf: Support.root.appendingPathComponent("docs/media/menu-light.png"))
        #expect(try LeakShapes.pngTexts(png).flatMap { LeakShapes.found(in: $0) }.isEmpty)
        let orgId = Array(("org " + UUID().uuidString.lowercased()).utf8)
        let key = Array("Comment".utf8) + [0]
        let plants: [(String, Data)] = [
            ("tEXt", LeakShapes.png(png, adding: "tEXt", key + orgId)),
            (
                "zTXt",
                LeakShapes.png(png, adding: "zTXt", key + [0] + (try LeakShapes.deflate(orgId)))
            ),
            ("iTXt", LeakShapes.png(png, adding: "iTXt", key + [0, 0, 0, 0] + orgId)),
            (
                "compressed iTXt",
                LeakShapes.png(
                    png, adding: "iTXt", key + [1, 0, 0, 0] + (try LeakShapes.deflate(orgId)))
            ),
            (
                "iCCP",
                LeakShapes.png(png, adding: "iCCP", key + [0] + (try LeakShapes.deflate(orgId)))
            ),
            ("another chunk", LeakShapes.png(png, adding: "prVt", orgId)),
            ("bytes after the end", png + Data(orgId)),
        ]
        for (what, data) in plants {
            let shapes = try LeakShapes.pngTexts(data).flatMap { LeakShapes.found(in: $0) }
            #expect(shapes.contains("org id"), "\(what)")
        }
    }

    /// The leak test's shapes over every text chunk of the README pictures and over the scene
    /// sources they are drawn from.
    @Test func theReadmePicturesAndTheirSceneSourcesHoldNoLeakShape() throws {
        let media = Support.root.appendingPathComponent("docs/media")
        let pictures = try FileManager.default.contentsOfDirectory(atPath: media.path)
            .filter { $0.hasSuffix(".png") }.map { "docs/media/" + $0 }.sorted()
        #expect(Set(pictures).isSuperset(of: LeakShapes.picturePaths))
        for picture in pictures {
            let data = try Data(contentsOf: Support.root.appendingPathComponent(picture))
            let shapes = try LeakShapes.pngTexts(data).flatMap { LeakShapes.found(in: $0) }
            #expect(shapes.isEmpty, "\(picture): \(shapes)")
        }
        for source in LeakShapes.sceneSources {
            let text = try String(
                contentsOf: Support.root.appendingPathComponent(source), encoding: .utf8)
            let shapes = LeakShapes.found(in: text)
            #expect(shapes.isEmpty, "\(source): \(shapes)")
        }
    }
}
