import Foundation
import Testing

@testable import Core

/// The panel's date picker reports each date it passes through while a date is typed. Only the
/// date the edit finishes on is saved, with one command.
extension ManageViewModelTests {
    /// Typing a year passes through dates the person never meant, today among them.
    static let pickerSteps = ["2026-11-09", "2026-11-20", "2027-11-20", "2027-01-20", "2027-01-25"]

    @Test @MainActor func editingTheEndDateRunsOneCommandForTheDateTheEditFinishesOn()
        async throws
    {
        let fake = try Fake()
        let vm = Self.model(fake)
        vm.selection = "tok-ok"
        for date in Self.pickerSteps { vm.stepEndDate(label: "tok-ok", to: date) }
        // Work the steps queued, if any, gets its turn before anything is checked.
        for _ in 0..<200 { await Task.yield() }
        #expect(!vm.busy)
        #expect(fake.calls().isEmpty)
        // The panel shows the date the edit would save.
        #expect(vm.panel?.ends == .on("2027-01-25"))
        await vm.finishEndDate()
        #expect(fake.calls() == ["config set tok-ok ends 2027-01-25"])
        #expect(vm.bar?.command == "agent-balancer config set tok-ok ends 2027-01-25")
        #expect(vm.endDateEdit == nil)
        // An end with no edit under way runs nothing.
        await vm.finishEndDate()
        #expect(fake.calls().count == 1)
    }

    @Test @MainActor func anEditThatEndsWhileACommandRunsIsKeptAndSavedAtTheNextEnd()
        async throws
    {
        let fake = try Fake()
        let vm = Self.model(fake)
        vm.selection = "tok-ok"
        let first = Task { await vm.run(.setEndingSoon(label: "tok-ok", on: true)) }
        await Self.waitUntilBusy(vm)
        #expect(vm.busy)
        vm.stepEndDate(label: "tok-ok", to: "2027-01-25")
        await vm.finishEndDate()
        #expect(vm.endDateEdit == EndDateEdit(label: "tok-ok", date: "2027-01-25"))
        #expect(await first.value)
        await vm.finishEndDate()
        #expect(vm.endDateEdit == nil)
        #expect(
            fake.calls() == [
                "config set tok-ok ending-soon true", "config set tok-ok ends 2027-01-25",
            ])
    }

    @Test @MainActor func anEndChoiceClickedDuringAnEditReplacesIt() async throws {
        let fake = try Fake()
        let vm = Self.model(fake)
        vm.selection = "fol-ok"
        for date in Self.pickerSteps { vm.stepEndDate(label: "fol-ok", to: date) }
        await vm.changeEnds(label: "fol-ok", to: .soon)
        await vm.finishEndDate()
        #expect(fake.calls() == ["config set fol-ok ending-soon true"])
    }
}
