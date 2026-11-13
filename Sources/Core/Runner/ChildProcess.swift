import Foundation

/// Collects a child's output up to a cap and discards the rest, so the child never blocks.
final class Capture: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let cap: Int
    private var over = false

    init(cap: Int) { self.cap = cap }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        let room = cap - data.count
        if chunk.count <= room {
            data.append(chunk)
        } else {
            if room > 0 { data.append(chunk.prefix(room)) }
            over = true
        }
    }

    func snapshot() -> (Data, Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (data, over)
    }
}

/// Runs one child with an argument array and no shell, captures both streams up to a cap and ends
/// the child at the timeout. Shared by the `claude` runner and the menu app's CLI runner.
enum ChildProcess {
    static func run(
        executable exe: URL, program: String, arguments: [String],
        environment env: [String: String],
        workingDirectory: URL, timeout: TimeInterval, outputCap: Int, inheritInput: Bool,
        rawOutput: ((Data) -> Void)?
    ) throws -> RunOutput {
        let proc = Process()
        proc.executableURL = exe
        proc.arguments = arguments
        proc.environment = env
        proc.currentDirectoryURL = workingDirectory
        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        if !inheritInput { proc.standardInput = inPipe }

        let outCapture = Capture(cap: outputCap)
        let errCapture = Capture(cap: outputCap)
        let drained = DispatchGroup()
        func drain(_ pipe: Pipe, into capture: Capture) {
            drained.enter()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    drained.leave()
                } else {
                    capture.append(chunk)
                }
            }
        }
        drain(outPipe, into: outCapture)
        drain(errPipe, into: errCapture)

        let finished = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in finished.signal() }
        do {
            try proc.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            throw ToolError("Could not start \(program).", code: .checkFailed)
        }
        if !inheritInput { try? inPipe.fileHandleForWriting.close() }

        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            proc.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut {
                kill(proc.processIdentifier, SIGKILL)
                finished.wait()
            }
        }
        if drained.wait(timeout: .now() + 2) == .timedOut {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
        }

        let (outData, outOver) = outCapture.snapshot()
        let (errData, errOver) = errCapture.snapshot()
        rawOutput?(outData + errData)
        return RunOutput(
            status: timedOut ? -1 : proc.terminationStatus,
            stdout: Scrubber.tokenPass(outData),
            stderr: Scrubber.scrubText(String(decoding: errData, as: UTF8.self)),
            timedOut: timedOut,
            truncated: outOver || errOver)
    }
}
