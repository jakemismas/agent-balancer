import Foundation
import Testing

@testable import Core

/// The app shows its Dock icon while the Manage accounts window is open and takes it away when
/// the window closes, through the view model's Dock seam.
extension ManageViewModelTests {
    /// Stands in for the app's activation policy: true while the app is in the Dock.
    @MainActor final class DockRecord {
        var calls: [Bool] = []
        var shown: Bool { calls.last ?? false }
    }

    @Test @MainActor func theDockIconShowsWhileTheWindowIsOpenAndGoesWhenItCloses() throws {
        let fake = try Fake()
        let dock = DockRecord()
        LocalTime.zone = TimeZone(identifier: "America/Los_Angeles")!
        let vm = ManageViewModel(
            context: fake.context, runner: fake.runner, clock: { Self.now },
            dock: { dock.calls.append($0) })
        #expect(dock.calls.isEmpty)
        vm.windowOpened()
        #expect(dock.shown)
        // Reads while the window is open leave the icon where it is.
        vm.statusMayHaveChanged()
        vm.select("tok-ok")
        #expect(dock.shown)
        vm.windowClosed()
        #expect(!dock.shown)
        #expect(dock.calls == [true, false])
        // A second opening shows it again.
        vm.windowOpened()
        #expect(dock.calls == [true, false, true])
    }
}
