import Foundation

/// Lets the terminate signal end a command only between the writes that keep what a finished
/// probe found, so a command the menu ends past its timeout never leaves such a write half done,
/// and waits for one that has begun. Without `install` the signal ends the command at once, as
/// before.
public final class TerminateGate: @unchecked Sendable {
    public static let shared = TerminateGate()

    private let lock = NSLock()
    private var source: DispatchSourceSignal?

    /// From now on, the terminate signal waits for a write in progress, then ends the process
    /// the way the signal does. A second signal while it waits changes nothing.
    public func install() {
        lock.lock()
        defer { lock.unlock() }
        guard source == nil else { return }
        let source = DispatchSource.makeSignalSource(
            signal: SIGTERM, queue: DispatchQueue(label: "agent-balancer.terminate"))
        source.setEventHandler { [lock] in
            // Never let go: the process ends here, after the write that held the lock.
            lock.lock()
            signal(SIGTERM, SIG_DFL)
            kill(getpid(), SIGTERM)
        }
        source.resume()
        self.source = source
        // A handler, unlike an ignored signal, goes back to the default in each child.
        signal(SIGTERM) { _ in }
    }

    /// Runs `body`, a write that keeps what a probe found, whole before the signal ends the
    /// process.
    public func recording<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
