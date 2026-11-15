import Core
import Foundation
import Testing

@testable import Core

/// Commands that keep the registry as it was: a refused relabel of a folder account, and `init`
/// over a config that already holds accounts.
extension FolderAccountsCLITests {
    @Test func relabellingAFolderAccountExitsOneAndChangesNeitherTheConfigNorTheFolder() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        let ctx = context(cli)
        let folder = try FolderPaths.configDir(context: ctx, label: "spare")
        let config = cli.read("config.json")
        let inFolder = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()

        let out = try cli.run(["config", "set", "spare", "label", "renamed"])
        #expect(out.status == 1)
        #expect(
            String(decoding: out.stderr, as: UTF8.self).contains(
                "A folder account cannot be renamed: its folder is named for the label. Nothing was changed."
            ))
        #expect(cli.read("config.json") == config)
        #expect(try ConfigStore(context: ctx).loadRequired().account("spare")?.kind == Kind.folder)
        let kept = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(kept == inFolder)
        let renamed = try FolderPaths.configDir(context: ctx, label: "renamed")
        #expect(!FileManager.default.fileExists(atPath: renamed.deletingLastPathComponent().path))
    }

    @Test func initOverAConfigWithTokenAndFolderAccountsKeepsItsSafeMode() throws {
        let cli = try setUp(login: false)
        defer { cli.cleanup() }
        let store = ConfigStore(context: context(cli))
        var config = try store.loadRequired()
        config.accounts.append(Account(label: "lab", kind: Kind.token, role: Role.pool))
        config.probe.safeMode = false
        try store.save(config)
        try cli.fakeFixture("logged_in")

        let out = try cli.run(["init", "--label", "main"])
        #expect(out.status == 0, "\(String(decoding: out.stderr, as: UTF8.self))")
        let after = try store.loadRequired()
        #expect(after.probe.safeMode == false)
        #expect(after.accounts.map(\.label) == ["spare", "lab", "main"])
        #expect(after.account("main")?.kind == Kind.login)
    }
}
