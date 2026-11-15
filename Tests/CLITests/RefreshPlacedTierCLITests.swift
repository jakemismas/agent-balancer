import Core
import Foundation
import Testing

@testable import Core

/// `refresh` records an account's expected plan only from a check that placed the expected
/// sign-in in the account's own folder.
extension FolderAccountsCLITests {
    /// The folder account's expected plan after one `refresh`, starting from none.
    func tierAfterRefresh(_ cli: CLIHome, auth: String) throws -> String? {
        let store = ConfigStore(context: context(cli))
        var config = try store.loadRequired()
        let index = try #require(config.accounts.firstIndex { $0.label == "spare" })
        config.accounts[index].expectedPlanTier = nil
        try store.save(config)
        try cli.fake("auth.json", auth)
        #expect(try cli.run(["refresh", "--label", "spare", "--force"]).status == 0)
        return try ConfigStore(context: context(cli)).loadRequired().account("spare")?
            .expectedPlanTier
    }

    @Test func refreshRecordsAPlanOnlyFromACheckThatPlacedTheSignIn() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        let own = try folderPath(cli)
        // A plainly different folder, not a spelling of the account's own.
        let elsewhere = cli.home.appendingPathComponent("other/accounts/x/.claude").path
        func auth(email: String? = Self.email, folder: String?) -> String {
            var fields = [#""loggedIn":true"#, #""planTier":"max_20x""#]
            if let email { fields.append(#""email":"\#(email)""#) }
            if let folder { fields.append(#""configDirectory":"\#(folder)""#) }
            return "{" + fields.joined(separator: ",") + "}"
        }
        // Signed in in another folder, with no folder reported, or with no email reported.
        #expect(try tierAfterRefresh(cli, auth: auth(folder: elsewhere)) == nil)
        #expect(try tierAfterRefresh(cli, auth: auth(folder: nil)) == nil)
        #expect(try tierAfterRefresh(cli, auth: auth(email: nil, folder: own)) == nil)
        // Another account in its own folder.
        #expect(
            try tierAfterRefresh(cli, auth: auth(email: "other@example.com", folder: own)) == nil)
        // The expected account in its own folder.
        #expect(try tierAfterRefresh(cli, auth: auth(folder: own)) == "max_20x")
    }
}
