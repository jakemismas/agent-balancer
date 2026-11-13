import Foundation

/// What the link manifest says about one folder account.
public enum FolderVerdict: Equatable, Sendable {
    /// Linked, and every listed link and target is as recorded.
    case ok
    /// No `link` run ever finished for this folder.
    case notLinked
    /// A listed link or its target is gone or changed.
    case broken(String)
}

public struct FolderFacts: Equatable, Sendable {
    public var verdict: FolderVerdict
    /// True when the account's list holds the shared settings link, so hook changes reach it.
    public var sharesSettings: Bool

    public init(verdict: FolderVerdict, sharesSettings: Bool) {
        self.verdict = verdict
        self.sharesSettings = sharesSettings
    }
}

/// The drift checks of docs/ARCHITECTURE.md section 5.7 for a folder account. Links and targets are
/// checked by metadata only: nothing inside a linked folder is listed or read, no inode or whole
/// file hash is compared, and no content is printed.
public enum Verifier {
    public struct Failure: Equatable, Sendable {
        public var code: StateCode
        /// The short reason `pick` shows for the skipped account.
        public var reason: String
        /// The text `verify` and `status` show.
        public var text: String
    }

    /// Checks 1 and 2: every shared source that exists is listed, and each listed link is still a symlink to its recorded target, and each target
    /// still exists, is owned by the user, and is a file (the two files) or a folder (the three
    /// folders). No process runs and no settings file is read.
    public static func linkFacts(context: ToolContext, label: String) -> FolderFacts {
        let hooks = HookRecord(context: context)
        guard hooks.isLinked(label) else {
            return FolderFacts(verdict: .notLinked, sharesSettings: false)
        }
        let entries = hooks.entries(for: label)
        let shares = hooks.sharesSettings(label)
        for entry in entries {
            let name = URL(fileURLWithPath: entry.path).lastPathComponent
            guard let item = SharedItems.all.first(where: { $0.name == name }) else {
                return FolderFacts(
                    verdict: .broken("a listed link is not one the tool makes"),
                    sharesSettings: shares)
            }
            guard hooks.isIntact(entry) else {
                return FolderFacts(
                    verdict: .broken("\(name) is no longer the recorded link"),
                    sharesSettings: shares)
            }
            var st = stat()
            guard stat(entry.target, &st) == 0 else {
                return FolderFacts(
                    verdict: .broken("the target of \(name) is missing"), sharesSettings: shares)
            }
            let kind = st.st_mode & S_IFMT
            let typeOk = item.isFolder ? kind == S_IFDIR : kind == S_IFREG
            guard typeOk, st.st_uid == context.ownerId else {
                return FolderFacts(
                    verdict: .broken("the target of \(name) is not yours or has changed type"),
                    sharesSettings: shares)
            }
        }
        if let name = hooks.firstUnlinkedSource(for: label) {
            return FolderFacts(
                verdict: .broken("\(name) exists in the default folder and is not linked"),
                sharesSettings: shares)
        }
        return FolderFacts(verdict: .ok, sharesSettings: shares)
    }

    /// The hook refusal text for a folder: it names `--all` because the folder is affected.
    static func folderSettingsText(_ issue: String) -> String {
        switch issue {
        case Messages.hookRecordMissing: return Messages.hookRecordMissingAll
        case Messages.settingsChanged: return Messages.settingsChangedAll
        default: return issue
        }
    }

    /// Checks 1 to 4 for one folder account. `settingsIssue` is what a reader already found in the
    /// default folder's settings against the record (nil when they match); it counts only when the
    /// folder shares the settings link. With `stopAtFirst` the first failure ends the check, so a
    /// pick never starts `claude` for an account that already failed.
    public static func failures(
        context: ToolContext, account: Account, runner: ClaudeRunner, settingsIssue: String?,
        now: Date, stopAtFirst: Bool
    ) -> (failures: [Failure], check: AccountCheck?) {
        var found: [Failure] = []
        let facts = linkFacts(context: context, label: account.label)
        switch facts.verdict {
        case .notLinked:
            found.append(
                Failure(
                    code: .notLinked, reason: "not linked", text: Messages.notLinked(account.label))
            )
        case .broken(let detail):
            found.append(
                Failure(
                    code: .settingsChanged, reason: "link broken",
                    text: Messages.linkBroken(account.label) + " "
                        + Display.safe(detail, limit: 120)))
        case .ok: break
        }
        if stopAtFirst, !found.isEmpty { return (found, nil) }
        if facts.verdict != .notLinked, facts.sharesSettings, let issue = settingsIssue {
            let text = folderSettingsText(issue)
            found.append(Failure(code: .settingsChanged, reason: text, text: text))
        }
        if stopAtFirst, !found.isEmpty { return (found, nil) }
        let check = FolderKind().check(account: account, runner: runner, now: now)
        for issue in check.issues where issue.severity == .error {
            found.append(
                Failure(
                    code: issue.code, reason: Display.safe(issue.text, limit: 200),
                    text: issue.text))
        }
        return (found, check)
    }
}
