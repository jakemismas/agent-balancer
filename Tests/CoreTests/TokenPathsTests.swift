import Foundation
import Testing

@testable import Core

@Suite struct TokenPathsTests {
    @Test func buildsThePathFromALabel() throws {
        let t = try TestHome()
        let url = try TokenPaths.fileURL(context: t.context, label: "pool-a")
        #expect(url.path == t.context.dataRoot.path + "/" + TokenPaths.folders[0] + "/pool-a.json")
        #expect(throws: ToolError.self) {
            try TokenPaths.fileURL(context: t.context, label: "../x")
        }
    }

    @Test func opensNoFileAndCreatesNone() throws {
        let t = try TestHome()
        _ = try TokenPaths.fileURL(context: t.context, label: "pool-a")
        let facts = try TokenPaths.facts(context: t.context, label: "pool-a")
        #expect(facts.exists == false)
        #expect(!FileManager.default.fileExists(atPath: t.context.dataRoot.path))

        // A file nobody can read still reports its facts, so the call never opened it.
        let url = try t.makeTokenFile(label: "pool-a", secret: Canaries.oauth())
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        let sealed = try TokenPaths.facts(context: t.context, label: "pool-a")
        #expect(sealed.exists && sealed.isRegularFile && sealed.mode == 0)
        #expect(!sealed.isPrivate)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #expect(try TokenPaths.facts(context: t.context, label: "pool-a").isPrivate)
    }

    @Test func refusesASymlinkedTokensFolder() throws {
        let t = try TestHome()
        let root = t.context.dataRoot
        let elsewhere = root.deletingLastPathComponent()
            .appendingPathComponent("elsewhere-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: elsewhere, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(TokenPaths.folders[0]), withDestinationURL: elsewhere)
        #expect(throws: ToolError.self) {
            try TokenPaths.facts(context: t.context, label: "pool-a")
        }
    }

    @Test func probeLockNamesNeverMatchTheReservedLocks() {
        #expect(Layout.lockName("pick") != "pick.lock")
        #expect(Layout.lockName("history") != "history.lock")
    }
}
