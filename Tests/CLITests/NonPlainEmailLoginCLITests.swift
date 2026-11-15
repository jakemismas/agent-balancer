import Core
import Foundation
import Testing

@testable import Core

/// A folder whose expected email starts with a hyphen is never signed in through the browser:
/// `login --browser` refuses it before claude starts, so the email can never act as an option.
extension FolderAccountsCLITests {
    @Test func aBrowserSignInRefusesAnEmailThatStartsWithAHyphenBeforeClaudeStarts() throws {
        let cli = try setUp(folder: false)
        defer { cli.cleanup() }
        let added = try cli.run(["add", "dash", "--kind", "folder", "--email=-dash@example.com"])
        #expect(added.status == 0, "\(String(decoding: added.stderr, as: UTF8.self))")
        #expect(
            try ConfigStore(context: context(cli)).loadRequired().account("dash")?.email
                == "-dash@example.com")
        let link = try cli.runOnTerminal(["link", "dash"], typing: "dash\n")
        #expect(link.status == 0)
        // Signed out, so nothing but the email rule can stop the sign-in.
        let folder = try FolderPaths.configDir(context: context(cli), label: "dash").path
        try cli.fake(
            "auth.json",
            #"{"loggedIn":false,"email":"-dash@example.com","configDirectory":"\#(folder)"}"#)

        let out = try cli.run(["login", "dash", "--browser"])
        #expect(out.status == 1)
        let said = String(decoding: out.stderr, as: UTF8.self)
        #expect(said.contains(Messages.emailNotPlain("dash")))
        #expect(!cli.fakeRecord("args.log").contains("auth login"))
    }
}
