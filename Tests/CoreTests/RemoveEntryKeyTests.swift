import Foundation
import Testing

@testable import Core

/// `remove` deletes a registry entry only while it is still the account its under-lock check saw.
@Suite struct RemoveEntryKeyTests {
    @Test func anEntrySwappedUnderTheLabelAfterTheCheckIsKept() throws {
        let t = try TestHome()
        let store = ConfigStore(context: t.context)
        let spare = Account(label: "spare", kind: Kind.token, role: Role.pool)
        let boss = Account(label: "boss", kind: Kind.login, role: Role.main, reserve: .standard)
        try store.save(Config(accounts: [boss, spare]))
        let loaded = try store.loadRequired()
        var seen: String?
        #expect(throws: ToolError.self) {
            try TokenAccounts.removeAccount(context: t.context, label: "spare", config: loaded) {
                fresh in
                seen = fresh?.account("spare")?.role
                guard seen == Role.pool else { throw ToolError("Needs a terminal.") }
                // A writer that does not take the pick lock swaps the labels after the check.
                var swapped = try store.loadRequired()
                swapped.accounts[0].label = "spare"
                swapped.accounts[1].label = "spare2"
                try store.save(swapped)
            }
        }
        #expect(seen == Role.pool)
        let after = try store.loadRequired()
        let main = try #require(after.accounts.first { $0.role == Role.main })
        #expect(main.accountKey == boss.accountKey)
        #expect(after.account("spare2")?.accountKey == spare.accountKey)
    }

    @Test func theEntryTheCheckSawIsDeleted() throws {
        let t = try TestHome()
        let store = ConfigStore(context: t.context)
        let spare = Account(label: "spare", kind: Kind.token, role: Role.pool)
        let boss = Account(label: "boss", kind: Kind.login, role: Role.main, reserve: .standard)
        try store.save(Config(accounts: [boss, spare]))
        _ = try TokenAccounts.removeAccount(
            context: t.context, label: "spare", config: try store.loadRequired())
        let after = try store.loadRequired()
        #expect(after.account("spare") == nil)
        #expect(after.account("boss")?.accountKey == boss.accountKey)
    }
}
