import Foundation

/// Paths and process helpers the CLI tests share.
enum Support {
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func builtBinary() -> URL? {
        for config in ["debug", "release"] {
            let url = root.appendingPathComponent(".build/\(config)/agent-balancer")
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    struct Output {
        var status: Int32
        var stdout: Data
        var stderr: Data
    }

    static func run(
        _ exe: URL, _ args: [String], env: [String: String], stdin: Data? = nil
    ) throws -> Output {
        let task = Process()
        task.executableURL = exe
        task.arguments = args
        task.environment = env
        let out = Pipe()
        let err = Pipe()
        task.standardOutput = out
        task.standardError = err
        let input = Pipe()
        task.standardInput = input
        try task.run()
        if let stdin { _ = feed(stdin, to: input.fileHandleForWriting.fileDescriptor) }
        try input.fileHandleForWriting.close()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return Output(status: task.terminationStatus, stdout: outData, stderr: errData)
    }

    /// Writes `data` to a command's standard input. A command that exits, or closes its input,
    /// before it reads everything makes the write fail; without `F_SETNOSIGPIPE` that failure
    /// would be a SIGPIPE that ends the whole test process. Returns false when the command did
    /// not read all of its input.
    static func feed(_ data: Data, to fd: Int32) -> Bool {
        let on: Int32 = 1
        _ = fcntl(fd, F_SETNOSIGPIPE, on)
        return data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Bool in
            guard let base = buffer.baseAddress else { return true }
            var offset = 0
            while offset < buffer.count {
                let written: Int = Darwin.write(fd, base + offset, buffer.count - offset)
                if written < 0 && errno == EINTR { continue }
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
    }

    /// Runs with a pseudo-terminal as standard input, so the command sees a terminal. `input` is
    /// typed once the process is running, then end of input follows.
    static func runOnTerminal(
        _ exe: URL, _ args: [String], env: [String: String], input: String = ""
    ) throws -> Output {
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw MissingBinary()
        }
        defer {
            close(master)
            close(slave)
        }
        let task = Process()
        task.executableURL = exe
        task.arguments = args
        task.environment = env
        let out = Pipe()
        let err = Pipe()
        task.standardOutput = out
        task.standardError = err
        task.standardInput = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        try task.run()
        let typed = Array((input + "\u{4}").utf8)
        _ = Darwin.write(master, typed, typed.count)
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return Output(status: task.terminationStatus, stdout: outData, stderr: errData)
    }

    /// The command printed something else and kept waiting, so `prompt` never came.
    struct PromptNotShown: Error, CustomStringConvertible {
        var shown: String
        var description: String { "The prompt never appeared. The command printed: \(shown)" }
    }

    /// Like `runOnTerminal`, but `between` runs once the command has printed `prompt` and is
    /// waiting for its answer, and only then is `input` typed. A test changes a record there, the
    /// way another command could while a person reads the plan. A command that exits before the
    /// prompt skips `between`. A command still waiting without the prompt after `deadline`
    /// seconds is stopped, and the call throws `PromptNotShown` with what it printed.
    static func runOnTerminal(
        _ exe: URL, _ args: [String], env: [String: String], prompt: String,
        between: () throws -> Void, input: String, deadline: TimeInterval = 30
    ) throws -> Output {
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw MissingBinary()
        }
        defer {
            close(master)
            close(slave)
        }
        let task = Process()
        task.executableURL = exe
        task.arguments = args
        task.environment = env
        let out = Pipe()
        let err = Pipe()
        task.standardOutput = out
        task.standardError = err
        task.standardInput = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        try task.run()
        var shown = Data()
        let wanted = Data(prompt.utf8)
        let reader: Int32 = out.fileHandleForReading.fileDescriptor
        let end = Date().addingTimeInterval(deadline)
        while shown.range(of: wanted) == nil {
            let left = end.timeIntervalSinceNow
            if left <= 0 {
                task.terminate()
                task.waitUntilExit()
                throw PromptNotShown(shown: String(decoding: shown, as: UTF8.self))
            }
            var watch = pollfd(fd: reader, events: Int16(POLLIN), revents: 0)
            let count: nfds_t = 1
            let wait: Int32 = Int32(min(left, 1) * 1000) + 1
            let ready: Int32 = poll(&watch, count, wait)
            if ready <= 0 { continue }
            let chunk = out.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            shown.append(chunk)
        }
        var failure: Error?
        if shown.range(of: wanted) != nil {
            do { try between() } catch { failure = error }
        }
        let typed = Array((input + "\u{4}").utf8)
        _ = Darwin.write(master, typed, typed.count)
        shown.append(out.fileHandleForReading.readDataToEndOfFile())
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        if let failure { throw failure }
        return Output(status: task.terminationStatus, stdout: shown, stderr: errData)
    }

    /// The folder `CLIHome` homes go in: `TMPDIR` when it is set, so a run can keep them, and the
    /// access lists some tests set on them, out of the system's temporary folder, which
    /// Foundation picks whatever `TMPDIR` says.
    static let temporaryFolder: URL = {
        if let set = ProcessInfo.processInfo.environment["TMPDIR"], !set.isEmpty {
            return URL(fileURLWithPath: set, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
    }()

    static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ab-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

struct MissingBinary: Error, CustomStringConvertible {
    var description: String {
        "The agent-balancer binary is not built. Run `swift build` before the CLI tests."
    }
}

/// A temporary home with the fake `claude` at `.local/bin/claude`, and the built CLI to run in it.
/// No test runs the real `claude`.
struct CLIHome {
    let home: URL
    let exe: URL
    let fixtures = Support.root.appendingPathComponent("Tests/Fixtures")

    init(installFake: Bool = true) throws {
        guard let exe = Support.builtBinary() else { throw MissingBinary() }
        self.exe = exe
        home = Support.temporaryFolder
            .appendingPathComponent("ab-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        if installFake { try self.installFake() }
    }

    func cleanup() { try? FileManager.default.removeItem(at: home) }

    var dataRoot: URL { home.appendingPathComponent(".agent-balancer") }
    var fakePath: URL { home.appendingPathComponent(".local/bin/claude") }

    func installFake() throws {
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(
            at: bin, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.copyItem(
            at: fixtures.appendingPathComponent("bin/claude"), to: fakePath)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fakePath.path)
    }

    func fake(_ name: String, _ text: String) throws {
        let dir = home.appendingPathComponent(".ab-fake")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func fakeFixture(_ name: String, exit: Int = 0) throws {
        let text = try String(
            contentsOf: fixtures.appendingPathComponent("auth/\(name).json"), encoding: .utf8)
        try fake("auth.json", text)
        try fake("auth.exit", "\(exit)")
    }

    func fakeProbe(_ fixture: String) throws {
        let now = Date()
        let text = try String(
            contentsOf: fixtures.appendingPathComponent("probe/\(fixture)"), encoding: .utf8
        )
        .replacingOccurrences(of: "@RESET_5H@", with: "\(Int(now.timeIntervalSince1970) + 10_000)")
        .replacingOccurrences(of: "@RESET_7D@", with: "\(Int(now.timeIntervalSince1970) + 400_000)")
        .replacingOccurrences(
            of: "@RESET_31D@", with: "\(Int(now.timeIntervalSince1970) + 2_000_000)")
        try fake("probe.jsonl", text)
    }

    func fakeRecord(_ name: String) -> String {
        (try? String(
            contentsOf: home.appendingPathComponent(".ab-fake/\(name)"), encoding: .utf8)) ?? ""
    }

    func settings(_ json: String) throws {
        let dir = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try json.write(
            to: dir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
    }

    func run(_ args: [String], env extra: [String: String] = [:], stdin: String? = nil) throws
        -> Support.Output
    {
        var env = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        for (k, v) in extra { env[k] = v }
        // These commands need a person at a terminal, so what a test pipes in is typed on one.
        let needsTerminal =
            ["init", "uninstall"].contains(args.first ?? "")
            || (args.first == "login" && args.contains("--paste"))
        if needsTerminal {
            return try Support.runOnTerminal(exe, args, env: env, input: stdin ?? "")
        }
        return try Support.run(exe, args, env: env, stdin: stdin.map { Data($0.utf8) })
    }

    /// Runs with a pipe as input even for a command that needs a terminal, to test its refusal.
    func runPiped(_ args: [String], env extra: [String: String] = [:], stdin: String? = nil) throws
        -> Support.Output
    {
        var env = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        for (k, v) in extra { env[k] = v }
        return try Support.run(exe, args, env: env, stdin: stdin.map { Data($0.utf8) })
    }

    /// Like `run`, with a terminal as standard input.
    func runOnTerminal(_ args: [String], env extra: [String: String] = [:], typing: String = "")
        throws -> Support.Output
    {
        var env = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        for (k, v) in extra { env[k] = v }
        return try Support.runOnTerminal(exe, args, env: env, input: typing)
    }

    /// Like `runOnTerminal`, with `between` run at the typed-answer prompt before `typing`.
    func runOnTerminal(
        _ args: [String], prompt: String, between: () throws -> Void, typing: String,
        env extra: [String: String] = [:], deadline: TimeInterval = 30
    ) throws -> Support.Output {
        var env = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        for (k, v) in extra { env[k] = v }
        return try Support.runOnTerminal(
            exe, args, env: env, prompt: prompt, between: between, input: typing,
            deadline: deadline)
    }

    func read(_ relative: String) -> String {
        (try? String(contentsOf: dataRoot.appendingPathComponent(relative), encoding: .utf8)) ?? ""
    }

    /// Every file and folder under the data root.
    func dataEntries() -> [URL] {
        guard
            let walker = FileManager.default.enumerator(
                at: dataRoot, includingPropertiesForKeys: [.isDirectoryKey])
        else { return [] }
        return walker.compactMap { $0 as? URL }
    }

    func mode(_ url: URL) -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func expectPrivateModes() -> [String] {
        var bad: [String] = []
        if mode(dataRoot) != 0o700 { bad.append("root") }
        for url in dataEntries() {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            let want = isDir.boolValue ? 0o700 : 0o600
            if mode(url) != want { bad.append(url.lastPathComponent) }
        }
        return bad
    }

    /// stdout, stderr and the text of every file under the data root.
    func everything(_ out: Support.Output) -> String {
        var text =
            String(decoding: out.stdout, as: UTF8.self)
            + String(decoding: out.stderr, as: UTF8.self)
        for url in dataEntries() {
            text += (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        return text
    }
}
