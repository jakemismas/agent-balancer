import Foundation
import Testing

@testable import Core

/// The menu's timer and stale bound are worked out in `Double`, so no interval can trap.
@Suite struct MenuIntervalTests {
    @Test func theTimerAndTheStaleBoundHoldEveryInterval() {
        #expect(MenuController.refreshSeconds(backgroundMinutes: 10_080) == 604_800)
        #expect(MenuBuilder.staleAfterSeconds(backgroundMinutes: 10_080) == 1_209_600)
        #expect(MenuController.refreshSeconds(backgroundMinutes: .max) == Double(Int.max) * 60)
        #expect(MenuBuilder.staleAfterSeconds(backgroundMinutes: .max) == Double(Int.max) * 120)
    }

    @Test func theMenuReadsAnIntervalPastTheBoundAsTheBound() {
        var config = Config()
        config.refresh.backgroundMinutes = .max
        #expect(StatusReader.backgroundMinutes(config) == ConfigLimits.spanMinutes)
        config.refresh.backgroundMinutes = 0
        #expect(StatusReader.backgroundMinutes(config) == 1)
    }
}
