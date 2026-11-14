import Foundation
import Observation

/// How a Sign in button behaves. `run` starts the command. `showCommand` starts nothing and shows
/// the command with a Copy button.
public enum SignInMode: Equatable, Sendable {
    case run
    case showCommand
}

/// The sign-in mode per panel. A token account signs in with `claude setup-token`, which hung with
/// no terminal in the one run observed, so its button shows the command. A folder account signs in
/// with `claude auth login`, which does finish, so its button runs `login <label> --browser`.
public struct ManageSettings: Equatable, Sendable {
    public var tokenSignIn: SignInMode
    public var folderSignIn: SignInMode

    public init(tokenSignIn: SignInMode = .showCommand, folderSignIn: SignInMode = .run) {
        self.tokenSignIn = tokenSignIn
        self.folderSignIn = folderSignIn
    }
}

public enum EndChoice: Equatable, Sendable {
    case never
    case soon
    /// A day written `YYYY-MM-DD`.
    case on(String)
}

/// The six command shapes the window runs, and no others. `arguments` is nil when an input fails
/// the same rules the tool applies, so nothing odd reaches the tool as an argument. No case holds
/// a token, and none can build `link`, `unlink`, `config set-main`, `config clear-main`, a change
/// of email or label, or `--paste`.
public enum ManageCommand: Equatable, Sendable {
    case add(label: String, email: String?, kind: String, end: EndChoice)
    case removeAccount(label: String)
    case setEnds(label: String, date: String?)
    case setEndingSoon(label: String, on: Bool)
    case login(label: String)
    case loginBrowser(label: String)

    public static let toolName = "agent-balancer"

    /// The argument array after the tool's name, or nil when an input is not acceptable.
    public func arguments(now: Date = Date()) -> [String]? {
        switch self {
        case .add(let label, let email, let kind, let end):
            guard ConfigValidator.isValidLabel(label), kind == Kind.token || kind == Kind.folder
            else { return nil }
            var args = ["add", label]
            if kind == Kind.folder { args += ["--kind", Kind.folder] }
            if let email, !email.isEmpty {
                guard ConfigValidator.isPlainEmail(email) else { return nil }
                args += ["--email", email]
            }
            switch end {
            case .never: break
            case .soon: args.append("--ending-soon")
            case .on(let date):
                guard ConfigValidator.isTodayOrLater(date, now: now) else { return nil }
                args += ["--ends", date]
            }
            return args
        case .removeAccount(let label):
            return ConfigValidator.isValidLabel(label) ? ["remove", label] : nil
        case .setEnds(let label, let date):
            guard ConfigValidator.isValidLabel(label) else { return nil }
            guard let date else { return ["config", "set", label, "ends", "none"] }
            guard ConfigValidator.isTodayOrLater(date, now: now) else { return nil }
            return ["config", "set", label, "ends", date]
        case .setEndingSoon(let label, let on):
            guard ConfigValidator.isValidLabel(label) else { return nil }
            return ["config", "set", label, "ending-soon", on ? "true" : "false"]
        case .login(let label):
            return ConfigValidator.isValidLabel(label) ? ["login", label] : nil
        case .loginBrowser(let label):
            return ConfigValidator.isValidLabel(label) ? ["login", label, "--browser"] : nil
        }
    }

    /// The command as a person would type it, for the bottom bar and for Copy.
    public func display(now: Date = Date()) -> String? {
        arguments(now: now).map { ([Self.toolName] + $0).joined(separator: " ") }
    }
}

/// Every tip text the window shows. A test lists them and sees none longer than two sentences.
public enum ManageTips {
    public static let tokenEmail =
        "Typed when you added it. A token cannot report its email, so this is not checked."
    public static let tokenFile =
        "Saved in a private file under ~/.agent-balancer. Only you can read it."
    public static let endingSoon = "Used up first, then treated as ended once its plan drops."
    public static let endsOn = "Set only a date you know, because launches stop after that day."
    public static let addFolder =
        "Full sign-in in its own folder. Needed for connectors and Remote Control."
    public static let addTokenRun =
        "Opens your browser. The token goes straight to its file and is never shown, then one short check reads its use."
    public static let addTokenCommand =
        "Adds the account, then shows the command that signs it in. The token goes straight to its file and is never shown."

    public static func tokenSignIn(mode: SignInMode, email: String?) -> String {
        let who = email.map { " Sign in as \($0)." } ?? ""
        switch mode {
        case .run: return "Opens your browser for a new one-year token." + who
        case .showCommand: return "Shows the command that gets a new one-year token." + who
        }
    }

    public static func folderSignIn(email: String?) -> String {
        "Opens your browser." + (email.map { " Sign in as \($0)." } ?? "")
    }

    public static func sharedSettings(label: String) -> String {
        "Run this in Terminal to share settings with this folder: agent-balancer link \(label)"
    }

    /// Samples of every tip, with the longest dynamic parts, for the length test.
    public static func all(email: String = "spare-b@example.com", label: String = "spare-b")
        -> [String]
    {
        [
            tokenEmail, tokenFile, endingSoon, endsOn, addFolder, addTokenRun, addTokenCommand,
            tokenSignIn(mode: .run, email: email), tokenSignIn(mode: .showCommand, email: email),
            folderSignIn(email: email), sharedSettings(label: label),
        ]
    }
}

/// One line of the account list.
public struct ManageListRow: Equatable, Sendable, Identifiable {
    public var id: String { label }
    public var label: String
    public var subtitle: String
    public var signedIn: Bool
    public var isMain: Bool
    public var accessibilityLabel: String
}

/// The sign-in control of a panel. In `showCommand` mode the view shows `command` with a Copy
/// button and starts nothing.
public struct SignInControl: Equatable, Sendable {
    public var title: String
    public var mode: SignInMode
    public var command: String
    public var enabled: Bool
}

public struct RemoveControl: Equatable, Sendable {
    public var enabled: Bool
    /// Set for a main account: the command to run in Terminal instead.
    public var terminalCommand: String?
}

public struct ManagePanel: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case token, folder, login }

    public var label: String
    public var kind: Kind
    public var roleBadge: String
    public var isMain: Bool
    public var emailLine: String?
    public var emailTip: String?
    public var signInText: String
    public var signedIn: Bool
    public var signInTip: String?
    public var signIn: SignInControl?
    /// A problem to show under Sign-in, such as `wrong_account`, with its steps.
    public var problem: ErrorModel?
    public var tokenExpires: String?
    public var tokenTip: String?
    public var folderPath: String?
    public var sharedText: String?
    public var sharedOK: Bool
    public var sharedTip: String?
    public var linkCommand: String?
    public var ends: EndChoice
    public var canChangeEnds: Bool
    public var endingSoonTip: String
    public var endsOnTip: String
    public var remove: RemoveControl?
    /// Why a folder that is not signed in offers no Sign in, shown in the button's place.
    public var signInNote: String? = nil
}

public struct ManageBar: Equatable, Sendable {
    public var command: String
    public var ok: Bool
    /// The tool's first output line on success, or its scrubbed error text.
    public var text: String
    public var at: Date

    public init(command: String, ok: Bool, text: String, at: Date) {
        self.command = command
        self.ok = ok
        self.text = text
        self.at = at
    }
}

public struct AddDraft: Equatable, Sendable {
    public enum Stage: Equatable, Sendable { case form, added }

    public var label = ""
    public var email = ""
    public var kind = Kind.token
    public var end: EndChoice = .never
    public var endDate = ""
    public var stage = Stage.form
    public var error: String?

    public init(endDate: String = "") { self.endDate = endDate }
}

public struct AddStep: Equatable, Sendable, Identifiable {
    public enum State: Equatable, Sendable { case done, todo }

    public var id: Int
    public var title: String
    public var command: String?
    public var state: State
    /// A button that runs the step: nil when the step shows a command to copy or has no action.
    public var action: ManageCommand?
    public var actionTitle: String?
    public var actionEnabled: Bool

    public init(
        id: Int, title: String, command: String?, state: State, action: ManageCommand?,
        actionTitle: String?, actionEnabled: Bool
    ) {
        self.id = id
        self.title = title
        self.command = command
        self.state = state
        self.action = action
        self.actionTitle = actionTitle
        self.actionEnabled = actionEnabled
    }
}

public struct RemoveDraft: Equatable, Sendable {
    public var label: String
    public var typed = ""
    public var text: String
    /// The kind and email of the account the sheet was opened for, so the consent text and the
    /// account removed stay the same one.
    public var kind: String?
    public var email: String?

    public init(label: String, text: String, kind: String? = nil, email: String? = nil) {
        self.label = label
        self.text = text
        self.kind = kind
        self.email = email
    }
}

/// The state behind the Manage accounts window. It reads `status.json`, runs one agent-balancer
/// command per change, and writes no file itself. It is off, with a one-line reason, when the
/// app's own environment carries the chat-shell variable.
@MainActor @Observable
public final class ManageViewModel {
    public private(set) var accounts: [AccountSnapshot] = []
    public private(set) var notice: String?
    public private(set) var generatedAt: Date?
    public private(set) var busy = false
    public private(set) var bar: ManageBar?
    public var selection: String?
    public var add: AddDraft?
    public var removeSheet: RemoveDraft?
    /// The date the "On" end choice holds before the person picks one.
    public var endsDate: String

    @ObservationIgnored public let settings: ManageSettings
    @ObservationIgnored private let reader: StatusReader
    @ObservationIgnored private let runner: CLIRunner
    @ObservationIgnored private let context: ToolContext
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored let timeoutSeconds: Double
    /// A sign-in waits on the person in the browser, so it gets far longer than a change.
    @ObservationIgnored let loginTimeoutSeconds: Double
    /// Counts the Add sheets opened, so a command that finishes after its sheet closed knows it.
    @ObservationIgnored private var addSheetCount = 0

    public init(
        context: ToolContext, runner: CLIRunner? = nil, settings: ManageSettings = ManageSettings(),
        clock: @escaping @Sendable () -> Date = { Date() }, timeoutSeconds: Double = 60,
        loginTimeoutSeconds: Double = 600
    ) {
        self.context = context
        self.reader = StatusReader(context: context)
        self.runner = runner ?? CLIRunner(context: context)
        self.settings = settings
        self.clock = clock
        self.timeoutSeconds = timeoutSeconds
        self.loginTimeoutSeconds = loginTimeoutSeconds
        self.endsDate = ManageFormat.isoDay(clock())
        reload()
    }

    // MARK: Off state

    /// One line saying why every action is disabled, or nil when management is on.
    public var offReason: String? {
        if context.inChatShell { return "Management is off: this app was started from a chat." }
        if !runner.isAvailable { return "Management is off: agent-balancer was not found." }
        return nil
    }

    public var isOn: Bool { offReason == nil }
    public var canAct: Bool { isOn && !busy }

    // MARK: Reading

    public func reload() {
        switch reader.load() {
        case .loaded(let snapshot):
            accounts = snapshot.accounts.filter { ConfigValidator.isValidLabel($0.label) }
            generatedAt = snapshot.generatedAt
            notice = accounts.isEmpty ? "No accounts yet. Use the plus button." : nil
        case .missing:
            accounts = []
            notice = "No accounts yet. Use the plus button."
        case .unreadable(let text):
            accounts = []
            notice = text
        case .newerSchema:
            accounts = []
            notice = "Update agent-balancer."
        }
        if let current = selection, !accounts.contains(where: { $0.label == current }) {
            selection = nil
        }
        if selection == nil { selection = accounts.first?.label }
    }

    /// Opens the window on one account, as the menu's fix action does.
    public func select(_ label: String) {
        reload()
        if accounts.contains(where: { $0.label == label }) { selection = label }
    }

    /// True while the window is on screen.
    public private(set) var isOpen = false

    public func windowOpened() {
        isOpen = true
        reload()
    }

    public func windowClosed() { isOpen = false }

    /// Called when the window becomes key and on each pass of the menu's file loop. While the
    /// window is open it reads the status again, so a sheet follows a `link` run in Terminal.
    public func statusMayHaveChanged() {
        guard isOpen else { return }
        reload()
    }

    public var rows: [ManageListRow] {
        accounts.map { ManageBuilder.listRow($0, now: clock()) }
    }

    public var selected: AccountSnapshot? { accounts.first { $0.label == selection } }

    public var panel: ManagePanel? {
        guard let account = selected else { return nil }
        return ManageBuilder.panel(
            account, settings: settings, now: clock(), checked: generatedAt, canAct: canAct,
            folderPath: ManageBuilder.folderPath(account.label, context: context))
    }

    // MARK: Running commands

    /// Runs one command and shows it with its result in the bottom bar. Returns true on success.
    @discardableResult
    public func run(_ command: ManageCommand) async -> Bool {
        let now = clock()
        guard isOn else { return false }
        guard !busy else { return false }
        guard let arguments = command.arguments(now: now), let shown = command.display(now: now)
        else {
            bar = ManageBar(
                command: "", ok: false, text: "That input is not valid.", at: now)
            return false
        }
        if case .removeAccount(let label) = command {
            let check = removeCheck(label)
            guard check == .ok else {
                bar = ManageBar(
                    command: "", ok: false, text: Self.removeRefusal(check, label: label), at: now)
                return false
            }
        }
        busy = true
        let runner = self.runner
        let timeout: Double
        switch command {
        case .login, .loginBrowser: timeout = loginTimeoutSeconds
        default: timeout = timeoutSeconds
        }
        let result = await Task.detached { Result { try runner.run(arguments, timeout: timeout) } }
            .value
        var ok = false
        var text = ""
        switch result {
        case .failure(let error):
            text = ManageViewModel.firstLine(error.localizedDescription)
        case .success(let output):
            if output.timedOut {
                text = "The command timed out."
            } else if output.status != 0 {
                let raw = output.stderr.isEmpty ? output.stdout : output.stderr
                let line = ManageViewModel.firstLine(raw)
                text = line.isEmpty ? "Failed (exit \(output.status))." : line
            } else {
                ok = true
                let line = ManageViewModel.firstLine(output.stdout)
                text = line.isEmpty ? "Done." : line
            }
            // A browser sign-in prints its advice first, so the bar picks the line that answers.
            if case .loginBrowser = command, !output.timedOut,
                let answer = Self.signInAnswer(output, ok: ok)
            {
                text = answer
            }
        }
        bar = ManageBar(command: shown, ok: ok, text: text, at: clock())
        busy = false
        reload()
        return ok
    }

    static func firstLine(_ text: String) -> String {
        let line =
            text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return Display.safe(Scrubber.tokenPass(line), limit: 240)
    }

    /// For `login <label> --browser`: on failure the first line, stdout then stderr, that starts
    /// with "Error " (the tool's error line); on success the "Signed in." line. Nil when there is
    /// none, so the bar keeps the first line.
    static func signInAnswer(_ output: RunOutput, ok: Bool) -> String? {
        let prefix = ok ? "Signed in." : "Error "
        for text in ok ? [output.stdout] : [output.stdout, output.stderr] {
            let lines = text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if let line = lines.first(where: { $0.hasPrefix(prefix) }) {
                return firstLine(line)
            }
        }
        return nil
    }

    /// The panel's Sign in button. In `showCommand` mode it starts nothing. The kind, link and
    /// sign-in state come from a fresh read, not from the panel as it was drawn.
    public func signIn(_ label: String) async {
        reload()
        guard let account = accounts.first(where: { $0.label == label }) else { return }
        switch ManageBuilder.panelKind(account) {
        case .token:
            guard settings.tokenSignIn == .run else { return }
            await run(.login(label: label))
        case .folder:
            guard settings.folderSignIn == .run, account.linked == true,
                ManageBuilder.offersSignIn(ManageBuilder.signInState(account)),
                ManageBuilder.signInBlocked(account) == nil
            else { return }
            await run(.loginBrowser(label: label))
        case .login:
            return
        }
    }

    // MARK: End choice

    /// The one command a change of the end choice runs. The tool keeps one end marker per
    /// account: `ends <date>` clears the soon flag, `ending-soon true` clears the date and
    /// `ends none` clears both, so no change needs a second command.
    nonisolated public static func endCommand(label: String, to choice: EndChoice) -> ManageCommand
    {
        switch choice {
        case .never: return .setEnds(label: label, date: nil)
        case .soon: return .setEndingSoon(label: label, on: true)
        case .on(let date): return .setEnds(label: label, date: date)
        }
    }

    /// Runs the choice's one command after a fresh read still lists the account as one whose end
    /// the window may change.
    public func changeEnds(label: String, to choice: EndChoice) async {
        reload()
        guard let account = accounts.first(where: { $0.label == label }),
            ManageBuilder.panelKind(account) != .login
        else { return }
        await run(Self.endCommand(label: label, to: choice))
    }

    // MARK: Add sheet

    public func openAdd() {
        guard isOn else { return }
        addSheetCount += 1
        add = AddDraft(endDate: ManageFormat.isoDay(clock()))
    }

    /// Closing waits for a running command, as the sheet's Cancel and Esc do.
    public func closeAdd() {
        guard !busy else { return }
        add = nil
        reload()
    }

    /// Why the Add button is off, or nil when the form can go.
    public func addProblem(_ draft: AddDraft) -> String? {
        if !isOn { return offReason }
        if draft.label.isEmpty { return "Type a label." }
        if !ConfigValidator.isValidLabel(draft.label) {
            return "Use lowercase letters, digits or hyphens."
        }
        if accounts.contains(where: { $0.label == draft.label }) {
            return "That label is already used."
        }
        if !draft.email.isEmpty, !ConfigValidator.isPlainEmail(draft.email) {
            return "That is not an email address."
        }
        if case .on = draft.end, !ConfigValidator.isTodayOrLater(draft.endDate, now: clock()) {
            return "Pick today or a later day."
        }
        return nil
    }

    public func addCommand(_ draft: AddDraft) -> ManageCommand { ManageBuilder.addCommand(draft) }

    /// "Sign in and add" for a token account, "Create folder" for a folder account. A token
    /// account then signs in when its mode is `run`; in `showCommand` mode the sheet shows the
    /// command and starts nothing.
    public func submitAdd() async {
        guard var draft = add, draft.stage == .form, addProblem(draft) == nil, canAct else {
            return
        }
        let sheet = addSheetCount
        let ok = await run(addCommand(draft))
        // A sheet closed while the command ran stays closed, and no sign-in starts for it.
        guard add != nil, addSheetCount == sheet else { return }
        guard ok else {
            draft.error = bar?.text
            add = draft
            return
        }
        draft.stage = .added
        draft.error = nil
        add = draft
        selection = draft.label
        if draft.kind == Kind.token, settings.tokenSignIn == .run {
            await run(.login(label: draft.label))
        }
    }

    /// The steps the sheet lists after the account is added, from the account as the status file
    /// shows it now.
    public func addSteps(_ draft: AddDraft) -> [AddStep] {
        ManageBuilder.addSteps(
            draft, account: accounts.first { $0.label == draft.label }, settings: settings,
            canAct: canAct, now: clock())
    }

    /// Runs a step's button only when a fresh read still offers that step, so a folder that lost
    /// its link or got signed in since the sheet was drawn starts nothing.
    public func runStep(_ step: AddStep) async {
        guard let draft = add, step.action != nil else { return }
        reload()
        guard let current = addSteps(draft).first(where: { $0.id == step.id }),
            current.actionEnabled, let action = current.action, action == step.action
        else { return }
        await run(action)
    }

    // MARK: Remove sheet

    public func openRemove() {
        guard isOn, let account = selected, ManageBuilder.panelKind(account) != .login,
            account.role == Role.pool
        else { return }
        let text: String
        if ManageBuilder.panelKind(account) == .folder {
            text = "It stops getting workers. Its folder, login and chats stay."
        } else {
            text = "It stops getting workers and its token file is deleted. Its chats stay."
        }
        removeSheet = RemoveDraft(
            label: account.label, text: text, kind: account.kind, email: account.email)
    }

    /// Closing waits for a running `remove`, as the sheet's Cancel and Esc do.
    public func closeRemove() {
        guard !busy else { return }
        removeSheet = nil
    }

    public func canConfirmRemove(_ draft: RemoveDraft) -> Bool {
        canAct && draft.typed == draft.label
    }

    /// Runs `remove <label>` only when a fresh read still lists the account as a pool account of
    /// a kind the window removes, with the kind and email the sheet was opened for. Otherwise
    /// nothing runs, the sheet closes, and the panel shows the Terminal command for a main
    /// account.
    public func confirmRemove() async {
        guard let draft = removeSheet, canConfirmRemove(draft) else { return }
        let check = removeCheck(draft.label, as: draft)
        guard check == .ok else {
            removeSheet = nil
            if check != .gone { selection = draft.label }
            bar = ManageBar(
                command: "", ok: false, text: Self.removeRefusal(check, label: draft.label),
                at: clock())
            return
        }
        if await run(.removeAccount(label: draft.label)) {
            removeSheet = nil
            if selection == draft.label { selection = accounts.first?.label }
        }
    }

    /// What a remove depends on, read again from the status file right before it runs.
    enum RemoveCheck: Equatable {
        case ok, gone, main, other, changed
    }

    /// The role can change while the sheet is open (`config set-main` in Terminal, or a rewritten
    /// status file), so every remove reads the status again first. With the sheet's draft, a
    /// label that now names an account of another kind or email is another account.
    func removeCheck(_ label: String, as draft: RemoveDraft? = nil) -> RemoveCheck {
        reload()
        guard let account = accounts.first(where: { $0.label == label }) else { return .gone }
        if let draft, account.kind != draft.kind || account.email != draft.email {
            return .changed
        }
        if account.role == Role.main { return .main }
        guard account.role == Role.pool, ManageBuilder.panelKind(account) != .login else {
            return .other
        }
        return .ok
    }

    static func removeRefusal(_ check: RemoveCheck, label: String) -> String {
        let safe = Display.safe(label, limit: 32)
        switch check {
        case .gone: return "Nothing was removed: \(safe) is no longer listed."
        case .main:
            return "Nothing was removed: \(safe) is the main account now. Remove it in Terminal."
        case .changed:
            return "Nothing was removed: \(safe) is another account now. Open Remove again."
        case .other, .ok: return "Nothing was removed: \(safe) cannot be removed here."
        }
    }
}

enum ManageFormat {
    static func isoDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// "2026-11-16" becomes "Nov 16, 2026". Anything else goes through the display-safe pass.
    static func longDay(_ iso: String) -> String {
        guard let parts = MenuFormat.dateParts(iso), let short = MenuFormat.dayIfDate(iso) else {
            return Display.safe(iso, limit: 32)
        }
        return "\(short), \(parts.year)"
    }

    /// The calendar day of a moment in the zone the app shows times in.
    static func localDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = LocalTime.zone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func clockTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = LocalTime.zone
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }
}

public enum ManageBuilder {
    static let signedOutCodes: Set<String> = ["login_rejected", "token_missing"]

    static func isSignedOut(_ a: AccountSnapshot) -> Bool {
        guard a.state == "error", let code = a.error?.code else { return false }
        return signedOutCodes.contains(code)
    }

    /// How the window reads an account's sign-in.
    enum SignIn: Equatable, Sendable {
        case signedIn
        /// A check saw it signed out: `login_rejected`, or `token_missing` for a token account.
        case signedOut
        /// A folder that is not linked, or with no evidence that it is signed in.
        case notSignedIn
        /// A check found it signed in to another account (`wrong_account`).
        case otherAccount
        /// A token or login account that has ended.
        case ended
        /// A token or login account whose row has a code that could hide a check that saw it
        /// signed out or could not confirm it, `check_failed` included. A folder whose last check
        /// saw a sign-in that it could not place, or could not confirm as the expected account
        /// because it reported no email, or saw it placed with a doubt since.
        case notConfirmed
    }

    /// A folder counts as signed in only with evidence: it is linked, and its row carries the
    /// plan tier, which the status shows only from a check that placed the expected sign-in in
    /// the folder while no check since says it is gone or unconfirmed. The row's own state and
    /// code must say nothing against the sign-in either; any other row fails closed. The row's
    /// one code can hide the last check's result, so a folder row's `signInCheck` comes first:
    /// another account reads as that whatever the code, and a sign-in the check saw but could not
    /// place offers no Sign in, which `login --browser` would refuse. A row with no
    /// `signInCheck` key comes from a writer that kept the tier through a doubt, so it reads by
    /// the tier alone only while it shows no code that can hide one.
    /// A token or login row has no such evidence, and any code could hide one that says otherwise
    /// (`account_ended` hides them all), so it counts only when it has no code at all.
    static func signInState(_ a: AccountSnapshot) -> SignIn {
        let folder = panelKind(a) == .folder
        if folder, let seen = a.signInCheck {
            switch SignInSeen(rawValue: seen) {
            case .otherAccount?: return .otherAccount
            case .signedIn?, .signedOut?: break
            case .notConfirmed?, nil: return .notConfirmed
            }
        }
        if isSignedOut(a) { return .signedOut }
        if a.error?.code == StateCode.wrongAccount.rawValue { return .otherAccount }
        guard folder else {
            if a.state == "ended" { return .ended }
            switch (a.state, a.error?.code) {
            case ("ok", nil), ("limited", nil): return .signedIn
            default: return .notConfirmed
            }
        }
        if !a.hasSignInCheck, let code = a.error?.code, hidesADoubt.contains(code) {
            return .notConfirmed
        }
        let linked = a.linked == true
        if linked, a.planTier != nil, a.signInCheck != SignInSeen.signedOut.rawValue {
            switch (a.state, a.error?.code) {
            case ("ok", nil), ("limited", nil), ("ended", "account_ended"?),
                ("error", "settings_changed"?), ("error", "duplicate_login"?),
                ("error", "plan_changed"?):
                return .signedIn
            default:
                break
            }
        }
        // Placed by the last check and doubted since: still signed in as far as `auth status`
        // knows, so a Sign in would be refused.
        if linked, a.signInCheck == SignInSeen.signedIn.rawValue { return .notConfirmed }
        return .notSignedIn
    }

    /// Codes a row shows over a doubt from a sign-in check (`login_rejected`, `check_failed` or
    /// `wrong_account`): `account_ended`, and every other code the ranking puts above one.
    static let hidesADoubt: Set<String> = {
        let order = Transitions.errorOrder
        let doubts = Transitions.signInDoubted
        let lowest = order.lastIndex { doubts.contains($0.rawValue) } ?? 0
        let above = order[..<lowest].map(\.rawValue).filter { !doubts.contains($0) }
        return Set(above + [StateCode.accountEnded.rawValue])
    }()

    /// A folder offers Sign in only when it is signed out or not signed in; one signed in to
    /// another account needs that account signed out in Terminal first.
    static func offersSignIn(_ state: SignIn) -> Bool {
        state == .signedOut || state == .notSignedIn
    }

    /// Why `login --browser` would refuse a folder whatever its sign-in: an expected email it
    /// cannot pass to claude. Nil when nothing stops it.
    static func signInBlocked(_ a: AccountSnapshot) -> String? {
        guard let email = a.email, !ConfigValidator.isPlainEmail(email) else { return nil }
        return MenuBuilder.plain(Messages.emailNotPlain(a.label))
    }

    /// The text for a folder whose last sign-in check saw a sign-in it could not place.
    static let notPlacedText =
        "The last sign-in check could not confirm the sign-in in this folder."

    /// The text for a folder whose last sign-in check saw a sign-in that reported no email.
    static let noEmailText = MenuBuilder.plain(Messages.signInEmailMissing)

    /// The panel's problem block. Another account reads as `wrong_account` with its steps even
    /// when the row shows another code over it. A folder whose last check could not place its
    /// sign-in says so, whatever code the row shows, and names the missing email when the row's
    /// own error is that one. Otherwise "Sign-in not confirmed" and
    /// "Account ended" give the row's own error as the reason, and an ended folder, which keeps
    /// its sign-in line, gives its own `account_ended` error.
    static func problem(_ a: AccountSnapshot, state: SignIn) -> ErrorModel? {
        let folder = panelKind(a) == .folder
        switch state {
        case .otherAccount:
            let code = StateCode.wrongAccount.rawValue
            let text = a.error?.code == code ? a.error?.text : nil
            return ErrorModel(
                title: MenuBuilder.title(for: code),
                text: MenuBuilder.plain(text ?? Messages.wrongAccount),
                steps: windowSteps(code: code, label: a.label))
        case .notConfirmed, .ended:
            if folder, a.signInCheck == SignInSeen.notConfirmed.rawValue {
                let noEmail = a.error?.text == Messages.signInEmailMissing
                return ErrorModel(
                    title: MenuBuilder.title(for: StateCode.checkFailed.rawValue),
                    text: noEmail ? noEmailText : notPlacedText,
                    steps: StepsModel(steps: [], command: nil))
            }
            guard let e = a.error else { return nil }
            return ErrorModel(
                title: MenuBuilder.title(for: e.code), text: MenuBuilder.plain(e.text),
                steps: StepsModel(steps: [], command: nil))
        case .signedIn, .signedOut, .notSignedIn:
            guard folder, a.state == "ended", let e = a.error else { return nil }
            return ErrorModel(
                title: MenuBuilder.title(for: e.code), text: MenuBuilder.plain(e.text),
                steps: StepsModel(steps: [], command: nil))
        }
    }

    /// The menu's steps for a code, less the ones that name an action only the menu has.
    static func windowSteps(code: String, label: String) -> StepsModel {
        var steps = MenuBuilder.steps(code: code, label: label)
        steps.steps.removeAll { MenuBuilder.menuOnlySteps.contains($0) }
        return steps
    }

    static func panelKind(_ a: AccountSnapshot) -> ManagePanel.Kind {
        switch a.kind {
        case Kind.token: return .token
        case Kind.folder: return .folder
        default: return .login
        }
    }

    static func daysLeft(_ a: AccountSnapshot, now: Date) -> Int? {
        guard let at = a.loginExpiresAt else { return nil }
        return Int((at.timeIntervalSince(now) / 86400).rounded(.down))
    }

    static func endText(_ a: AccountSnapshot) -> String? {
        if let ends = a.endsAt, !ends.isEmpty { return "ends " + MenuFormat.day(ends) }
        if a.endingSoon { return "ending soon" }
        return nil
    }

    /// A folder keeps its sign-in words when its row has ended, so its end says it has.
    static func folderEnded(_ a: AccountSnapshot) -> Bool {
        panelKind(a) == .folder && a.state == "ended"
    }

    /// "ended Nov 1" for a date that has passed, "ended" for a plan that dropped.
    static func endedText(_ a: AccountSnapshot) -> String {
        if let ends = a.endsAt, !ends.isEmpty { return "ended " + MenuFormat.day(ends) }
        return "ended"
    }

    /// "Signed out at 12:40 PM" on the token panel and "Signed out since today, 12:40 PM" on the
    /// others, from the time the tool first saw the account signed out, when the status has it.
    static func signedOutText(_ kind: ManagePanel.Kind, since: Date?, now: Date) -> String {
        guard let since else { return "Signed out" }
        let time = ManageFormat.clockTime(since)
        let day = ManageFormat.localDay(since)
        let today = day == ManageFormat.localDay(now)
        let shownDay = today ? "today" : MenuFormat.day(day)
        switch kind {
        case .token: return today ? "Signed out at \(time)" : "Signed out on \(shownDay) at \(time)"
        case .folder, .login: return "Signed out since \(shownDay), \(time)"
        }
    }

    /// A paste-ready Terminal command, or nil when the label is not a plain label.
    static func terminalCommand(_ verb: String, _ label: String) -> String? {
        ConfigValidator.isValidLabel(label) ? "agent-balancer \(verb) \(label)" : nil
    }

    /// The folder path a folder panel shows and copies. It is made from the plain label and the
    /// data folder, never taken from the status file, so the clipboard gets only a path the tool
    /// would make.
    public static func folderPath(_ label: String, context: ToolContext) -> String? {
        guard let url = try? FolderPaths.configDir(context: context, label: label) else {
            return nil
        }
        return context.display(url)
    }

    static func capitalized(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    public static func listRow(_ a: AccountSnapshot, now: Date) -> ManageListRow {
        let kind = panelKind(a)
        let state = signInState(a)
        let end = folderEnded(a) ? endedText(a) : endText(a)
        func withEnd(_ base: String) -> String { end.map { base + " \u{00B7} " + $0 } ?? base }
        let subtitle: String
        switch state {
        case .signedOut: subtitle = withEnd("Signed out")
        case .notSignedIn: subtitle = withEnd("Not signed in")
        case .otherAccount: subtitle = withEnd("Signed in as another account")
        case .ended: subtitle = withEnd("Account ended")
        case .notConfirmed: subtitle = withEnd("Sign-in not confirmed")
        case .signedIn:
            switch kind {
            case .login: subtitle = withEnd("Your login")
            case .folder: subtitle = withEnd("Signed in")
            case .token:
                if let end {
                    subtitle = capitalized(end)
                } else if let days = daysLeft(a, now: now) {
                    subtitle = days <= 0 ? "Expired" : "\(days) days left"
                } else {
                    subtitle = "Signed in"
                }
            }
        }
        let kindWords: String
        switch kind {
        case .login: kindWords = "login account"
        case .token: kindWords = "token account"
        case .folder: kindWords = "folder account"
        }
        let stateWords: String
        switch state {
        case .signedIn: stateWords = "signed in"
        case .signedOut: stateWords = "signed out"
        case .notSignedIn: stateWords = "not signed in"
        case .otherAccount: stateWords = "signed in as another account"
        case .ended: stateWords = "account ended"
        case .notConfirmed: stateWords = "sign-in not confirmed"
        }
        let ended = folderEnded(a) ? ", ended" : ""
        let spoken = "\(Display.safe(a.label)), \(kindWords), \(stateWords)\(ended)"
        return ManageListRow(
            label: a.label, subtitle: subtitle, signedIn: state == .signedIn,
            isMain: a.role == Role.main, accessibilityLabel: spoken)
    }

    public static func panel(
        _ a: AccountSnapshot, settings: ManageSettings, now: Date, checked: Date?,
        canAct: Bool = true, folderPath: String? = nil
    ) -> ManagePanel {
        let kind = panelKind(a)
        let state = signInState(a)
        let isMain = a.role == Role.main
        let label = a.label

        var ends: EndChoice = .never
        if let date = a.endsAt, !date.isEmpty {
            ends = .on(Display.safe(date, limit: 32))
        } else if a.endingSoon {
            ends = .soon
        }

        let email = a.email.map { Display.safe($0) }
        let tier = kind == .token ? nil : a.planTier.map { Display.safe($0, limit: 64) }
        let emailLine = [email, tier].compactMap { $0 }.joined(separator: " \u{00B7} ")
        var panel = ManagePanel(
            label: Display.safe(label), kind: kind, roleBadge: isMain ? "main" : "pool",
            isMain: isMain, emailLine: emailLine.isEmpty ? nil : emailLine, emailTip: nil,
            signInText: "", signedIn: state == .signedIn,
            signInTip: nil, signIn: nil, problem: nil, tokenExpires: nil, tokenTip: nil,
            folderPath: nil, sharedText: nil, sharedOK: false, sharedTip: nil, linkCommand: nil,
            ends: ends, canChangeEnds: kind != .login && canAct,
            endingSoonTip: ManageTips.endingSoon, endsOnTip: ManageTips.endsOn, remove: nil)

        let signedOut = signedOutText(kind, since: a.stateSince, now: now)
        switch state {
        case .signedOut: panel.signInText = signedOut
        case .notSignedIn: panel.signInText = "Not signed in"
        case .otherAccount: panel.signInText = "Signed in as another account"
        case .ended: panel.signInText = "Account ended"
        case .notConfirmed: panel.signInText = "Sign-in not confirmed"
        case .signedIn: panel.signInText = "Signed in"
        }
        panel.problem = problem(a, state: state)

        switch kind {
        case .login:
            if state == .signedIn { panel.signInText = "Signed in with your own login" }
        case .token:
            panel.emailTip = a.email == nil ? nil : ManageTips.tokenEmail
            panel.signInTip = ManageTips.tokenSignIn(mode: settings.tokenSignIn, email: email)
            let command = ManageCommand.login(label: label)
            panel.signIn = SignInControl(
                title: "Sign in again...", mode: settings.tokenSignIn,
                command: command.display() ?? "", enabled: canAct)
            if let at = a.loginExpiresAt {
                panel.tokenExpires = "Expires " + ManageFormat.longDay(ManageFormat.localDay(at))
            } else {
                panel.tokenExpires = "Expiry unknown"
            }
            panel.tokenTip = ManageTips.tokenFile
        case .folder:
            panel.folderPath = folderPath
            let linked = a.linked == true
            panel.sharedOK = linked
            panel.linkCommand = linked ? nil : terminalCommand("link", label)
            if panel.linkCommand != nil || linked {
                panel.sharedTip = ManageTips.sharedSettings(label: label)
            }
            if linked {
                let when = checked.map {
                    " \u{00B7} checked " + MenuFormat.ago(seconds: Int(now.timeIntervalSince($0)))
                }
                panel.sharedText = "Linked" + (when ?? "")
            } else {
                panel.sharedText = "Not linked"
            }
            if offersSignIn(state), let blocked = signInBlocked(a) {
                panel.signInNote = blocked
            } else if offersSignIn(state) {
                panel.signInTip = ManageTips.folderSignIn(email: email)
                let command = ManageCommand.loginBrowser(label: label)
                panel.signIn = SignInControl(
                    title: state == .signedOut ? "Sign in again..." : "Sign in...",
                    mode: settings.folderSignIn, command: command.display() ?? "",
                    enabled: canAct && linked)
            }
        }

        if kind != .login {
            let removable = a.role == Role.pool
            panel.remove = RemoveControl(
                enabled: removable && canAct,
                terminalCommand: removable ? nil : terminalCommand("remove", label))
        }
        return panel
    }

    static func addCommand(_ draft: AddDraft) -> ManageCommand {
        let end: EndChoice
        switch draft.end {
        case .never: end = .never
        case .soon: end = .soon
        case .on: end = .on(draft.endDate)
        }
        return .add(
            label: draft.label, email: draft.email.isEmpty ? nil : draft.email, kind: draft.kind,
            end: end)
    }

    /// The Add sheet's steps once `draft` is added, from `account` as the status file shows it
    /// now (nil before the status lists it). A folder's Sign in stays off until it is linked and
    /// reads done only once a check has seen it signed in.
    public static func addSteps(
        _ draft: AddDraft, account: AccountSnapshot?, settings: ManageSettings, canAct: Bool,
        now: Date
    ) -> [AddStep] {
        guard draft.stage == .added else { return [] }
        let label = draft.label
        let addDisplay = addCommand(draft).display(now: now)
        let state = account.map(signInState) ?? .notSignedIn
        if draft.kind == Kind.token {
            let loginCommand = ManageCommand.login(label: label)
            let done = state == .signedIn
            let byButton = settings.tokenSignIn == .run
            return [
                AddStep(
                    id: 1, title: "Add the account", command: addDisplay, state: .done,
                    action: nil, actionTitle: nil, actionEnabled: false),
                AddStep(
                    id: 2, title: byButton ? "Sign in" : "Sign in, in Terminal",
                    command: byButton ? nil : loginCommand.display(), state: done ? .done : .todo,
                    action: byButton ? loginCommand : nil,
                    actionTitle: byButton ? "Sign in..." : nil,
                    actionEnabled: canAct && !done),
            ]
        }
        let linked = account?.linked == true
        let done = linked && state == .signedIn
        let loginCommand = ManageCommand.loginBrowser(label: label)
        let byButton = settings.folderSignIn == .run
        return [
            AddStep(
                id: 1, title: "Create the folder", command: addDisplay, state: .done, action: nil,
                actionTitle: nil, actionEnabled: false),
            AddStep(
                id: 2, title: "Share settings, in Terminal",
                command: terminalCommand("link", label),
                state: linked ? .done : .todo, action: nil, actionTitle: nil,
                actionEnabled: false),
            AddStep(
                id: 3, title: byButton ? "Sign in" : "Sign in, in Terminal",
                command: byButton ? nil : loginCommand.display(),
                state: done ? .done : .todo, action: byButton ? loginCommand : nil,
                actionTitle: byButton ? "Sign in..." : nil,
                actionEnabled: canAct && linked && offersSignIn(state)
                    && account.flatMap(signInBlocked) == nil),
            AddStep(
                id: 4, title: "Trust each project once, in Terminal",
                command: terminalCommand("run", label), state: .todo, action: nil,
                actionTitle: nil, actionEnabled: false),
        ]
    }
}
