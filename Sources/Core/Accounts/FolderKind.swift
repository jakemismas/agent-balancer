import Foundation

/// Where a folder account's config folder sits and the checks its path must pass.
public enum FolderPaths {
    /// The folder under the data folder that holds every account folder.
    static let accountsFolderName = "accounts"

    /// Folders under the data folder: `accounts/<label>/.claude`. The inner name is deliberate, so
    /// path rules written for Claude settings apply to the settings file inside.
    public static func folders(label: String) -> [String] {
        [accountsFolderName, label, ".claude"]
    }

    /// The pattern of docs/ARCHITECTURE.md section 5.2, plus no `.` or `..` segment.
    public static func isValidPath(_ path: String) -> Bool {
        guard
            path.range(of: #"\A/([A-Za-z0-9._-]+/)*[A-Za-z0-9._-]+\z"#, options: .regularExpression)
                != nil
        else { return false }
        return !path.split(separator: "/").contains { $0 == "." || $0 == ".." }
    }

    /// The absolute folder of one folder account. A path that is not absolute, has a `.` or `..`
    /// segment, or fails the folder pattern is refused. Nothing is created or opened.
    public static func configDir(context: ToolContext, label: String) throws -> URL {
        guard ConfigValidator.isValidLabel(label) else { throw ToolError("Label is not valid.") }
        var url = context.dataRoot
        for part in folders(label: label) { url.appendPathComponent(part, isDirectory: true) }
        guard isValidPath(url.path) else {
            throw ToolError(
                "The account folder path cannot be written safely into a command line. Move your home data to a path of letters, digits, dots, hyphens and underscores."
            )
        }
        return url
    }

    public enum FolderState: Equatable, Sendable {
        case missing
        /// A real folder owned by the user.
        case ready
        /// A link, a file, or a folder that another user owns.
        case refused
    }

    /// What opening the folder says, with no link followed at any level from the data folder
    /// down: a link in `accounts`, in `accounts/<label>` or on the folder itself is refused.
    public static func state(context: ToolContext, label: String) -> FolderState {
        do {
            let fd = try NoFollowWriter.openFolder(
                root: context.dataRoot, folders: folders(label: label), create: false,
                ownerId: context.ownerId)
            guard fd >= 0 else { return .missing }
            close(fd)
            return .ready
        } catch {
            return .refused
        }
    }

    /// The folder rules of an account entry: the path is absolute, plain and matches the folder
    /// pattern, and a folder that exists is a real folder owned by the user. A folder that does
    /// not exist yet passes.
    static func requireUsable(context: ToolContext, label: String) throws {
        _ = try configDir(context: context, label: label)
        if state(context: context, label: label) == .refused {
            throw ToolError(
                "Account '\(Display.safe(label, limit: 32))': its folder is a link, is wider than 0700 or is not owned by you. Make the folder mode 0700 and owned by you, or run `agent-balancer remove \(Display.safe(label, limit: 32))`."
            )
        }
    }

    /// A link target is written into the manifest and the folder. It must be absolute and plain.
    static func isLinkTargetText(_ path: String) -> Bool {
        path.hasPrefix("/")
            && path.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
    }

    /// True when the reported folder is this one, once links are resolved. A reported value with
    /// a `.` or `..` segment never matches. The runner redacts long random-looking runs in what it
    /// captures, so a `[redacted]` marker stands for text inside one path segment and never
    /// matches a `/`. Every segment without a marker must match literally. A reported value needs
    /// as many segments as the folder, a last segment with no marker, and at least one other
    /// segment with no marker. A marker in the label segment (the one before the last) matches
    /// only when the scrubber turns this label into that same text, which needs a label of 32 or
    /// more characters or one that holds the token prefix.
    static func sameFolder(_ reported: String, _ folder: URL) -> Bool {
        func plain(_ path: String) -> String {
            URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        }
        let wanted = [folder.standardizedFileURL.path, plain(folder.path)]
        guard reported.hasPrefix("/") else { return false }
        let given = reported.components(separatedBy: "/").dropFirst()
        guard !given.contains("."), !given.contains("..") else { return false }
        let marker = Scrubber.redacted
        guard reported.contains(marker) else {
            return wanted.contains(plain(reported)) || wanted.contains(reported)
        }
        guard !given.isEmpty, !given.contains(""),
            let last = given.last, !last.contains(marker),
            given.filter({ !$0.contains(marker) }).count >= 2
        else { return false }
        return wanted.contains { candidate in
            let have = candidate.components(separatedBy: "/").dropFirst()
            guard have.count == given.count else { return false }
            let labelAt = have.count - 2
            return zip(given, have).enumerated().allSatisfy { index, pair in
                // The label is what tells two account folders apart.
                if index == labelAt, pair.0.contains(marker) {
                    return Scrubber.tokenPass(pair.1) == pair.0
                }
                return segmentMatches(pair.0, pair.1)
            }
        }
    }

    /// One reported segment against one real segment. Text between markers must appear in order,
    /// the first piece at the start and the last at the end, with at least one character for
    /// each marker, two markers side by side included.
    private static func segmentMatches(_ reported: String, _ actual: String) -> Bool {
        let marker = Scrubber.redacted
        guard reported.contains(marker) else { return reported == actual }
        let pieces = reported.components(separatedBy: marker)
        guard let first = pieces.first, let last = pieces.last, actual.hasPrefix(first),
            actual.hasSuffix(last),
            actual.count >= first.count + last.count + (pieces.count - 1)
        else { return false }
        var rest = Substring(actual).dropFirst(first.count).dropLast(last.count)
        for middle in pieces.dropFirst().dropLast() {
            rest = rest.dropFirst()
            if middle.isEmpty { continue }
            guard let found = rest.range(of: middle) else { return false }
            rest = rest[found.upperBound...]
        }
        return pieces.count == 2 || !rest.isEmpty
    }
}

/// The `folder` kind: one Claude Code config folder per account, signed in once by the user.
public struct FolderKind: AccountKindHandler {
    public let kind = Kind.folder

    public init() {}

    public func check(account: Account, runner: ClaudeRunner, now: Date) -> AccountCheck {
        let dir: URL
        do {
            dir = try FolderPaths.configDir(context: runner.context, label: account.label)
        } catch let error as ToolError {
            return AccountCheck(issues: [Issue(.checkFailed, .error, error.message)])
        } catch {
            return AccountCheck(issues: [Issue(.checkFailed, .error, "Check failed.")])
        }
        guard FolderPaths.state(context: runner.context, label: account.label) == .ready else {
            return AccountCheck(
                issues: [
                    Issue(
                        .checkFailed, .error,
                        "Account folder is missing or not yours. Run `agent-balancer remove \(Display.safe(account.label, limit: 32))`, then add it again."
                    )
                ])
        }
        switch AuthStatusReader.read(runner: runner, configDir: dir) {
        case .failed(let issue):
            return AccountCheck(issues: [issue])
        case .status(let status):
            return Self.evaluate(status, account: account, folder: dir, now: now)
        }
    }

    /// The login checks of a `login` account, plus the one a folder adds: the sign-in must sit in
    /// this account's own folder.
    public static func evaluate(
        _ status: AuthStatus, account: Account, folder: URL, now: Date
    ) -> AccountCheck {
        guard status.loggedIn else {
            return AccountCheck(
                issues: [
                    Issue(
                        .loginRejected, .error,
                        "Login rejected. Run `agent-balancer login \(Display.safe(account.label, limit: 32))` in Terminal."
                    )
                ], emailDigest: account.emailDigest)
        }
        var check = LoginKind.evaluate(status, account: account, now: now)
        guard let reported = status.configDirectory, reported.hasPrefix("/") else {
            check.issues.insert(
                Issue(
                    .checkFailed, .error,
                    "Check failed: the folder of this sign-in could not be confirmed."),
                at: 0)
            return check
        }
        if !FolderPaths.sameFolder(reported, folder) {
            check.issues.insert(
                Issue(
                    .checkFailed, .error,
                    "Check failed: the sign-in is not in this account's own folder."),
                at: 0)
        }
        return check
    }
}
