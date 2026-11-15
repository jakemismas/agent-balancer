import Foundation
import Testing

@testable import Core

private func fileText(_ url: URL) -> String {
    (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

private func mode(_ url: URL) -> Int {
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attrs?[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

/// True when the folder carries the backup exclusion attribute. Read straight from the file
/// system, so the test does not depend on the writer's own reader.
private func excluded(_ url: URL) -> Bool {
    getxattr(url.path, "com.apple.metadata:com_apple_backup_excludeItem", nil, 0, 0, 0) >= 0
}

@Suite struct TokenShapeTests {
    @Test func theRealShapeCanaryHasTheRecordedShape() {
        let token = Canaries.oauthRealShape()
        let body = token.dropFirst(("sk-" + "ant-" + "oat01-").count)
        #expect(token.count == 108)
        #expect(token.hasPrefix("sk-" + "ant-" + "oat01-"))
        #expect(body.contains { $0.isUppercase } && body.contains { $0.isLowercase })
        #expect(body.contains { $0.isNumber } && body.contains("-"))
    }

    @Test func acceptsASetupTokenShapeAndRefusesOthers() {
        #expect(TokenCapture.hasTokenShape(Canaries.oauth()))
        #expect(TokenCapture.hasTokenShape(Canaries.oauthRealShape()))
        #expect(!TokenCapture.hasTokenShape(Canaries.oauthRealShape() + " trailing"))
        #expect(!TokenCapture.hasTokenShape(Canaries.apiKey()))
        #expect(!TokenCapture.hasTokenShape("sk-" + "ant-" + "oat01-short"))
        #expect(!TokenCapture.hasTokenShape("not a token at all, with spaces and more words here"))
        #expect(!TokenCapture.hasTokenShape(Canaries.oauth() + " trailing"))
        #expect(!TokenCapture.hasTokenShape(""))
    }

    @Test func extractsTheTokenFromRawOutputWithTerminalCodes() throws {
        for token in [Canaries.oauth(), Canaries.oauthRealShape()] {
            let raw =
                "\u{1B}[2J\u{1B}[32mOpening browser\u{1B}[0m\r\nYour token is \u{1B}[1m\(token)\u{1B}[0m\r\nStore it safely.\n"
            #expect(TokenCapture.extract(from: Data(raw.utf8)) == token)
        }
        #expect(TokenCapture.extract(from: Data("no token here\n".utf8)) == nil)
        #expect(TokenCapture.extract(from: Data(Canaries.apiKey().utf8)) == nil)
    }

    @Test func takesTheLastWellShapedCandidate() {
        let first = Canaries.oauth()
        let second = Canaries.oauth()
        let raw = "old \(first)\nnew \(second)\n"
        #expect(TokenCapture.extract(from: Data(raw.utf8)) == second)
    }
}

@Suite struct TokenAccountsTests {
    func tokenAccount(_ label: String = "pool-a") -> Account {
        Account(label: label, kind: Kind.token, role: Role.pool)
    }

    @Test func installWritesAPrivateFileInAnExcludedFolder() throws {
        let t = try TestHome()
        let token = Canaries.oauth()
        let installed = try TokenAccounts.install(context: t.context, label: "pool-a", token: token)
        #expect(!installed.replaced)
        #expect(installed.launchFilesRewritten == 0)

        let file = try TokenPaths.fileURL(context: t.context, label: "pool-a")
        #expect(mode(file) == 0o600)
        #expect(mode(file.deletingLastPathComponent()) == 0o700)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let env = try #require(object["env"] as? [String: String])
        #expect(env[ProtectedEnv.tokenVariable] == token)
        #expect(env["AGENT_BALANCER_ACCOUNT"] == "pool-a")
        #expect(env.count == 2)
        #expect(TokenStore.isUsable(context: t.context, label: "pool-a"))
        #expect(excluded(file.deletingLastPathComponent()))
        let writer = NoFollowWriter(root: t.context.dataRoot)
        #expect(try writer.isExcludedFromBackup(folders: TokenPaths.folders))
    }

    @Test func aPickMarksTheLaunchFolderExcludedToo() throws {
        let t = try TestHome()
        _ = try TokenAccounts.install(
            context: t.context, label: "pool-a", token: Canaries.oauth())
        _ = try LaunchFiles.create(
            context: t.context, account: tokenAccount(), leaseId: "l-0a0b0c0d",
            caller: .none)
        #expect(excluded(LaunchFiles.rootURL(context: t.context)))
    }

    @Test func refusesATokenWithTheWrongShapeBeforeWritingAnything() throws {
        let t = try TestHome()
        #expect(throws: ToolError.self) {
            try TokenAccounts.install(context: t.context, label: "pool-a", token: "has a space")
        }
        #expect(!FileManager.default.fileExists(atPath: t.context.dataRoot.path))
    }

    @Test func replaceRewritesEveryLaunchFileOfTheLabelOnly() throws {
        let t = try TestHome()
        let old = Canaries.oauth()
        let other = Canaries.oauth()
        _ = try TokenAccounts.install(context: t.context, label: "pool-a", token: old)
        _ = try TokenAccounts.install(context: t.context, label: "pool-b", token: other)
        let one = try LaunchFiles.create(
            context: t.context, account: tokenAccount(), leaseId: "l-00000001", caller: .none)
        let two = try LaunchFiles.create(
            context: t.context, account: tokenAccount(), leaseId: "l-00000002", caller: .none)
        let b = try LaunchFiles.create(
            context: t.context, account: tokenAccount("pool-b"), leaseId: "l-00000003",
            caller: .none)
        #expect(fileText(one).contains(old))

        let fresh = Canaries.oauth()
        let installed = try TokenAccounts.install(
            context: t.context, label: "pool-a", token: fresh)
        #expect(installed.replaced)
        #expect(installed.launchFilesRewritten == 2)
        for url in [one, two] {
            let text = fileText(url)
            #expect(text.contains(fresh) && !text.contains(old))
            #expect(mode(url) == 0o600)
            #expect(text.contains("AGENT_BALANCER_ACCOUNT"))
        }
        #expect(fileText(b).contains(other) && !fileText(b).contains(fresh))
        #expect(!t.allText().contains(old))
    }

    @Test func removeDeletesTheTokenAndLaunchFilesAndKeepsOtherLabels() throws {
        let t = try TestHome()
        _ = try TokenAccounts.install(
            context: t.context, label: "pool-a", token: Canaries.oauth())
        _ = try TokenAccounts.install(
            context: t.context, label: "pool-b", token: Canaries.oauth())
        let a = try LaunchFiles.create(
            context: t.context, account: tokenAccount(), leaseId: "l-00000001", caller: .none)
        let b = try LaunchFiles.create(
            context: t.context, account: tokenAccount("pool-b"), leaseId: "l-00000002",
            caller: .none)
        let store = ReadingStore(context: t.context)
        let reading = Reading(readAt: Date(), windows: [:], fable: nil)
        try store.save(reading, label: "pool-a")
        let leases = LeaseStore(context: t.context)
        // pool-a's open lease is for a pick whose file is gone, so its one launch file is deleted.
        try leases.save([
            Lease(id: "l-0000000f", label: "pool-a", model: "m", at: Date()),
            Lease(id: "l-00000002", label: "pool-b", model: "m", at: Date()),
        ])

        let removed = try TokenAccounts.removeFiles(context: t.context, label: "pool-a")
        #expect(removed == TokenAccounts.Removed(tokenFile: true, launchFiles: 1))
        #expect(!FileManager.default.fileExists(atPath: a.path))
        #expect(!FileManager.default.fileExists(atPath: a.deletingLastPathComponent().path))
        #expect(
            !FileManager.default.fileExists(
                atPath: try TokenPaths.fileURL(context: t.context, label: "pool-a").path))
        #expect(FileManager.default.fileExists(atPath: b.path))
        #expect(TokenStore.isUsable(context: t.context, label: "pool-b"))
        #expect(try store.load(label: "pool-a") == nil)
        let open = try leases.current(now: Date(), leaseMinutes: 10)
        #expect(open.map(\.label) == ["pool-b"])

        let again = try TokenAccounts.removeFiles(context: t.context, label: "pool-a")
        #expect(again == TokenAccounts.Removed(tokenFile: false, launchFiles: 0))
    }

    @Test func removeNeverFollowsOrDeletesALinkItDidNotMake() throws {
        let t = try TestHome()
        _ = try TokenAccounts.install(
            context: t.context, label: "pool-a", token: Canaries.oauth())
        let launched = try LaunchFiles.create(
            context: t.context, account: tokenAccount(), leaseId: "l-00000001", caller: .none)
        let outside = t.home.appendingPathComponent("outside.txt")
        try "keep".write(to: outside, atomically: true, encoding: .utf8)
        let link = launched.deletingLastPathComponent().appendingPathComponent("l-00000002.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let removed = try TokenAccounts.removeFiles(context: t.context, label: "pool-a")
        #expect(removed.launchFiles == 1)
        #expect(fileText(outside) == "keep")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil)
    }

    @Test func refusesAnInstallOverALinkedTokenFile() throws {
        let t = try TestHome()
        _ = try TokenAccounts.install(
            context: t.context, label: "pool-a", token: Canaries.oauth())
        let file = try TokenPaths.fileURL(context: t.context, label: "pool-a")
        let outside = t.home.appendingPathComponent("outside.txt")
        try "keep".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        #expect(throws: ToolError.self) {
            try TokenAccounts.install(context: t.context, label: "pool-a", token: Canaries.oauth())
        }
        #expect(fileText(outside) == "keep")
    }
}

private func dataText(_ t: TestHome, skipping: URL) -> String {
    guard
        let walker = FileManager.default.enumerator(
            at: t.context.dataRoot, includingPropertiesForKeys: [.isRegularFileKey])
    else { return "" }
    var text = ""
    for case let url as URL in walker
    where url.resolvingSymlinksInPath().path != skipping.resolvingSymlinksInPath().path {
        text += fileText(url)
    }
    return text
}

@Suite struct TokenCaptureRunTests {
    /// The person's own environment: a home and a path, which the child needs to run at all.
    func ambient(_ t: TestHome, extra: [String: String] = [:]) -> [String: String] {
        ["HOME": t.home.path, "PATH": "/usr/bin:/bin"].merging(extra) { _, new in new }
    }

    /// `login` saves a token only for a token account in the registry.
    func register(_ t: TestHome, _ label: String = "pool-a") throws {
        try ConfigStore(context: t.context).save(
            Config(accounts: [Account(label: label, kind: Kind.token, role: Role.pool)]))
    }

    func run(_ t: TestHome, label: String = "pool-a", extra: [String: String] = [:]) throws
        -> TokenCapture.Result
    {
        let context = t.context(ambient: ambient(t, extra: extra))
        return try TokenCapture.capture(
            context: context, label: label, runner: ClaudeRunner(context: context))
    }

    @Test func capturesFromTheChildAndNeverShowsTheToken() throws {
        for token in [Canaries.oauth(), Canaries.oauthRealShape()] {
            let t = try TestHome()
            try t.installFake()
            try t.fake("setup-token.out", "Visit the page to approve.\nYour token is \(token)\n")
            try t.fake("setup-token.err", "note \(token)\n")
            try register(t)
            let result = try run(t)
            #expect(result.length == token.count)
            #expect(!result.replaced)
            let file = try TokenPaths.fileURL(context: t.context, label: "pool-a")
            #expect(mode(file) == 0o600)
            #expect(fileText(file).contains(token))
            // The token is in the token file and nowhere else under the data folder.
            #expect(!dataText(t, skipping: file).contains(token))
            #expect(t.fakeRecord("args.log").contains("setup-token"))
            let names = t.fakeRecord("env-names.txt")
            #expect(!names.contains(ProtectedEnv.tokenVariable))
            #expect(t.fakeRecord("config-dir.txt").contains("unset"))
        }
    }

    /// A terminal stand-in that counts its reads and hands back `line`.
    func terminal(echoOff: Bool, line: String, reads: HookCalls) -> PasteTerminal {
        PasteTerminal(
            isTerminal: { true }, echoOff: { echoOff ? termios() : nil }, restore: { _ in },
            readLine: {
                reads.add("read")
                return line
            })
    }

    @Test func pasteRefusesWhenEchoCannotBeTurnedOffAndReadsNothing() throws {
        let t = try TestHome()
        try register(t)
        let token = Canaries.oauth()
        let reads = HookCalls()
        do {
            _ = try TokenCapture.pasted(
                context: t.context, label: "pool-a",
                terminal: terminal(echoOff: false, line: token, reads: reads))
            Issue.record("expected a refusal")
        } catch let error as ToolError {
            #expect(error.message.contains("Could not hide the input"))
            #expect(!error.message.contains(token))
        }
        #expect(reads.labels.isEmpty)
        let file = try TokenPaths.fileURL(context: t.context, label: "pool-a")
        #expect(!FileManager.default.fileExists(atPath: file.path))

        // The same stand-in with echo off reads once and saves, so the refusal is the echo rule.
        let saved = try TokenCapture.pasted(
            context: t.context, label: "pool-a",
            terminal: terminal(echoOff: true, line: token, reads: reads))
        #expect(saved.length == token.count)
        #expect(reads.labels == ["read"])
        #expect(fileText(file).contains(token))
    }

    @Test func noTokenInTheOutputIsAnErrorThatHoldsNoOutput() throws {
        let t = try TestHome()
        try t.installFake()
        let secret = Canaries.apiKey()
        try t.fake("setup-token.out", "something else \(secret)\n")
        do {
            _ = try run(t)
            Issue.record("expected an error")
        } catch let error as ToolError {
            #expect(!error.message.contains(secret))
            #expect(error.message.contains("--paste"))
        }
        #expect(!FileManager.default.fileExists(atPath: t.context.dataRoot.path))
    }

    @Test func aProtectedVariableInTheParentNeverReachesTheChild() throws {
        let t = try TestHome()
        try t.installFake()
        try t.fake("setup-token.out", Canaries.oauth() + "\n")
        try register(t)
        _ = try run(
            t,
            extra: [
                ProtectedEnv.tokenVariable: Canaries.oauth(), "CLAUDE_CONFIG_DIR": "/tmp/elsewhere",
                "ANTHROPIC_API_KEY": Canaries.apiKey(),
            ])
        let names = t.fakeRecord("env-names.txt")
        #expect(!names.contains(ProtectedEnv.tokenVariable))
        #expect(!names.contains("CLAUDE_CONFIG_DIR"))
        #expect(!names.contains("ANTHROPIC_API_KEY"))
    }
}

@Suite struct TokenDuplicateTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func reading(week: TimeInterval, five: TimeInterval) -> Reading {
        Reading(
            readAt: now,
            windows: [
                WindowName.sevenDay: WindowReading(
                    usedPercent: 10, resetsAt: now.addingTimeInterval(week), readAt: now),
                WindowName.fiveHour: WindowReading(
                    usedPercent: 5, resetsAt: now.addingTimeInterval(five), readAt: now),
            ], fable: nil)
    }

    let accounts = [
        Account(label: "main", kind: Kind.login, role: Role.pool),
        Account(label: "pool-a", kind: Kind.token, role: Role.pool),
        Account(label: "pool-b", kind: Kind.token, role: Role.pool),
    ]

    @Test func bothResetTimesEqualNamesTheOtherLabel() {
        let readings = [
            "main": reading(week: 400_000, five: 9_000),
            "pool-a": reading(week: 400_000, five: 9_000),
        ]
        #expect(
            TokenKind.possibleDuplicate(
                of: "pool-a", accounts: accounts, readings: readings, now: now) == "main")
    }

    @Test func oneEqualTimeIsNotEnough() {
        let readings = [
            "main": reading(week: 400_000, five: 9_000),
            "pool-a": reading(week: 400_000, five: 12_000),
            "pool-b": reading(week: 300_000, five: 9_000),
        ]
        #expect(
            TokenKind.possibleDuplicate(
                of: "pool-a", accounts: accounts, readings: readings, now: now) == nil)
    }

    @Test func aMissingOrPastResetNeverMatches() {
        let past = [
            "main": reading(week: -10, five: -10), "pool-a": reading(week: -10, five: -10),
        ]
        #expect(
            TokenKind.possibleDuplicate(
                of: "pool-a", accounts: accounts, readings: past, now: now) == nil)
        let none = ["pool-a": reading(week: 400_000, five: 9_000)]
        #expect(
            TokenKind.possibleDuplicate(
                of: "pool-a", accounts: accounts, readings: none, now: now) == nil)
    }

    @Test func everyMatchIsReturnedNotOnlyTheFirst() {
        let readings = [
            "main": reading(week: 400_000, five: 9_000),
            "pool-a": reading(week: 400_000, five: 9_000),
            "pool-b": reading(week: 400_000, five: 9_000),
        ]
        #expect(
            TokenKind.possibleDuplicates(
                of: "pool-b", accounts: accounts, readings: readings, now: now)
                == ["main", "pool-a"])
    }

    @Test func anIdleSideWithNoFiveHourResetMatchesOnTheWeeklyTime() {
        var idle = reading(week: 400_000, five: 9_000)
        idle.windows[WindowName.fiveHour] = nil
        let readings = ["main": reading(week: 400_000, five: 9_000), "pool-a": idle]
        #expect(
            TokenKind.possibleDuplicates(
                of: "pool-a", accounts: accounts, readings: readings, now: now) == ["main"])
    }

    @Test func theTextNamesTheOtherLabel() {
        #expect(
            TokenKind.duplicateText("main")
                == "Same reset times as main. If this is the same account, remove one.")
    }
}

@Suite struct TokenExpiryTests {
    @Test func tokenCreatedAtBeatsTheFileTime() {
        let created = "2026-01-01T00:00:00Z"
        let account = Account(
            label: "pool-a", kind: Kind.token, role: Role.pool, tokenCreatedAt: created)
        let modified = Date(timeIntervalSince1970: 1_900_000_000)
        let start = TokenKind.createdAt(account, fileModified: modified)
        #expect(start == ISO8601DateFormatter().date(from: created))
        let bare = Account(label: "pool-a", kind: Kind.token, role: Role.pool)
        #expect(TokenKind.createdAt(bare, fileModified: modified) == modified)
        #expect(TokenKind.createdAt(bare, fileModified: nil) == nil)
    }

    @Test func aBadTokenCreatedAtFailsValidation() {
        var config = Config(accounts: [
            Account(
                label: "pool-a", kind: Kind.token, role: Role.pool, tokenCreatedAt: "yesterday")
        ])
        #expect(throws: ToolError.self) { try ConfigValidator.validate(config) }
        config.accounts[0].tokenCreatedAt = "2026-11-11T10:00:00Z"
        #expect(throws: Never.self) { try ConfigValidator.validate(config) }
        config.accounts[0].kind = Kind.login
        #expect(throws: ToolError.self) { try ConfigValidator.validate(config) }
    }
}
