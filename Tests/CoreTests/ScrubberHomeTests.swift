import Foundation
import Testing

@testable import Core

/// The home path rule of the second pass for a user whose home folder name holds a space.
@Suite struct ScrubberHomeTests {
    static let name = "Pat" + " Example"

    /// The second pass as it runs for a user whose home folder is `/Users/<name>`.
    func scrub(_ text: String) -> String {
        Scrubber.personalPass(text, homePaths: Scrubber.homePathRule(ownName: Self.name))
    }

    @Test func yourOwnHomeFolderNameIsRedactedWholeWithItsSpace() {
        let home = "/Users/" + Self.name
        #expect(scrub("\(home)/Documents/a.txt") == "/Users/[user]/Documents/a.txt")
        #expect(scrub("cannot read \(home)") == "cannot read /Users/[user]")
        #expect(scrub("'\(home)/x' and \"\(home)\"") == "'/Users/[user]/x' and \"/Users/[user]\"")
    }

    @Test func otherNamesKeepTheRuleThatStopsAtASlashOrSpace() {
        #expect(scrub("/Users/pat/x /Users/Pat2/y") == "/Users/[user]/x /Users/[user]/y")
        #expect(scrub("/Users/Patricia/x") == "/Users/[user]/x")
    }

    @Test func onlyAHomeDirectlyUnderUsersHasAName() {
        #expect(Scrubber.homeName(in: "/Users/" + Self.name) == Self.name)
        #expect(Scrubber.homeName(in: "/var/root") == nil)
        #expect(Scrubber.homeName(in: "/Users/a/b") == nil)
        #expect(Scrubber.homeName(in: "/Users/") == nil)
    }

    @Test func theRunningUsersOwnHomeIsRedacted() throws {
        let home = try #require(Env.userDatabaseHome())
        try #require(home.hasPrefix("/Users/"))
        #expect(Scrubber.personalPass(home + "/Documents") == "/Users/[user]/Documents")
    }

    /// The pass the tool runs takes your own home folder's name from the user database.
    @Test func theToolsPassTakesYourOwnHomeFolderNameFromTheUserDatabase() throws {
        let home = try #require(Env.userDatabaseHome())
        let name = Scrubber.homeName(in: home)
        #expect(name != nil, "no name in the user database's home")
        #expect(Scrubber.userPath.pattern == Scrubber.homePathRule(ownName: name).pattern)
    }
}
