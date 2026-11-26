import Foundation
import Testing

@testable import Core

/// A probe's result counts only for the account it was made for, as a sign-in check does: once
/// its label holds another account, as after a rename, or a remove and an add, while the probe
/// ran, a status rebuild takes neither its result nor its duplicate check for the account there.
@Suite struct ProbeAccountKeyTests {
    @Test func aProbeCountsOnlyForTheAccountItWasMadeFor() {
        let probed = Account(label: "main", kind: Kind.token, role: Role.pool)
        let there = Account(label: "main", kind: Kind.token, role: Role.pool)
        let rejected = Issue(.loginRejected, .error, "Login rejected.")
        let reading = Reading(readAt: Date())
        // A plain probe that worked or was rejected, and a Fable rejection on a fresh reading.
        let results = [
            AccountRefresh(
                label: "main", status: .probed(reading), fable: .notRun,
                duplicate: .sameAs("spare"), accountKey: probed.accountKey),
            AccountRefresh(
                label: "main", status: .failed(rejected), fable: .notRun,
                accountKey: probed.accountKey),
            AccountRefresh(
                label: "main", status: .fresh(reading), fable: .failed(rejected),
                accountKey: probed.accountKey),
        ]
        for result in results {
            var observations = StatusObservations()
            observations.add([result])
            #expect(observations.probe(for: there) == nil)
            #expect(observations.duplicate(for: there) == .notRun)
            #expect(observations.probe(for: probed) != nil)
            #expect(observations.duplicate(for: probed) == result.duplicate)
        }
        // A result with no key counts for the account the rebuild folds it into.
        var unkeyed = StatusObservations()
        unkeyed.add([AccountRefresh(label: "main", status: .failed(rejected), fable: .notRun)])
        #expect(unkeyed.probe(for: there)?.error?.code == .loginRejected)
    }
}
