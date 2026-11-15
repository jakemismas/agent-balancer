import Foundation
import Testing

@testable import Core

/// The window view model's remaining guards: what it builds, what it runs and what it shows when
/// an input or the status file is not what a command needs.
extension ManageViewModelTests {
    @Test func anOptionShapedLabelBuildsNoEndingSoonArguments() {
        for label in ["-x", "--paste"] {
            #expect(ManageCommand.setEndingSoon(label: label, on: true).arguments() == nil)
            #expect(ManageCommand.setEndingSoon(label: label, on: false).arguments() == nil)
        }
    }

    @Test @MainActor func removeCheckRefusesARoleThatIsNeitherMainNorPool() async throws {
        let fake = try Fake()
        let vm = Self.model(fake)
        try Self.typedRemoveSheet(vm, "tok-ok")
        try fake.status(changing: "tok-ok", ["role": "reserve"])
        #expect(vm.removeCheck("tok-ok") == .other)
        await vm.confirmRemove()
        #expect(fake.calls().isEmpty)
        #expect(vm.removeSheet == nil)
        #expect(vm.bar?.text == "Nothing was removed: tok-ok cannot be removed here.")
    }

    @Test @MainActor func signInOnALoginAccountsRowRunsNothing() async throws {
        let fake = try Fake()
        let vm = Self.model(fake, settings: ManageSettings(tokenSignIn: .run, folderSignIn: .run))
        vm.selection = "main"
        await vm.signIn("main")
        #expect(fake.calls().isEmpty)
        #expect(vm.bar == nil)
    }

    @Test @MainActor func reloadMovesTheSelectionToTheFirstAccountWhenTheSelectedOneIsGone()
        throws
    {
        let fake = try Fake()
        let vm = Self.model(fake)
        vm.selection = "fol-wrong"
        try fake.status(changing: "fol-wrong", nil)
        vm.reload()
        #expect(vm.selection == "main")
        #expect(vm.panel?.label == "main")
    }

    @Test @MainActor func canActIsFalseWhileACommandRuns() async throws {
        let fake = try Fake()
        let vm = Self.model(fake)
        #expect(vm.canAct)
        let change = Task { await vm.run(.setEndingSoon(label: "tok-ok", on: true)) }
        await Self.waitUntilBusy(vm)
        #expect(vm.busy)
        #expect(!vm.canAct)
        #expect(await change.value)
        #expect(vm.canAct)
    }

    @Test @MainActor func aLinkedFoldersPanelShowsNoLinkCommand() throws {
        let fake = try Fake()
        let vm = Self.model(fake)
        vm.selection = "fol-ok"
        let linked = try #require(vm.panel)
        #expect(linked.sharedOK)
        #expect(linked.linkCommand == nil)
        vm.selection = "fol-unlinked"
        #expect(vm.panel?.linkCommand == "agent-balancer link fol-unlinked")
    }
}
