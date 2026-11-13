import Foundation

/// The check that a typed consent has a person at a terminal. The check is a closure so a test can
/// stand in for a terminal; nothing in the environment or on the command line can switch it off.
public enum ConsentTerminal {
    public static let standardInputIsTerminal: @Sendable () -> Bool = {
        isatty(STDIN_FILENO) != 0
    }

    /// Throws before any prompt when standard input is not a terminal.
    public static func require(
        isTerminal: @Sendable () -> Bool = ConsentTerminal.standardInputIsTerminal
    ) throws {
        guard isTerminal() else { throw ToolError(Messages.terminalRequired) }
    }
}
