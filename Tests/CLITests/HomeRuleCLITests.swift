import Core
import Foundation
import Testing

/// A HOME that is not an absolute path, or that has a `..` segment, stops every command with a
/// message that names HOME before anything is read or written, so the data folder never moves
/// with the current folder.
@Suite struct HomeRuleCLITests {
    /// Every command, each with arguments that parse.
    static let commands: [[String]] = [
        ["init"], ["doctor"], ["config", "show"], ["config", "validate"],
        ["config", "set-main", "pool-a"], ["config", "clear-main", "pool-a"],
        ["config", "set", "refresh.backgroundMinutes", "30"], ["link", "pool-a"],
        ["unlink", "pool-a"], ["verify", "pool-a"], ["refresh"], ["pick", "--json"],
        ["status", "--cached"], ["events"], ["history"], ["add", "pool-b"], ["login", "pool-a"],
        ["remove", "pool-a"], ["run", "--print-command", "pool-a"], ["uninstall"],
    ]

    /// A root by its real path. `work`, the current folder of each run, holds `x`, the folder
    /// HOME `x` and `./x` would name, and `home` is the folder `<root>/home/../home` would name.
    /// Each holds a config and the fake `claude`, so a command that took such a HOME would read
    /// and write there, and never reach another `claude`.
    static func withRoot(_ body: (URL) throws -> Void) throws {
        let fm = FileManager.default
        let made = Support.temporaryFolder.appendingPathComponent("ab-home-\(UUID().uuidString)")
        try fm.createDirectory(at: made, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: made) }
        let real = try #require(realpath(made.path, nil))
        let root = URL(fileURLWithPath: String(cString: real))
        free(real)
        for home in [root.appendingPathComponent("work/x"), root.appendingPathComponent("home")] {
            try fm.createDirectory(at: home, withIntermediateDirectories: true)
            try ConfigStore(context: ToolContext(home: home, ambient: [:])).save(Config())
            let bin = home.appendingPathComponent(".local/bin")
            try fm.createDirectory(
                at: bin, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let fake = bin.appendingPathComponent("claude")
            try fm.copyItem(
                at: Support.root.appendingPathComponent("Tests/Fixtures/bin/claude"), to: fake)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        }
        try body(root)
    }

    /// Every path under `root`, with the bytes of each file.
    static func tree(_ root: URL) -> [String: Data] {
        var found: [String: Data] = [:]
        for path in FileManager.default.subpaths(atPath: root.path) ?? [] {
            found[path] = (try? Data(contentsOf: root.appendingPathComponent(path))) ?? Data()
        }
        return found
    }

    /// Runs the built CLI in `folder` with only HOME and PATH set and no terminal.
    static func run(_ args: [String], home: String, in folder: URL) throws -> Support.Output {
        guard let exe = Support.builtBinary() else { throw MissingBinary() }
        let task = Process()
        task.executableURL = exe
        task.arguments = args
        task.environment = ["HOME": home, "PATH": "/usr/bin:/bin"]
        task.currentDirectoryURL = folder
        task.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        task.standardOutput = out
        task.standardError = err
        try task.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return Support.Output(status: task.terminationStatus, stdout: outData, stderr: errData)
    }

    @Test(arguments: ["x", "./x", "dotdot"])
    func aHomeThatIsRelativeOrHasDotDotStopsEveryCommandAndWritesNothing(spelling: String) throws {
        try Self.withRoot { root in
            let home = spelling == "dotdot" ? root.path + "/home/../home" : spelling
            let before = Self.tree(root)
            #expect(before.keys.contains("work/x/.agent-balancer/config.json"))
            #expect(before.keys.contains("home/.agent-balancer/config.json"))
            for args in Self.commands {
                let out = try Self.run(args, home: home, in: root.appendingPathComponent("work"))
                let said = String(decoding: out.stderr, as: UTF8.self)
                #expect(out.status == 1, "\(spelling) \(args)")
                #expect(said.contains("HOME must be an absolute path"), "\(spelling) \(args)")
                #expect(out.stdout.isEmpty, "\(spelling) \(args)")
                #expect(Self.tree(root) == before, "\(spelling) \(args)")
            }
        }
    }
}

extension AppSurfaceTests {
    /// No test opens the app, so its start is pinned by its text: it takes the context the HOME
    /// rule gives first, and a refusal prints and ends the app before the controller, the first
    /// reader of the data folder, exists.
    @Test func theAppTakesItsContextFromTheHomeRuleBeforeItReadsAnything() throws {
        let app = try Self.source("AppModel.swift")
        let start = try #require(Self.block(after: "init()", in: app))
        let context = try #require(start.range(of: "context = try ToolContext.current()"))
        let printed = try #require(start.range(of: "print(error.localizedDescription)"))
        let ended = try #require(start.range(of: "exit(1)"))
        let controller = try #require(start.range(of: "controller = MenuController(context:"))
        #expect(context.upperBound < printed.lowerBound)
        #expect(printed.upperBound < ended.lowerBound)
        #expect(ended.upperBound < controller.lowerBound)
        #expect(!app.contains("ToolContext(home:"))
    }
}
