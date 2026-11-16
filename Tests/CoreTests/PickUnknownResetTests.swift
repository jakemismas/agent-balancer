import Foundation
import Testing

@testable import Core

/// A pick whose chosen account's weekly window has no reset time says the reset time is unknown,
/// as that account's own candidate reason does, and ranks as before.
extension PickerTests {
    func noWeeklyReset(five: Double? = 10) -> Reading {
        var r = reading(week: 10, five: five)
        r.windows[WindowName.sevenDay]?.resetsAt = nil
        return r
    }

    @Test(.localZone("UTC")) func aPickWhoseChosenAccountHasNoWeeklyResetSaysTheResetIsUnknown() {
        let d = decide([PickInput(account: pool("a"), reading: noWeeklyReset())])
        #expect(d.chosen == 0)
        #expect(reason(d, "a") == "Resets an unknown time.")
        #expect(d.reason == "Soonest weekly reset: resets an unknown time.")
        #expect(!d.reason.contains(Picker.shortTime(.distantFuture)))
        let fable = decide([PickInput(account: pool("a"), reading: noWeeklyReset())], model: .fable)
        #expect(fable.chosen == 0)
        #expect(
            fable.reason
                == "Soonest weekly reset: resets an unknown time. Fable room guaranteed at 80% of cap."
        )
        let unread = decide([PickInput(account: pool("a"), reading: noWeeklyReset(five: nil))])
        #expect(
            unread.reason == "Soonest weekly reset: resets an unknown time. 5-hour use unknown.")
        let protected = decide([PickInput(account: main(), reading: noWeeklyReset())])
        #expect(protected.chosen == 0)
        #expect(protected.reason == "Soonest weekly reset: resets an unknown time.")
    }

    @Test(.localZone("UTC")) func anAccountWithNoWeeklyResetStillRanksAfterOneWithAKnownReset() {
        let known = PickInput(account: pool("k"), reading: reading(week: 10, resetDays: 6))
        let open = PickInput(account: pool("o"), reading: noWeeklyReset())
        let resets = Picker.shortTime(Self.now.addingTimeInterval(6 * 86_400))
        for order in [[open, known], [known, open]] {
            let d = decide(order)
            #expect(d.chosen.map { order[$0].account.label } == "k")
            #expect(d.reason == "Soonest weekly reset: resets \(resets).")
        }
    }
}
