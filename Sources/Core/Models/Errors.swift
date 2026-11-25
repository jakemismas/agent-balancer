import Foundation

/// Error and warning codes of the states table (docs/ARCHITECTURE.md section 9).
public enum StateCode: String, Codable, Sendable, CaseIterable {
    case loginRejected = "login_rejected"
    case wrongAccount = "wrong_account"
    case duplicateLogin = "duplicate_login"
    case settingsChanged = "settings_changed"
    case planChanged = "plan_changed"
    case accountEnded = "account_ended"
    case checkFailed = "check_failed"
    case limited
    case fableLimited = "fable_limited"
    case loginExpiring = "login_expiring"
    case tokenMissing = "token_missing"
    case notLinked = "not_linked"
    case possibleDuplicate = "possible_duplicate"
    case keyInSettings = "key_in_settings"
    case stale
    /// A live session names a launch file that is gone. A count only: no event, no path.
    case launchFileMissing = "launch_file_missing"
    /// A live session names a launch file that `lstat` cannot check, so it may hold a token. A
    /// count only: no event, no path.
    case launchFileUnchecked = "launch_file_unchecked"
}

public enum Severity: String, Sendable {
    case error
    case warning
}

/// One error or warning on an account or on the setup, with scrubbed text.
public struct Issue: Equatable, Sendable {
    public let code: StateCode
    public let severity: Severity
    public let text: String

    public init(_ code: StateCode, _ severity: Severity, _ text: String) {
        self.code = code
        self.severity = severity
        self.text = text
    }
}

/// A failure with a message that is safe to print as is.
public struct ToolError: Error, LocalizedError, Equatable, Sendable {
    public let code: StateCode?
    public let message: String

    public init(_ message: String, code: StateCode? = nil) {
        self.message = message
        self.code = code
    }

    public var errorDescription: String? { message }

    /// `error` with `more` after its text and with its code, for a step that failed and left
    /// something with a fix of its own.
    static func adding(_ more: String, to error: Error) -> ToolError {
        let tool = error as? ToolError
        return ToolError(
            (tool?.message ?? error.localizedDescription) + " " + more, code: tool?.code)
    }
}

public enum Messages {
    /// A consent command asked for a typed answer where no person can type one.
    public static let terminalRequired =
        "Applying needs an interactive terminal. Run this in your own terminal and type the label (or `accept`) when asked. Nothing was changed."
    public static let chatShellRefusal =
        "Run this in your own terminal, outside a Claude Code session."

    /// `remove` of the main account where no person is at a terminal, such as from the menu app.
    public static func removeMainNeedsTerminal(_ label: String) -> String {
        let safe = Display.safe(label, limit: 32)
        return
            "'\(safe)' is the main account. Removing it needs your own terminal: run `agent-balancer remove \(safe)` in Terminal. Nothing was changed."
    }
    public static let hookRecordMissing =
        "Hook record missing. Run `agent-balancer link --accept-source-change` in Terminal."
    public static let settingsChanged =
        "Settings changed. Run `agent-balancer link --accept-source-change` in Terminal."
    /// The same two texts when a folder account is affected too: `--all` covers every linked folder.
    public static let hookRecordMissingAll =
        "Hook record missing. Run `agent-balancer link --accept-source-change --all` in Terminal."
    public static let settingsChangedAll =
        "Settings changed. Run `agent-balancer link --accept-source-change --all` in Terminal."
    /// `run` found no verdict that matches the settings file as it is now.
    public static let settingsNotChecked =
        "Settings changed since the last check. Run `agent-balancer doctor` in Terminal."
    /// The default folder's settings path is a link to nothing, which no reader can clear.
    public static let settingsLinkGoesNowhere =
        "The default folder's settings file is a link that goes nowhere. Repair the link or remove it, then run `agent-balancer doctor` in Terminal."
    /// The default folder's settings path is a folder or another entry that is not a file.
    public static let settingsNotAFile =
        "The default folder's settings file is not a file. Replace it with a file or remove it, then run `agent-balancer doctor` in Terminal."
    /// A link change whose settings verdict failed or changed after the typed approval.
    public static let settingsMovedAfterApproval =
        "The default folder's settings changed after you approved, so nothing was changed."
    public static let keyInSettings =
        "Settings carry an API key or key helper. Every account is skipped."
    public static let notSetUp = "Setup has not run. Run `agent-balancer init`."

    public static func notLinked(_ label: String) -> String {
        "Settings not shared. Run `agent-balancer link \(Display.safe(label, limit: 32))` in Terminal."
    }

    public static func linkBroken(_ label: String) -> String {
        "A shared link is broken. Run `agent-balancer link --repair \(Display.safe(label, limit: 32))` in Terminal. If repair refuses, fix the item it names, in the default folder or in the account folder, then run it again."
    }

    /// What `verify` adds to the broken-link text when a listed link's default folder item now
    /// resolves elsewhere.
    public static func olderTargetDetail(_ name: String) -> String {
        "the link of \(name) points to an older target than the default folder's \(name)"
    }

    /// The reason `pick` and `run` give for such a link.
    public static func olderTarget(_ label: String, _ name: String) -> String {
        "The link of \(name) points to an older target. Run `agent-balancer link --repair \(Display.safe(label, limit: 32))` in Terminal."
    }

    /// What a check says when a listed link's default folder item exists but no longer resolves:
    /// `link --repair` refuses such an item until it is fixed.
    public static func unresolvedItem(_ label: String, _ name: String) -> String {
        "The default folder's \(name) no longer resolves. Fix it there first, then run `agent-balancer link --repair \(Display.safe(label, limit: 32))` in Terminal."
    }

    /// What a check says when `lstat` cannot check a listed link's default folder item, as when
    /// its access list denies `readattr`. It may be a link, so `-h` keeps each command on the
    /// item itself. `link --repair` is not named: `link` would read the item as gone and drop
    /// its link.
    public static func uncheckedItem(_ name: String, _ place: String) -> String {
        "The default folder's \(name) cannot be checked, so the tool cannot tell where it resolves. Run `chmod -h -N \(place)`, or `chmod -N \(place)` if that says Permission denied, in Terminal. Run `chflags -h nouchg,nouappnd \(place)` first if it is locked."
    }

    public static let oneAccountPerFolder =
        "Never sign a different account into a folder that already has chats. Add a new folder for the new account instead."

    /// `login` over a folder sign-in its last probe found rejected, when the run cannot show that
    /// it signed the folder in again.
    public static func signInNotRenewed(_ label: String) -> String {
        let safe = Display.safe(label, limit: 32)
        return
            "This run did not show a new sign-in, so the probe's rejection stands. Run `agent-balancer login \(safe) --browser`, or `agent-balancer refresh --label \(safe) --force` once it is signed in."
    }

    /// `login --browser` for a folder whose expected email fails `ConfigValidator.isPlainEmail`.
    public static func emailNotPlain(_ label: String) -> String {
        "The expected email of '\(Display.safe(label, limit: 32))' cannot be passed to claude safely. Fix it with `agent-balancer config set`."
    }

    /// The `wrong_account` text, and the one step that fixes it.
    public static let wrongAccount = "Folder is logged in as another account."
    /// A sign-in that reports no email cannot be matched to the account's expected email.
    public static let signInEmailMissing =
        "Check failed: the sign-in reported no email, so it could not be confirmed as this account."
    /// A login or folder account that holds no email cannot be checked against its sign-in.
    public static let emailNotRecorded =
        "Check failed: no email is recorded for this account, so its sign-in cannot be confirmed."
    public static let signExpectedBackIn =
        "Sign the expected account back in to this folder. Do not relabel the folder."
    /// The same step for a login account, the default folder's own sign-in.
    public static let signExpectedBackInLogin =
        "Run claude and sign the expected account back in."

    /// `uninstall` with a data folder that is a link, which it never follows.
    public static let uninstallDataFolderIsALink = uninstallFolderIsALink(
        "The data folder", "~/.agent-balancer")
    /// `uninstall` with something other than a folder where the data folder belongs.
    public static let uninstallDataFolderIsNotAFolder = uninstallFolderIsNotAFolder(
        "~/.agent-balancer")
    /// `uninstall` with a data folder that another user owns.
    public static let uninstallDataFolderIsNotYours =
        "The data folder `~/.agent-balancer` belongs to another user, so `uninstall` cannot check what the tool made there. Nothing was removed. Run `agent-balancer uninstall` as that user."

    /// `uninstall` with a link where a folder of the tool belongs, which it never follows.
    /// `place` is the folder's path as the person types it.
    public static func uninstallFolderIsALink(_ subject: String, _ place: String) -> String {
        "\(subject) `\(place)` is a link, and `uninstall` never follows one, so it cannot check what the tool made. Nothing was removed. Move the folder it points to back in place of the link, or delete the link if that folder is gone, then run `agent-balancer uninstall` again."
    }

    /// `uninstall` with something other than a folder or a link where a folder of the tool
    /// belongs.
    public static func uninstallFolderIsNotAFolder(_ place: String) -> String {
        "`\(place)` is not a folder, and the tool only ever makes a folder there, so `uninstall` cannot check it. Nothing was removed. Check what it is and move it away, then run `agent-balancer uninstall` again."
    }

    /// Why `uninstall` refuses `entry` where the folder `place` in the data folder belongs, or nil
    /// when it is missing or a real folder of the user's that passes the folder checks.
    public static func uninstallRefusal(
        _ subject: String, _ place: String, _ entry: NoFollowWriter.PlaceEntry
    ) -> String? {
        switch entry {
        case .missing, .folder:
            return nil
        case .link:
            return uninstallFolderIsALink(subject, place)
        case .notFolder:
            return uninstallFolderIsNotAFolder(place)
        case .notYours:
            return
                "\(subject) `\(place)` belongs to another user, so `uninstall` cannot check what the tool made in it. Nothing was removed. Move it out of `~/.agent-balancer`, then run `agent-balancer uninstall` again."
        case .problem(let problem):
            return uninstallFolderRefused(subject, place, problem)
        }
    }

    /// `uninstall` with a folder of the user's that fails the folder checks. `place` is the
    /// folder's path as the person types it. One wider than 0700, one whose access list lets
    /// another user or group in, or one that cannot be opened or searched, is a real folder whose
    /// mode `lstat` read, never a link, so its commands take no `-h`, and `chmod -N` clears its
    /// access list without opening it. An entry `lstat` cannot check may be a link, so `-h` keeps
    /// each command on the entry itself; `chmod -h -N` opens the entry, so the text names
    /// `chmod -N` for one whose access list also denies its owner `read`, and `-N` goes first
    /// because `chmod 700` fails while `lstat` does.
    public static func uninstallFolderRefused(
        _ subject: String, _ place: String, _ problem: NoFollowWriter.FolderProblem
    ) -> String {
        switch problem {
        case .widerThanPrivate:
            return
                "\(subject) `\(place)` is wider than 0700, so `uninstall` cannot check what the tool made in it. Nothing was removed. Run `chmod 700 \(place)`, then run `agent-balancer uninstall` again."
        case .sharedByAccessList:
            return
                "\(subject) `\(place)` has an access list that lets another user or group in, or that cannot be read, so `uninstall` cannot check what the tool made in it. Nothing was removed. Run `chmod -N \(place)`, then run `agent-balancer uninstall` again."
        case .cannotOpen:
            return
                "\(subject) `\(place)` cannot be opened or searched, so `uninstall` cannot check what the tool made in it. Nothing was removed. Run `chmod -N \(place)`, then `chmod 700 \(place)`, then run `agent-balancer uninstall` again."
        case .cannotCheck:
            return
                "\(subject) `\(place)` cannot be checked, so `uninstall` cannot tell what it is or what the tool made in it. Nothing was removed. Run `chmod -h -N \(place)`, or `chmod -N \(place)` if that says Permission denied, then `chmod -h 700 \(place)`, then run `agent-balancer uninstall` again."
        }
    }

    /// What every command that opens a folder of the tool's says when the folder's access list
    /// lets another user or group in, or cannot be read. The folder opened as a real folder, so
    /// plain `chmod -N` acts on it. It names the fix and no next command, since after a saved
    /// token the next one is not the one that ran.
    public static func folderSharedByAccessList(_ place: String) -> String {
        "Refused `\(place)`: its access list lets another user or group in, or cannot be read. Run `chmod -N \(place)` in Terminal."
    }

    /// What every command that would start `claude`, and the menu app's lookup of the command
    /// line tool, says when the access list of the binary's real target, the file that the path
    /// at `shown` resolves to, lets another user or group change it or cannot be read. `fix` is
    /// the sentence that clears that list.
    public static func claudeSharedByAccessList(_ shown: String, fix: String) -> String {
        "Refused \(shown): its real target's access list lets another user or group change it, or cannot be read. \(fix)"
    }

    /// The same for `~/.local/bin` when the binary sits there.
    public static func claudeFolderSharedByAccessList(_ shown: String, fix: String) -> String {
        "Refused \(shown): its folder's access list lets another user or group change it, or cannot be read. \(fix)"
    }

    /// What every command that would start `claude` says when the folder that holds the binary's
    /// real target, `place` as a person types it, is not owned by the user or root or is writable
    /// by group or others. `fix` is the sentence that clears that mode, when one is known to.
    public static func claudeTargetFolderRefused(_ shown: String, _ place: String, fix: String?)
        -> String
    {
        "Refused \(shown): its real target's folder `\(place)` must be owned by you or root and not writable by others."
            + (fix.map { " " + $0 } ?? "")
    }

    /// The same when the access list of that folder lets another user or group change it, or
    /// cannot be read. `fix` is the sentence that clears that list.
    public static func claudeTargetFolderSharedByAccessList(
        _ shown: String, _ place: String, fix: String
    ) -> String {
        "Refused \(shown): the access list of its real target's folder `\(place)` lets another user or group change it, or cannot be read. \(fix)"
    }

    /// What every command that would start `claude`, and the menu app's lookup of the command
    /// line tool, says when the lookup of what `what` names stops: the binary (`it`),
    /// `~/.local/bin` or the folder that holds the real target. `because` says where, when a step
    /// can be named, and `fix` is the command that lets the lookup through, when one is known to.
    public static func claudeUnchecked(
        _ shown: String, what: String, because: String?, fix: String?
    ) -> String {
        let why = because.map { ", because " + $0 } ?? ""
        return "Refused \(shown): \(what) cannot be checked\(why)." + (fix.map { " " + $0 } ?? "")
    }

    /// What every command that opens a folder of the tool's says when it refuses the folder, with
    /// its fix. A link is never given a `chmod`, which would act on what it points to.
    public static func folderRefused(_ place: String, _ why: NoFollowWriter.FolderRefusal)
        -> String
    {
        switch why {
        case .linkOrNotFolder:
            return
                "Refused `\(place)`: it is a link or not a folder, and the tool never follows a link. Move what is there out of the way, or move the folder a link points to back in its place."
        case .cannotOpen:
            return
                "Refused `\(place)`: it cannot be opened or searched. Run `chmod -N \(place)`, then `chmod 700 \(place)` in Terminal."
        case .cannotMake:
            guard let cut = place.lastIndex(of: "/"), place != NoFollowWriter.dataFolderPlace
            else { return "Refused `\(place)`: it is missing and could not be made." }
            let above = String(place[..<cut])
            return
                "Refused `\(place)`: it is missing and could not be made in `\(above)`. Run `chmod -N \(above)`, then `chmod 700 \(above)` in Terminal."
        case .notYours:
            return
                "Refused `\(place)`: it belongs to another user, so the tool does not use it. Move it out of the way."
        case .widerThanPrivate:
            return
                "Refused `\(place)`: it is wider than 0700. Run `chmod 700 \(place)` in Terminal."
        case .sharedByAccessList:
            return folderSharedByAccessList(place)
        }
    }

    /// What a check before a write says about a folder of the tool's in which the tool cannot make
    /// and delete what it writes there, as an entry that denies the user adding or deleting
    /// files makes.
    public static func folderNotWritable(_ place: String) -> String {
        "Refused `\(place)`: the tool cannot make and delete what it writes in it. Run `chmod -N \(place)`, then `chmod 700 \(place)` in Terminal, and `chflags nouchg \(place)` first if it is locked."
    }

    /// What a command says about a folder of the tool's it cannot mark as excluded from backups,
    /// as an entry that denies the user writing its extended attributes makes.
    static func notExcludedFromBackup(_ place: String) -> String {
        "Refused `\(place)`: it cannot be marked as excluded from backups. Run `chmod -N \(place)` in Terminal."
    }

    /// What a probe says about its folder when it holds something the tool did not make there.
    static func holdsForeignEntry(_ place: String) -> String {
        "Refused `\(place)`: it holds something that is not a probe folder. Move what the tool did not make out of it."
    }

    /// What a check before a write says about a name the tool writes that is not a regular file
    /// of the user's, which the writer never replaces or follows.
    public static func notReplaceable(_ place: String) -> String {
        fileRefused("`\(place)`", place, .notRegular, "replace or delete it")
    }

    /// What a check before a write says about a file of the tool's that a later step replaces or
    /// deletes and could not, by the cause, with its fix. `subject` is what the text calls the
    /// file and `path` the path its commands take, which differ only for a launch file, named by
    /// its folder; `action` is what the tool could not do.
    public static func fileRefused(
        _ subject: String, _ path: String, _ why: NoFollowWriter.FileRefusal, _ action: String
    ) -> String {
        switch why {
        case .notRegular:
            let use = action == "read it" ? "read" : "write"
            return
                "Refused \(subject): it is not a regular file of yours, so the tool does not \(use) it. Move it out of the way."
        case .flagged(let flags):
            return flagged(subject, path, flags, action)
        case .deleteDenied:
            return
                "Refused \(subject): its access list does not let the tool \(action). Run `chmod -N \(path)` in Terminal."
        case .unchecked:
            return
                "Refused \(subject): it cannot be checked, so the tool cannot tell whether it can \(action). Run `chmod -h -N \(path)`, or `chmod -N \(path)` if that says Permission denied, in Terminal."
        }
    }

    /// What a check says about a file or folder of the tool's that a flag locks: the user's own
    /// flags with the `chflags` that clears them, or a system flag, which only an administrator
    /// can clear.
    public static func flagged(
        _ subject: String, _ path: String, _ flags: NoFollowWriter.FileFlags, _ action: String
    ) -> String {
        guard !flags.user.isEmpty else {
            return
                "Refused \(subject): a system flag on it does not let the tool \(action), and only an administrator can clear that flag."
        }
        let names = flags.user.map { "`\($0)`" }.joined(separator: " and ")
        let noun = flags.user.count == 1 ? "flag" : "flags"
        let clear = flags.user.map { "no" + $0 }.joined(separator: ",")
        let also =
            flags.system
            ? " A system flag is also set, which only an administrator can clear." : ""
        return
            "Refused \(subject): it has the \(names) \(noun) set, so the tool cannot \(action). Run `chflags \(clear) \(path)` in Terminal.\(also)"
    }

    /// What a check before a write says about a folder of the tool's whose new files and
    /// folders take an inherited access list entry that keeps the tool from reading, writing or
    /// checking them, as one that denies the user `read`, `write` or `readsecurity` does.
    /// `chmod -N` on the folder drops the inheritable entry.
    public static func folderGivesClosedFiles(_ place: String) -> String {
        "Refused `\(place)`: what the tool makes in it takes an access list that keeps the tool from reading, writing or checking it. Run `chmod -N \(place)` in Terminal."
    }

    /// What a check before a read says about a file of the tool's that the reader cannot open,
    /// by an access list entry or by its mode.
    public static func fileNotReadable(_ subject: String, _ path: String) -> String {
        "Refused \(subject): the tool cannot read it. Run `chmod -N \(path)`, then `chmod 600 \(path)` in Terminal."
    }

    /// What a check before a read says about a file of the tool's larger than the tool reads.
    public static func fileTooLarge(_ subject: String) -> String {
        "Refused \(subject): it is larger than any file the tool writes there. Move it out of the way."
    }

    /// What `login` prints for a new token the service rejects at its first check: one more
    /// check first, since a rejection can pass, and a new sign-in only when the service rejects
    /// the token again.
    public static func newTokenRejected(_ label: String) -> String {
        let safe = Display.safe(label, limit: 32)
        return
            "The service rejected the new token for '\(safe)'. Run `agent-balancer refresh --label \(safe)` once; if the service rejects it again, run `agent-balancer login \(safe)` in Terminal."
    }

    /// What `login` prints when its first check could not use the token file it just saved, such
    /// as one changed or moved meanwhile: the token was saved, so `doctor` names what to fix.
    public static func savedTokenNotUsable(_ label: String) -> String {
        "The token file of '\(Display.safe(label, limit: 32))' could not be used for the first check. Run `agent-balancer doctor` in Terminal."
    }

    /// What `login` says when the account was removed while the person signed in.
    static func accountGoneTokenNotSaved(_ label: String) -> String {
        "No account is labelled '\(Display.safe(label))' any more, so the token was not saved."
    }

    /// What `login` adds when a step after the sign-in refuses before the new token is saved,
    /// as only a change made while the person signed in or a lock held that long can make it.
    public static func tokenNotSaved(_ label: String) -> String {
        let safe = Display.safe(label, limit: 32)
        return
            "The new token for '\(safe)' was not saved. Once the above is fixed, run `agent-balancer login \(safe)` again."
    }

    /// What a check before a write adds when the file or folder it made to test a folder stays
    /// there after the refusal, as an entry on the folder that denies deleting what is in it
    /// keeps it. It is empty, and its own access list is cleared unless that clear is what
    /// failed.
    public static func checkLeft(_ place: String, folder: Bool) -> String {
        "The check left the empty \(folder ? "folder" : "file") `\(place)` there; move it out of the way once that is done."
    }

    /// What `login` says once the new token is saved and a step after the save did not finish.
    /// It names the command that finishes the job, never a new sign-in.
    public static func tokenSavedNoSignIn(_ label: String) -> String {
        let safe = Display.safe(label, limit: 32)
        return
            "The new token for '\(safe)' is saved, so no new sign-in is needed. Once the above is fixed, run `agent-balancer refresh --label \(safe)` to check it."
    }

    /// What a folder account's `login` says when its sign-in worked and the plan it found could
    /// not be saved. The next `refresh` that checks the sign-in records it.
    public static func planNotRecorded(_ label: String, _ reason: String) -> String {
        let safe = Display.safe(label, limit: 32)
        return
            "'\(safe)' is signed in, but its plan could not be recorded: \(reason) Once that is fixed, run `agent-balancer refresh --label \(safe)`, which records it; no new sign-in is needed."
    }

    /// The save's own step after the token file: its time. The config keeps the time saved
    /// before, for the token the new one replaced, so the estimated end can show early, never
    /// late.
    static func tokenDateNotSaved(_ reason: String) -> String {
        "The time the new token was made could not be saved in `~/.agent-balancer/config.json`, so its estimated end still counts from the time saved before, or from the token file's last change when there is none, and may show early: \(reason)"
    }

    static func launchFilesNotRewritten(_ label: String, _ reason: String) -> String {
        "Launch files of '\(Display.safe(label, limit: 32))' could not all be rewritten with the new token, so a session that uses one keeps the old token until it ends: \(reason)"
    }

    /// `items` as a sentence lists them: `a`, `a and b`, `a, b and c`.
    static func listed(_ items: [String]) -> String {
        items.count > 1
            ? items.dropLast().joined(separator: ", ") + " and " + (items.last ?? "")
            : items.joined()
    }

    /// What a token save and `refresh` say about the writer's temporary files they could not
    /// delete in the folder `place`, as a person types it, each by its path, since each may hold
    /// a token.
    static func temporariesNotDeleted(place: String, names: [String]) -> String {
        let one = names.count == 1
        let paths = names.map { "`" + place + "/" + $0 + "`" }
        return
            "\(names.count) temporary \(one ? "file" : "files") the writer left in `\(place)` could not be deleted and may hold a token: \(listed(paths)). "
            + temporaryFix(place: place, one: one)
    }

    /// What `doctor` says about the writer's temporary files in the folder `place` that may hold
    /// a token and that the upkeep `refresh` runs cannot delete, each by its path.
    static func temporariesStuck(place: String, names: [String]) -> String {
        let one = names.count == 1
        let paths = names.map { "`" + place + "/" + $0 + "`" }
        return
            "\(names.count) temporary \(one ? "file" : "files") the writer left in `\(place)` may hold a token, and `agent-balancer refresh` cannot delete \(one ? "it" : "them"): \(listed(paths)). "
            + temporaryFix(place: place, one: one)
            + " Then run `agent-balancer refresh`, which deletes \(one ? "it" : "them")."
    }

    /// What the writer adds to the error of a write that stopped and could not delete its
    /// temporary file `name` in the folder `place`, as a person types it. The file may hold
    /// `holding`, or what was written when that is nil, so the text names it by its path with
    /// the commands that let the tool delete it. A file that holds a token is in a folder whose
    /// writer leftovers the upkeep of `refresh` deletes. With no `place`, it names the file alone.
    static func temporaryLeft(place: String?, name: String, holding: String?) -> String {
        guard let place else { return "Its temporary file `\(name)` could not be deleted." }
        return
            "Its temporary file `\(place)/\(name)` could not be deleted and may hold \(holding ?? "what was written"). "
            + temporaryFix(place: place, one: true) + temporaryThen(holding)
    }

    /// What the writer adds to the error of a write that stopped right after it made its
    /// temporary file `name` in the folder `place`, before the first byte, and could not delete
    /// it: the file is empty, so the text says so, with the commands and the last step of
    /// `temporaryLeft`. With no `place`, it names the file alone.
    static func emptyTemporaryLeft(place: String?, name: String, holding: String?) -> String {
        guard let place else { return "Its empty temporary file `\(name)` could not be deleted." }
        return
            "Its empty temporary file `\(place)/\(name)` could not be deleted. "
            + temporaryFix(place: place, one: true) + temporaryThen(holding)
    }

    /// The step after the commands of `temporaryLeft`: a file of a write that holds a token is in
    /// a folder whose writer leftovers the upkeep of `refresh` deletes.
    private static func temporaryThen(_ holding: String?) -> String {
        holding == nil
            ? " Then move it out of the way."
            : " Then run `agent-balancer refresh`, which deletes it."
    }

    /// What `refresh` says, when its upkeep did not run, about the writer's temporary files in
    /// the folder `place` that may hold a token and that a delete would not fail on, each by its
    /// path.
    static func temporariesKept(place: String, names: [String]) -> String {
        let one = names.count == 1
        let paths = names.map { "`" + place + "/" + $0 + "`" }
        return
            "\(names.count) temporary \(one ? "file" : "files") the writer left in `\(place)` may hold a token: \(listed(paths)). `agent-balancer refresh` deletes \(one ? "it" : "them") once its upkeep runs."
    }

    /// What `refresh` says when its launch file upkeep did not run, so it deleted nothing, with
    /// `why`: the cause and its fix.
    static func upkeepNotRun(_ why: String) -> String {
        "The launch file upkeep did not run, so this refresh deleted no launch file or temporary file: \(why)"
    }

    /// Why the upkeep did not run when another command held the pick lock past the wait.
    static let upkeepLockBusy =
        "another command held the pick lock. Run `agent-balancer refresh` again once it ends."

    /// What a probe says when it cannot lock the folder it made in `place`. Each probe locks its
    /// own so that no cleanup removes it while the probe runs; an inherited entry that keeps the
    /// new folder from being opened stops the lock.
    static func probeFolderNotLocked(_ place: String) -> String {
        "Refused `\(place)`: a probe folder made in it cannot be locked, so another command could remove it while its probe runs. Run `chmod -N \(place)` in Terminal."
    }

    /// The commands that let the tool delete the writer's temporary files in the folder `place`:
    /// a lock or an append-only flag on the folder or a file goes first; then `chmod -h -N`
    /// clears the folder's entries, `chmod -h 700` a mode that keeps a delete out, and on each
    /// file `chmod -h -N` its list, or `chmod -N` one that also denies `read`. `-h` keeps each
    /// command on the entry itself.
    static func temporaryFix(place: String, one: Bool) -> String {
        let each = one ? "that file" : "each of these files"
        return
            "Run `chflags -h nouchg,nouappnd` first on `\(place)` and on \(one ? "that file if either is locked" : "each of these files that is locked"). Then run `chmod -h -N \(place)` and `chmod -h 700 \(place)`, and on \(each) `chmod -h -N`, or `chmod -N` \(one ? "if" : "where") that says Permission denied."
    }

    static func launchLeftoversNotDeleted(_ label: String, _ reason: String) -> String {
        "Temporary files the writer left in the launch folder of '\(Display.safe(label, limit: 32))' could not be deleted, and one may hold a token: \(reason)"
    }

    /// What a command says about a lock file of the tool's that does not open for writing.
    public static func lockFileNotOpened(_ place: String) -> String {
        "Refused `\(place)`: the lock file cannot be opened. Run `chmod -N \(place)`, then `chmod 600 \(place)` in Terminal."
    }

    /// What a check before a write says about a file of the tool's that does not open to take
    /// another line.
    public static func fileNotWritable(_ place: String) -> String {
        "Refused `\(place)`: it cannot be opened to write. Run `chmod -N \(place)`, then `chmod 600 \(place)` in Terminal, and `chflags nouchg \(place)` first if it is locked."
    }

    /// What `doctor` says about a folder of the tool's whose access list lets another user or
    /// group in, or cannot be read. What is in it is checked in the same run.
    public static func doctorFolderShared(_ place: String) -> String {
        "`\(place)` has an access list that lets another user or group in, or that cannot be read, so the tool refuses it. Run `chmod -N \(place)` in Terminal, then run `agent-balancer doctor` again."
    }

    /// What `doctor` says about a folder of the tool's that the folder checks refuse for its mode
    /// or its access list, both when both apply, or that cannot be opened, searched or checked,
    /// with the commands `uninstall` gives such a folder. What is in a folder it can open is
    /// checked in the same run; in one it cannot, once its commands have run.
    public static func doctorFolderProblem(
        _ place: String, _ problem: NoFollowWriter.FolderProblem, alsoShared: Bool = false
    ) -> String {
        switch problem {
        case .widerThanPrivate where alsoShared:
            return
                "`\(place)` is wider than 0700 and has an access list that lets another user or group in, or that cannot be read, so the tool refuses it. Run `chmod 700 \(place)` and `chmod -N \(place)` in Terminal, then run `agent-balancer doctor` again."
        case .widerThanPrivate:
            return
                "`\(place)` is wider than 0700, so the tool refuses it. Run `chmod 700 \(place)` in Terminal, then run `agent-balancer doctor` again."
        case .sharedByAccessList:
            return doctorFolderShared(place)
        case .cannotOpen:
            return
                "`\(place)` cannot be opened or searched, so the tool refuses it, and what is in it is checked once it opens. Run `chmod -N \(place)`, then `chmod 700 \(place)`, then run `agent-balancer doctor` again."
        case .cannotCheck:
            return
                "`\(place)` cannot be checked, so the tool cannot tell what it is, and what is in it is checked once it can. Run `chmod -h -N \(place)`, or `chmod -N \(place)` if that says Permission denied, then `chmod -h 700 \(place)`, then run `agent-balancer doctor` again."
        }
    }

    /// What `doctor` says about an entry where a folder of the tool's belongs that every command
    /// refuses without opening it: a link, which is never followed and never given a `chmod`, a
    /// file, or another user's folder, each with its fix. Nil for anything else.
    public static func doctorFolderNotUsed(_ place: String, _ entry: NoFollowWriter.PlaceEntry)
        -> String?
    {
        switch entry {
        case .link:
            return
                "`\(place)` is a link, which the tool never follows, so it refuses it. Move the folder the link points to back in its place, then run `agent-balancer doctor` again."
        case .notFolder:
            return
                "`\(place)` is not a folder, so the tool refuses it. Move it out of the way, then run `agent-balancer doctor` again."
        case .notYours:
            return
                "`\(place)` belongs to another user, so the tool refuses it. Move it out of the way, then run `agent-balancer doctor` again."
        default:
            return nil
        }
    }

    /// What `doctor` says about the probe folder when it holds something that is not a probe's
    /// folder, which every probe refuses.
    public static func doctorHoldsForeignEntry(_ place: String) -> String {
        "`\(place)` holds something that is not a probe folder, so every probe refuses it. Move what the tool did not make out of it, then run `agent-balancer doctor` again."
    }

    /// What `doctor` says about a file of the tool's whose access list may let another user or
    /// group in. A file `lstat` showed is a regular file, so plain `chmod -N` acts on it; one
    /// `lstat` cannot check may be a link, so `-h` keeps `chmod` on the entry itself.
    public static func doctorFileProblem(
        _ place: String, _ problem: NoFollowWriter.FileListProblem
    ) -> String {
        switch problem {
        case .shared:
            return
                "`\(place)` has an access list that lets another user or group in, or that cannot be read. Run `chmod -N \(place)` in Terminal."
        case .unchecked:
            return
                "`\(place)` cannot be checked, so the tool cannot tell who can read it. Run `chmod -h -N \(place)`, or `chmod -N \(place)` if that says Permission denied."
        }
    }

    /// What `doctor` says about a token file whose access list lets another user or group in, or
    /// cannot be read. `lstat` showed a regular file, so plain `chmod -N` acts on it.
    public static func doctorTokenFileShared(_ place: String, label: String) -> String {
        "`\(place)` has an access list that lets another user or group in, or that cannot be read, so its token is not used, and another user may have read it. Run `chmod -N \(place)` in Terminal to use it again, or `agent-balancer login \(Display.safe(label, limit: 32))` to replace it."
    }

    /// What `doctor` says about a token file's name that `lstat` cannot check in a token folder
    /// the user can search, such as a file whose list denies the user `readsecurity`. A `login`
    /// refuses to replace such a file, so only the commands that clear its list are named.
    public static func doctorTokenFileUnchecked(_ place: String, label: String) -> String {
        "`\(place)` cannot be checked, so its token is not used, and another user may have read it. Run `chmod -h -N \(place)`, or `chmod -N \(place)` if that says Permission denied, to use it again."
    }

    /// What a status row, `pick` and `run` say about a token account whose token file has an
    /// access list that lets another user or group in, or cannot be read or checked.
    public static func tokenFileShared(_ label: String) -> String {
        "The token file of '\(Display.safe(label, limit: 32))' may be readable by others, so its token is not used. Run `agent-balancer doctor` in Terminal."
    }

    /// What `doctor` says about a label's launch folder that holds a launch file whose access
    /// list lets another user or group in, or cannot be read. Names only the folder, never a file.
    public static func doctorLaunchFilesShared(_ place: String) -> String {
        "Launch files in `\(place)` have an access list that lets another user or group in, or that cannot be read. Run `chmod -N \(place)/l-*.json` in Terminal."
    }

    public static let trustStep =
        "Open `claude` once in each project folder on that account, so the folder is trusted there."
    public static let notCarriedOver =
        "MCP servers and plugins do not carry over to a folder account. Add them in that folder."

    /// The `token_missing` text for a token file that is absent, not private by its kind, owner or
    /// mode, or does not parse (docs/ARCHITECTURE.md section 9).
    public static func tokenMissing(_ label: String) -> String {
        "No token saved. Run `agent-balancer login \(Display.safe(label, limit: 32))` in Terminal."
    }

    /// The `login_rejected` text of a probe that got an auth error: what a token account's status
    /// row shows unless the account is marked ending soon, and what `run` refuses such an account
    /// with.
    public static let probeLoginRejected =
        "Login rejected. Sign in to this account again, then run `agent-balancer refresh`."
}
