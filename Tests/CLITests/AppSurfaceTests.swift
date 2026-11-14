import Foundation
import Testing

/// The menu app declares no scripting surface and acts on no launch argument that reaches
/// management, a command or a URL.
@Suite struct AppSurfaceTests {
    static let forbiddenKeys = [
        "NSAppleScriptEnabled", "OSAScriptingDefinition", "CFBundleURLTypes", "NSServices",
        "CFBundleDocumentTypes", "NSUserActivityTypes", "NSExtension",
    ]

    /// The Info.plist text the build script writes.
    static func plistFromBuildScript() throws -> String {
        let script = try String(
            contentsOf: Support.root.appendingPathComponent("scripts/build-app.sh"),
            encoding: .utf8)
        let start = try #require(script.range(of: "<?xml"))
        let end = try #require(script.range(of: "</plist>"))
        return String(script[start.lowerBound..<end.upperBound])
    }

    @Test func theInfoPlistTheScriptWritesDeclaresNoScriptingUrlOrServiceSurface() throws {
        let text = try Self.plistFromBuildScript()
        let plist =
            try PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil)
            as? [String: Any]
        let info = try #require(plist)
        for key in Self.forbiddenKeys { #expect(info[key] == nil, "\(key)") }
        #expect(info["LSUIElement"] as? Bool == true)
    }

    @Test func aBuiltInfoPlistDeclaresNone() throws {
        let url = Support.root.appendingPathComponent(
            "build/AgentBalancerBar.app/Contents/Info.plist")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        let plist =
            try PropertyListSerialization.propertyList(from: data, format: nil)
            as? [String: Any]
        let info = try #require(plist)
        for key in Self.forbiddenKeys { #expect(info[key] == nil, "\(key)") }
    }

    /// Source files of the app, relative to the root.
    static func appSources() throws -> [(String, String)] {
        let dir = Support.root.appendingPathComponent("Sources/AgentBalancerBar")
        let walker = try #require(FileManager.default.enumerator(atPath: dir.path))
        var out: [(String, String)] = []
        for case let path as String in walker where path.hasSuffix(".swift") {
            let text = try String(
                contentsOf: dir.appendingPathComponent(path), encoding: .utf8)
            out.append((path, text))
        }
        return out
    }

    @Test func onlyTheDeveloperRenderFlagsReadLaunchArguments() throws {
        let allowed: Set<String> = ["main.swift", "RenderMode.swift"]
        for (path, text) in try Self.appSources() where !allowed.contains(path) {
            #expect(!text.contains("CommandLine"), "\(path)")
            #expect(!text.contains("onOpenURL"), "\(path)")
            #expect(!text.contains("handlesExternalEvents"), "\(path)")
            #expect(!text.contains("NSAppleScript"), "\(path)")
            #expect(!text.contains("servicesProvider"), "\(path)")
            #expect(!text.contains("NSServices"), "\(path)")
            #expect(!text.contains("application(_ application: NSApplication, open"), "\(path)")
        }
    }

    @Test func theRenderFlagsWriteOnlyUnderABuildFolder() throws {
        let text = try String(
            contentsOf: Support.root.appendingPathComponent(
                "Sources/AgentBalancerBar/RenderMode.swift"), encoding: .utf8)
        // The folder comes only from the checked rule, opened once; every file is written
        // relative to that handle.
        #expect(text.contains("writer = try RenderOutput.hold(arguments[flagIndex + 1])"))
        #expect(!text.contains("NoFollowWriter(root:"))
        #expect(!text.contains("RenderOutput.folder("))
        #expect(!text.contains("/build/"))
        let main = try String(
            contentsOf: Support.root.appendingPathComponent("Sources/AgentBalancerBar/main.swift"),
            encoding: .utf8)
        // Only these two flags are looked at, and neither reaches the Manage view model.
        #expect(main.contains("\"--render\""))
        #expect(main.contains("\"--iconset\""))
        #expect(!main.contains("Manage"))
    }

    static func appBinary() throws -> URL {
        for config in ["debug", "release"] {
            let url = Support.root.appendingPathComponent(".build/\(config)/AgentBalancerBar")
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        throw MissingBinary()
    }

    /// Runs the app binary with one render flag in `cwd`, with `home` as the home folder.
    static func renderFlag(_ arguments: [String], cwd: URL, home: URL) throws -> (Int32, String) {
        let task = Process()
        task.executableURL = try appBinary()
        task.arguments = arguments
        task.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        task.currentDirectoryURL = cwd
        let out = Pipe()
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = out
        task.standardError = FileHandle.nullDevice
        try task.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test func theRenderFlagsRefuseEveryOtherFolderAndWriteNothing() throws {
        let made = FileManager.default.temporaryDirectory
            .appendingPathComponent("ab-app-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: made) }
        let real = try #require(realpath(made.path, nil))
        let root = URL(fileURLWithPath: String(cString: real))
        free(real)
        let fm = FileManager.default
        let repo = root.appendingPathComponent("repo")
        let home = root.appendingPathComponent("home")
        let elsewhere = root.appendingPathComponent("elsewhere")
        let inClaude = home.appendingPathComponent(".claude/proj")
        for folder in [repo.appendingPathComponent("build"), elsewhere, inClaude] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try fm.createDirectory(
            at: home.appendingPathComponent(".claude/proj/build"), withIntermediateDirectories: true
        )
        try fm.createSymbolicLink(
            at: repo.appendingPathComponent("build/out"), withDestinationURL: elsewhere)
        let before = (fm.subpaths(atPath: root.path) ?? []).sorted()
        let cases: [([String], URL)] = [
            (["--iconset", "icons"], repo),
            (["--iconset", "build/../icons"], repo),
            (["--iconset", "build"], repo),
            (["--iconset", "build/out"], repo),
            (["--render", "build/out/renders"], repo),
            (["--iconset", elsewhere.path + "/build/icons"], repo),
            (["--iconset", "build/icons"], inClaude),
        ]
        for (arguments, cwd) in cases {
            let (status, printed) = try Self.renderFlag(arguments, cwd: cwd, home: home)
            #expect(status != 0, "\(arguments)")
            // Refused by the path rule, before anything is drawn.
            #expect(
                printed.contains("The output folder must be a folder under build/"), "\(arguments)")
        }
        #expect((fm.subpaths(atPath: root.path) ?? []).sorted() == before)
        #expect((fm.subpaths(atPath: elsewhere.path) ?? []).isEmpty)
    }

    /// Makes `names` one inside the other under `top`, each relative to the folder before it, since
    /// the whole path can be longer than a path call takes. Returns a handle on the last one.
    static func deepFolder(under top: URL, names: [String]) throws -> Int32 {
        var dir = open(top.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        for name in names where dir >= 0 {
            let next =
                mkdirat(dir, name, 0o700) == 0
                ? openat(dir, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC) : -1
            close(dir)
            dir = next
        }
        guard dir >= 0 else { throw POSIXError(.EIO) }
        return dir
    }

    /// Renames each folder of a chain `deepFolder` made to one letter, so the tree's paths are
    /// short enough for FileManager to remove it.
    static func shorten(under top: URL, names: [String]) {
        var dir = open(top.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        for name in names where dir >= 0 {
            let next =
                renameat(dir, name, dir, "s") == 0
                ? openat(dir, "s", O_RDONLY | O_DIRECTORY | O_CLOEXEC) : -1
            close(dir)
            dir = next
        }
        if dir >= 0 { close(dir) }
    }

    /// The names in the folder `dir` holds open.
    static func names(in dir: Int32) -> [String] {
        let copy = dup(dir)
        guard copy >= 0, let stream = fdopendir(copy) else { return ["(unreadable)"] }
        defer { closedir(stream) }
        rewinddir(stream)
        var out: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." { out.append(name) }
        }
        return out.sorted()
    }

    /// Runs the app binary with one render flag, started in the folder `dir` holds open (no path
    /// call reaches it), with `home` as the home folder. What it prints goes to `output`.
    static func renderFlag(_ arguments: [String], in dir: Int32, home: URL, output: URL) throws
        -> (Int32, String)
    {
        let binary = try appBinary().path
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Only the descriptors named here reach the child.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(
            &actions, 1, output.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addfchdir_np(&actions, dir)
        let argv = ([binary] + arguments).map { strdup($0) } + [nil]
        let environment: [String] = ["HOME=" + home.path, "PATH=/usr/bin:/bin"]
        let envp = environment.map { strdup($0) } + [nil]
        defer { for pointer in argv + envp { free(pointer) } }
        var pid = pid_t()
        guard posix_spawn(&pid, binary, &actions, &attributes, argv, envp) == 0 else {
            throw POSIXError(.EIO)
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        let printed = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
        // A normal exit has zero in the low seven bits and its code in the next eight.
        return (status & 0x7f == 0 ? (status >> 8) & 0xff : -1, printed)
    }

    @Test func theRenderFlagsRefuseACurrentFolderInsideTheToolFoldersWhateverItsPathLength()
        throws
    {
        let made = FileManager.default.temporaryDirectory
            .appendingPathComponent("ab-deep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: made) }
        let real = try #require(realpath(made.path, nil))
        let root = URL(fileURLWithPath: String(cString: real))
        free(real)
        let home = root.appendingPathComponent("home")
        // Six 200-byte names take the current folder's path past the 1024 bytes the system gives
        // for it, so the app reads its current folder's path as "".
        let deep = Array(repeating: String(repeating: "d", count: 200), count: 6)
        for folder in [".claude", ".agent-balancer"] {
            let top = home.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: top, withIntermediateDirectories: true)
            let cwd = try Self.deepFolder(under: top, names: deep)
            defer {
                close(cwd)
                Self.shorten(under: top, names: deep)
            }
            #expect(mkdirat(cwd, "build", 0o700) == 0)
            let build = openat(cwd, "build", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            defer { close(build) }
            for arguments in [
                ["--render", "build/x"], ["--iconset", "build/x"], ["--render", "/build/x"],
            ] {
                let (status, printed) = try Self.renderFlag(
                    arguments, in: cwd, home: home, output: root.appendingPathComponent("out"))
                #expect(status == 1, "\(folder) \(arguments)")
                #expect(
                    printed.contains("The output folder must be a folder under build/"),
                    "\(folder) \(arguments)")
                #expect(Self.names(in: build).isEmpty, "\(folder) \(arguments)")
                #expect(Self.names(in: cwd) == ["build"], "\(folder) \(arguments)")
            }
        }
    }

    static func source(_ path: String) throws -> String {
        try String(
            contentsOf: Support.root.appendingPathComponent("Sources/AgentBalancerBar/" + path),
            encoding: .utf8)
    }

    @Test func everyFieldDatePickerAndChoiceGroupInTheWindowHasAnAccessibilityLabel() throws {
        var controls = 0
        for (path, text) in try Self.appSources() where path.hasPrefix("Manage/") {
            let lines = text.components(separatedBy: "\n")
            for (index, line) in lines.enumerated()
            where line.contains("TextField(") || line.contains("DatePicker(") {
                controls += 1
                let chain = lines[index..<min(lines.count, index + 8)].joined(separator: "\n")
                #expect(chain.contains(".accessibilityLabel("), "\(path):\(index + 1)")
            }
        }
        // The Add sheet's field builder (label and email), the Remove sheet's field, the picker.
        #expect(controls == 3)
        let sheets = try Self.source("Manage/ManageSheets.swift")
        for label in ["Kind", "Ends", "Type the label to confirm"] {
            #expect(sheets.contains(".accessibilityLabel(\"\(label)\")"), "\(label)")
        }
        #expect(sheets.contains(".accessibilityLabel(name)"))
        let content = try Self.source("Manage/ManageContent.swift")
        for label in ["Ends", "End date"] {
            #expect(content.contains(".accessibilityLabel(\"\(label)\")"), "\(label)")
        }
    }

    @Test func theAddSheetKeepsCancelAndEscapeOffWhileACommandRuns() throws {
        let sheets = try Self.source("Manage/ManageSheets.swift")
        #expect(sheets.contains("title: added ? \"Close\" : \"Cancel\", enabled: !busy"))
        let window = try Self.source("Manage/ManageWindow.swift")
        #expect(window.contains(".interactiveDismissDisabled(model.busy)"))
    }

    @Test func everySheetKeepsCancelAndEscapeOffWhileACommandRuns() throws {
        let window = try Self.source("Manage/ManageWindow.swift")
        let sheets = window.components(separatedBy: ".sheet(").count - 1
        #expect(sheets == 2)
        // One per sheet: Esc stays off while its command runs.
        #expect(
            window.components(separatedBy: ".interactiveDismissDisabled(model.busy)").count - 1
                == sheets)
        #expect(window.contains("busy: model.busy,"))
        let content = try Self.source("Manage/ManageSheets.swift")
        #expect(content.contains("ChromeButton(title: \"Cancel\", enabled: !busy"))
        #expect(content.contains("enabled: canConfirm && !busy"))
        #expect(content.contains(".disabled(busy)"))
    }

    @Test func everyControlTurnsOffWithDisabledSoVoiceOverAndTheKeyboardSeeIt() throws {
        for (path, text) in try Self.appSources() where path.hasPrefix("Manage/") {
            #expect(!text.contains("allowsHitTesting"), "\(path)")
        }
        let controls = try Self.source("Manage/ManageControls.swift")
        // The radio choice, the one control that turned off by hit testing alone.
        #expect(controls.contains(".buttonStyle(.plain).disabled(!enabled)"))
    }

    @Test func eachCopyButtonNamesWhatItCopies() throws {
        var chips = 0
        for (path, text) in try Self.appSources() where path.hasPrefix("Manage/") {
            for line in text.components(separatedBy: "\n") where line.contains("CopyChip(text:") {
                chips += 1
                #expect(line.contains("what: \""), "\(path): \(line)")
            }
        }
        #expect(chips == 3)
        let controls = try Self.source("Manage/ManageControls.swift")
        #expect(controls.contains("accessibility: \"Copy \\(what)\""))
        let content = try Self.source("Manage/ManageContent.swift")
        #expect(content.contains("what: \"folder path\""))
    }

    @Test func theBuildScriptChecksTheWrittenInfoPlistForEveryForbiddenKey() throws {
        let script = try String(
            contentsOf: Support.root.appendingPathComponent("scripts/build-app.sh"),
            encoding: .utf8)
        let written = try #require(script.range(of: "\nPLIST\n"))
        let signed = try #require(script.range(of: "codesign --force"))
        let check = String(script[written.upperBound..<signed.lowerBound])
        #expect(check.contains("plutil -extract \"$key\" xml1"))
        #expect(check.contains("exit 1"))
        for key in Self.forbiddenKeys { #expect(check.contains(key), "\(key)") }
    }

    @Test func theWindowBuildsItsCommandsOnlyThroughTheViewModel() throws {
        for (path, text) in try Self.appSources() where path.hasPrefix("Manage/") {
            #expect(!text.contains("CLIRunner"), "\(path)")
            #expect(!text.contains("\"link\""), "\(path)")
            #expect(!text.contains("\"unlink\""), "\(path)")
            #expect(!text.contains("--paste"), "\(path)")
            #expect(!text.contains("set-main"), "\(path)")
            #expect(!text.contains("clear-main"), "\(path)")
        }
    }
}

/// The open window reads the status file on each pass of the menu's file loop and when it or a
/// sheet becomes key, and both depend on the window marking itself open when it appears.
extension AppSurfaceTests {
    /// The first `{ ... }` block after `marker`, with its braces balanced.
    static func block(after marker: String, in text: String) -> String? {
        guard let found = text.range(of: marker),
            let open = text[found.upperBound...].firstIndex(of: "{")
        else { return nil }
        var depth = 0
        var index = open
        while index < text.endIndex {
            if text[index] == "{" { depth += 1 }
            if text[index] == "}" {
                depth -= 1
                if depth == 0 { return String(text[open...index]) }
            }
            index = text.index(after: index)
        }
        return nil
    }

    @Test func theOpenWindowReadsTheStatusOnTheFileLoopWhenKeyAndFromWhenItOpens() throws {
        let app = try Self.source("AppModel.swift")
        let setUp = try #require(Self.block(after: "init()", in: app))
        #expect(
            setUp.contains(
                "controller.afterFileRead = { [manage] in manage.statusMayHaveChanged() }"))
        let window = try Self.source("Manage/ManageWindow.swift")
        let key = try #require(
            Self.block(
                after:
                    ".onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification))",
                in: window))
        #expect(key.contains("model.statusMayHaveChanged()"))
        #expect(key.contains("(window.sheetParent ?? window).title == \"Manage accounts\""))
        #expect(window.contains("WindowDock(title: \"Manage accounts\")"))
        // Only an open window reads on those beats, so appearing must mark it open.
        let appear = try #require(Self.block(after: ".onAppear", in: window))
        #expect(appear.contains("model.windowOpened()"))
        #expect(!appear.contains("model.reload()"))
        let disappear = try #require(Self.block(after: ".onDisappear", in: window))
        #expect(disappear.contains("model.windowClosed()"))
    }
}
