import Foundation

/// Takes a setup-token from `claude setup-token` or from a pasted line, checks its shape and
/// stores it. The raw output of the child is read here first, before any scrubber sees it, and
/// the token goes straight into the token store. What comes back is a length and a verdict, never
/// text (docs/ARCHITECTURE.md section 4A.4).
public enum TokenCapture {
    /// What a capture did. It holds no part of the token.
    public struct Result: Equatable, Sendable {
        public let length: Int
        public let replaced: Bool
        public let launchFilesRewritten: Int
    }

    static let setupTokenTimeout: TimeInterval = 300
    static let minimumLength = 50
    static let maximumLength = 400

    private static let tokenPattern = try? NSRegularExpression(
        pattern: "sk-ant-oat[0-9]{2}-[A-Za-z0-9_-]+")
    private static let terminalCodes = try? NSRegularExpression(
        pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]|\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)")

    /// Whether `value` is shaped like a setup-token: `sk-ant-oat`, two digits, a dash, then
    /// letters, digits, dashes and underscores, within sane bounds. An API key does not pass.
    static func hasTokenShape(_ value: String) -> Bool {
        guard value.count >= minimumLength, value.count <= maximumLength else { return false }
        let whole = NSRange(value.startIndex..., in: value)
        guard let pattern = tokenPattern,
            let match = pattern.firstMatch(in: value, range: whole)
        else { return false }
        return match.range == whole
    }

    /// The token in the child's raw output, or nil. Terminal codes are dropped first. With more
    /// than one candidate the last well-shaped one wins, because the tool prints it last.
    static func extract(from raw: Data) -> String? {
        var text = String(decoding: raw, as: UTF8.self)
        if let codes = terminalCodes {
            text = codes.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        guard let pattern = tokenPattern else { return nil }
        let matches = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            if let range = Range(match.range, in: text), hasTokenShape(String(text[range])) {
                return String(text[range])
            }
        }
        return nil
    }

    /// The default form: runs `claude setup-token` with its output piped, takes the token from
    /// the raw output and stores it. The child's remaining output is scrubbed and dropped.
    public static func capture(context: ToolContext, label: String, runner: ClaudeRunner) throws
        -> Result
    {
        var found: String?
        let output = try runner.runSetupToken(timeout: setupTokenTimeout) { raw in
            found = extract(from: raw)
        }
        guard let token = found else {
            if output.timedOut {
                throw ToolError(
                    "No approval arrived in time. Run `agent-balancer login \(label)` again.")
            }
            throw ToolError(
                "No token was found in the output of `claude setup-token`. Run `agent-balancer login \(label) --paste` instead."
            )
        }
        return try store(context: context, label: label, token: token)
    }

    /// The fallback form: reads one line from standard input, with echo off on a terminal, and
    /// stores it when it has the shape of a setup-token. The token never comes from an argument.
    /// On a terminal whose echo cannot be turned off, nothing is read and nothing is saved.
    public static func pasted(context: ToolContext, label: String) throws -> Result {
        try pasted(context: context, label: label, terminal: .standardInput)
    }

    static func pasted(context: ToolContext, label: String, terminal: PasteTerminal) throws
        -> Result
    {
        let line = try readHidden(prompt: "Paste the token, then press Enter: ", terminal: terminal)
        let token = (line ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasTokenShape(token) else {
            throw ToolError(
                "That is not shaped like a setup-token from `claude setup-token`. Nothing was saved."
            )
        }
        return try store(context: context, label: label, token: token)
    }

    private static func store(context: ToolContext, label: String, token: String) throws -> Result {
        let installed = try TokenAccounts.install(
            context: context, label: label, token: token, requireAccount: true)
        return Result(
            length: token.count, replaced: installed.replaced,
            launchFilesRewritten: installed.launchFilesRewritten)
    }

    /// Reads one line. On a terminal, echo goes off first; when it cannot, this throws before
    /// anything is read, so a pasted token never shows on the screen.
    private static func readHidden(prompt: String, terminal: PasteTerminal) throws -> String? {
        guard terminal.isTerminal() else { return terminal.readLine() }
        guard let saved = terminal.echoOff() else {
            throw ToolError(
                "Could not hide the input on this terminal, so nothing was read and nothing was saved."
            )
        }
        print(prompt, terminator: "")
        fflush(stdout)
        let line = terminal.readLine()
        terminal.restore(saved)
        print("")
        return line
    }
}

/// The terminal calls of the paste prompt, so a test can stand in for a terminal.
struct PasteTerminal: Sendable {
    var isTerminal: @Sendable () -> Bool
    /// Turns echo off and returns the settings to restore, or nil when echo is still on.
    var echoOff: @Sendable () -> termios?
    var restore: @Sendable (termios) -> Void
    var readLine: @Sendable () -> String?

    static var standardInput: PasteTerminal {
        PasteTerminal(
            isTerminal: { isatty(STDIN_FILENO) != 0 },
            echoOff: {
                var saved = termios()
                guard tcgetattr(STDIN_FILENO, &saved) == 0 else { return nil }
                var quiet = saved
                quiet.c_lflag &= ~tcflag_t(ECHO)
                guard tcsetattr(STDIN_FILENO, TCSANOW, &quiet) == 0 else { return nil }
                // tcsetattr succeeds when any one change applies, so read the flag back.
                var now = termios()
                guard tcgetattr(STDIN_FILENO, &now) == 0, now.c_lflag & tcflag_t(ECHO) == 0 else {
                    tcsetattr(STDIN_FILENO, TCSANOW, &saved)
                    return nil
                }
                return saved
            },
            restore: { saved in
                var settings = saved
                tcsetattr(STDIN_FILENO, TCSANOW, &settings)
            },
            readLine: { Swift.readLine(strippingNewline: true) })
    }
}
