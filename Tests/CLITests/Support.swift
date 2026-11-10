import Foundation

/// Paths and process helpers the CLI tests share.
enum Support {
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func builtBinary() -> URL? {
        for config in ["debug", "release"] {
            let url = root.appendingPathComponent(".build/\(config)/agent-balancer")
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    struct Output {
        var status: Int32
        var stdout: Data
        var stderr: Data
    }

    static func run(_ exe: URL, _ args: [String], env: [String: String]) throws -> Output {
        let task = Process()
        task.executableURL = exe
        task.arguments = args
        task.environment = env
        let out = Pipe()
        let err = Pipe()
        task.standardOutput = out
        task.standardError = err
        try task.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return Output(status: task.terminationStatus, stdout: outData, stderr: errData)
    }

    static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ab-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
