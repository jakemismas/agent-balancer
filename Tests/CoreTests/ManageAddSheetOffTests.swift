import Foundation
import Testing

@testable import Core

/// When agent-balancer goes missing while the Add sheet is open, the sheet says why Add is off,
/// and an error from an earlier run no longer shows.
extension ManageViewModelTests {
    static let toolMissing = "Management is off: agent-balancer was not found."

    @Test @MainActor func theAddSheetSaysWhyAddIsOffAndDropsAnOldErrorWhenTheToolGoesMissing()
        async throws
    {
        let fake = try Fake()
        try fake.failOn("add spare")
        let vm = Self.model(fake)
        vm.windowOpened()
        vm.openAdd()
        vm.add?.label = "spare"
        await vm.submitAdd()
        let failed = try #require(vm.add)
        #expect(failed.error == "Could not save that.")
        #expect(vm.addNote(failed) == AddNote(text: "Could not save that.", isError: true))

        try FileManager.default.removeItem(at: fake.tool)
        // The reason shows at once, before the window reads again.
        #expect(vm.addNote(try #require(vm.add)) == AddNote(text: Self.toolMissing, isError: false))
        // The window reads again on the menu's next file loop pass.
        vm.statusMayHaveChanged()
        let open = try #require(vm.add)
        #expect(open.error == nil)
        #expect(vm.addProblem(open) == Self.toolMissing)
        #expect(vm.addNote(open) == AddNote(text: Self.toolMissing, isError: false))
        // With the label cleared, the reason still shows.
        vm.add?.label = ""
        #expect(vm.addNote(try #require(vm.add)) == AddNote(text: Self.toolMissing, isError: false))
        await vm.submitAdd()
        #expect(fake.calls() == ["add spare"])
    }

    @Test @MainActor func aToolThatGoesMissingDuringAddLeavesTheSheetTheOffReason() async throws {
        let fake = try Fake()
        // The tool deletes itself and fails, as an uninstall part way through the run would.
        try "#!/bin/sh\nrm -f '\(fake.tool.path)'\nexit 1\n".write(
            to: fake.tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fake.tool.path)
        let vm = Self.model(fake)
        vm.windowOpened()
        vm.openAdd()
        vm.add?.label = "spare"
        await vm.submitAdd()
        #expect(!FileManager.default.fileExists(atPath: fake.tool.path))
        let sheet = try #require(vm.add)
        #expect(sheet.error == nil)
        #expect(vm.addNote(sheet) == AddNote(text: Self.toolMissing, isError: false))
    }

    @Test @MainActor func aFormProblemShowsOnlyOnceALabelIsTyped() throws {
        let fake = try Fake()
        let vm = Self.model(fake)
        vm.openAdd()
        let empty = try #require(vm.add)
        #expect(vm.addProblem(empty) == "Type a label.")
        #expect(vm.addNote(empty) == nil)
        vm.add?.label = "tok-ok"
        #expect(
            vm.addNote(try #require(vm.add))
                == AddNote(text: "That label is already used.", isError: false))
    }
}
