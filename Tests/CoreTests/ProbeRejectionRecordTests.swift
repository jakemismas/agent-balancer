import Foundation
import Testing

@testable import Core

/// A probe's rejection as `state/current.json` records it, a Fable probe's included: of the probes
/// after it, only one that works ends it, and `login --browser` signs a folder in again over it
/// only while that file is sound, of the schema this version writes, and records the rejection for
/// this very account.
@Suite struct ProbeRejectionRecordTests {
    func write(
        _ entry: CurrentEntry, _ context: ToolContext,
        schemaVersion: Int = CurrentFile.currentSchema
    ) throws {
        var file = CurrentFile()
        file.schemaVersion = schemaVersion
        file.accounts["spare"] = entry
        try NoFollowWriter(root: context.dataRoot).put(
            try EventLog.encoder().encode(file), folders: Layout.stateFolders,
            name: "current.json")
    }

    /// An entry whose last probe found the sign-in rejected.
    func rejected(key: String, signInCheck: String = "signed_in") -> CurrentEntry {
        var entry = CurrentEntry(
            accountKey: key, state: "error", code: "login_rejected", since: Date(),
            endedByPlan: false)
        entry.probeError = IssueRecord(Issue(.loginRejected, .error, "Login rejected."))
        entry.signInCheck = signInCheck
        return entry
    }

    let account = Account(
        label: "spare", kind: Kind.folder, role: Role.pool, email: "acct@example.com")

    /// The probe error `entry` holds once the status writer folds in a probe that got `error`
    /// and, when it worked, stored a reading now.
    func probeError(after entry: CurrentEntry, _ error: Core.Issue?) -> IssueRecord? {
        probeError(after: entry, folding: ProbeObservation(error: error, readAt: .at(Date())))
    }

    /// The probe error `entry` holds once the status writer folds in `probe`.
    func probeError(after entry: CurrentEntry, folding probe: ProbeObservation) -> IssueRecord? {
        Transitions.observed(entry, account: account, auth: nil, probe: probe, now: Date())
            .probeError
    }

    @Test func aProbesRejectionStandsWhenTheNextProbeFailsForAnotherReason() {
        let failures = [
            Issue(.checkFailed, .error, "Check failed: probe timed out."),
            Issue(.checkFailed, .error, "Check failed: the probe reply could not be read."),
            Issue(.tokenMissing, .error, "No token saved."),
            Issue(.loginRejected, .error, "Login rejected."),
        ]
        for failure in failures {
            let kept = probeError(after: rejected(key: account.accountKey), failure)
            #expect(kept?.code == "login_rejected", "\(failure.text)")
        }
    }

    @Test func aProbeThatWorksEndsAProbesRejection() {
        #expect(probeError(after: rejected(key: account.accountKey), nil) == nil)
    }

    @Test func aWorkingProbeWhoseReadingTimeIsNotKnownLeavesAProbesRejection() {
        let kept = probeError(
            after: rejected(key: account.accountKey), folding: ProbeObservation(error: nil))
        #expect(kept?.code == "login_rejected")
    }

    /// The probe observation the status writer gets from one account's refresh result.
    func observation(_ plain: RefreshStatus, fable: FableRefreshStatus) -> ProbeObservation? {
        var observations = StatusObservations()
        observations.add([AccountRefresh(label: "spare", status: plain, fable: fable)])
        return observations.probe["spare"]
    }

    let reading = Reading(readAt: Date())
    let rejection = Issue(.loginRejected, .error, "Login rejected.")
    let otherFailure = Issue(.checkFailed, .error, "Check failed: probe timed out.")

    @Test func aFableProbesRejectionIsTheProbeObservationOverAFreshOrAWorkingPlainStep() {
        let steps: [(String, RefreshStatus)] = [
            ("fresh", .fresh(reading)), ("probed", .probed(reading)),
        ]
        for (name, plain) in steps {
            #expect(observation(plain, fable: .failed(rejection))?.error == rejection, "\(name)")
        }
    }

    @Test func aFableProbeThatWorksWhereNoPlainProbeRanEndsAProbesRejection() throws {
        let worked = try #require(observation(.fresh(reading), fable: .probed))
        #expect(worked.error == nil)
        #expect(probeError(after: rejected(key: account.accountKey), folding: worked) == nil)
    }

    @Test func aFableProbeThatFailsForAnotherReasonOrIsStillRunningAddsNothing() {
        #expect(observation(.fresh(reading), fable: .failed(otherFailure)) == nil)
        #expect(observation(.fresh(reading), fable: .notRun) == nil)
        // After a plain probe, that probe's own outcome stands.
        let ends: [(String, FableRefreshStatus)] = [
            ("failed", .failed(otherFailure)), ("running", .notRun),
        ]
        for (name, fable) in ends {
            let kept = observation(.probed(reading), fable: fable)
            #expect(kept != nil && kept?.error == nil, "\(name)")
        }
    }

    @Test func aWorkingProbeEndsARejectionOnlyWhenItsReadingTimeIsNewerThanTheLatestSeen() {
        let seen = Date(timeIntervalSince1970: 1_800_000_000)
        var entry = rejected(key: account.accountKey)
        entry.lastReadingAt = seen
        let times: [(String, ProbeObservation.ReadTime, Bool)] = [
            ("at older", .at(seen.addingTimeInterval(-1)), false),
            ("at seen", .at(seen), false),
            ("at newer", .at(seen.addingTimeInterval(1)), true),
            ("after older", .after(seen.addingTimeInterval(-1)), false),
            ("after seen", .after(seen), false),
            ("after newer", .after(seen.addingTimeInterval(1)), true),
        ]
        // Only a rebuild that could not read the stored reading goes by the probe's own time.
        for stored in [nil, seen] as [Date?] {
            for (name, readAt, ends) in times {
                let folded = Transitions.observed(
                    entry, account: account, auth: nil,
                    probe: ProbeObservation(error: nil, readAt: readAt), storedReadAt: stored,
                    now: Date())
                #expect(
                    (folded.probeError == nil) == (ends && stored == nil),
                    "\(name), \(stored == nil ? "no stored reading" : "the seen one stored")")
            }
        }
    }

    @Test func anObservationCarriesTheTimeOfTheReadingItsProbeStoredOrRanOver() throws {
        let probed = try #require(observation(.probed(reading), fable: .notRun))
        #expect(probed.readAt == .at(reading.readAt))
        let fable = try #require(observation(.fresh(reading), fable: .probed))
        #expect(fable.readAt == .after(reading.readAt))
    }

    @Test func aProbeErrorThatIsNoRejectionGivesWayToTheNextProbesResult() {
        var failed = rejected(key: account.accountKey)
        failed.code = "check_failed"
        let timedOut = Issue(.checkFailed, .error, "Check failed: probe timed out.")
        failed.probeError = IssueRecord(timedOut)
        #expect(probeError(after: failed, nil) == nil)
        let rejection = Issue(.loginRejected, .error, "Login rejected.")
        #expect(probeError(after: failed, rejection) == IssueRecord(rejection))
        let other = Issue(.checkFailed, .error, "Check failed: claude could not run.")
        #expect(probeError(after: failed, other) == IssueRecord(other))
    }

    @Test func aRejectionRecordedForAnotherAccountUnderTheLabelDoesNotCount() throws {
        let t = try TestHome()
        try write(rejected(key: account.accountKey), t.context)
        #expect(StatusBuilder.probeFoundSignInRejected(context: t.context, account: account))
        // A removed account with the same label, whose entry the rebuild after `add` has not
        // dropped yet.
        try write(rejected(key: Account.makeKey()), t.context)
        #expect(!StatusBuilder.probeFoundSignInRejected(context: t.context, account: account))
    }

    @Test func aRejectionInACurrentFileThatIsNotSoundDoesNotCount() throws {
        let t = try TestHome()
        try write(rejected(key: account.accountKey), t.context)
        #expect(StatusBuilder.probeFoundSignInRejected(context: t.context, account: account))
        // A sign-in check value the tool never writes makes the file a damaged record.
        try write(rejected(key: account.accountKey, signInCheck: "seen_elsewhere"), t.context)
        #expect(!StatusBuilder.probeFoundSignInRejected(context: t.context, account: account))
    }

    @Test func aProbeErrorThatIsNoRejectionDoesNotCount() throws {
        let t = try TestHome()
        var entry = rejected(key: account.accountKey)
        entry.code = "check_failed"
        entry.probeError = IssueRecord(Issue(.checkFailed, .error, "Check failed: no usage event."))
        try write(entry, t.context)
        #expect(!StatusBuilder.probeFoundSignInRejected(context: t.context, account: account))
    }

    @Test func aRejectionInACurrentFileOfAnotherSchemaVersionDoesNotCount() throws {
        let t = try TestHome()
        try write(rejected(key: account.accountKey), t.context)
        #expect(StatusBuilder.probeFoundSignInRejected(context: t.context, account: account))
        // A sound file a newer version wrote, read after a downgrade.
        try write(
            rejected(key: account.accountKey), t.context,
            schemaVersion: CurrentFile.currentSchema + 1)
        #expect(!StatusBuilder.probeFoundSignInRejected(context: t.context, account: account))
    }

    // MARK: a working probe whose rebuild lands after the rejection's

    let lab = Account(label: "lab", kind: Kind.token, role: Role.pool)

    /// A reading `seconds` old, dated to the second as the store keeps it.
    func labReading(secondsAgo seconds: Double) -> Reading {
        Reading(readAt: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - seconds))
    }

    /// A home whose config holds `lab`, with `stored` as lab's reading, after a rebuild that
    /// records a probe's rejection of lab.
    func rejectedLab(storing stored: Reading) throws -> TestHome {
        let t = try TestHome()
        try ConfigStore(context: t.context).save(Config(accounts: [lab]))
        try ReadingStore(context: t.context).save(stored, label: "lab")
        try StatusBuilder.rebuild(
            context: t.context,
            observations: StatusObservations(probe: ["lab": ProbeObservation(error: rejection)]))
        try #require(StatusBuilder.probeFoundSignInRejected(context: t.context, account: lab))
        return t
    }

    /// The names of the fields lab's entry in `state/current.json` holds.
    func entryFields(_ t: TestHome) throws -> Set<String> {
        let data = try #require(
            try NoFollowReader(root: t.context.dataRoot).read(
                folders: Layout.stateFolders, name: "current.json"))
        let file = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try #require(file["accounts"] as? [String: Any])
        return Set(try #require(entries["lab"] as? [String: Any]).keys)
    }

    @Test func aWorkingProbeRecordedAfterARejectionEndsItOnlyWhenItsReadingIsNewer() throws {
        // The probe stored the reading the rejection's rebuild saw, or a newer one after it.
        for newer in [false, true] {
            let seen = labReading(secondsAgo: 600)
            let t = try rejectedLab(storing: seen)
            var probed = seen
            if newer {
                probed.readAt = seen.readAt.addingTimeInterval(300)
                try ReadingStore(context: t.context).save(probed, label: "lab")
            }
            var late = StatusObservations()
            late.add([AccountRefresh(label: "lab", status: .probed(probed), fable: .notRun)])
            try StatusBuilder.rebuild(context: t.context, observations: late)
            #expect(
                StatusBuilder.probeFoundSignInRejected(context: t.context, account: lab) == !newer,
                "\(newer)")
            // The probe's reading time stays in memory: the entry keeps the fields it had.
            let fields: Set<String> = [
                "accountKey", "state", "code", "since", "limitedWindow", "limitedSince",
                "limitedUntil", "lastReadingAt", "authError", "probeError", "planTier",
                "loginExpiresAt", "endedByPlan", "expiringNotified", "historyAt",
                "historySignature", "possibleDuplicateOf", "signInCheck", "emailDigest",
            ]
            #expect(try entryFields(t).isSubset(of: fields), "\(newer)")
        }
    }

    @Test func aFableProbeOverAFreshReadingEndsARejectionOnlyWhenThatReadingWasTheLatestSeen()
        throws
    {
        // The rejection's rebuild saw the fresh reading the Fable probe ran over, or the newer
        // one the Fable probe stored.
        for sawFableReading in [false, true] {
            let fresh = labReading(secondsAgo: 600)
            var own = fresh
            own.readAt = fresh.readAt.addingTimeInterval(300)
            let t = try rejectedLab(storing: sawFableReading ? own : fresh)
            try ReadingStore(context: t.context).save(own, label: "lab")
            var late = StatusObservations()
            late.add([AccountRefresh(label: "lab", status: .fresh(fresh), fable: .probed)])
            try StatusBuilder.rebuild(context: t.context, observations: late)
            #expect(
                StatusBuilder.probeFoundSignInRejected(context: t.context, account: lab)
                    == sawFableReading, "\(sawFableReading)")
        }
    }

    @Test func aFableReadingInTheSecondOfTheFreshOneLeavesARejectionThatSawIt() throws {
        // The Fable probe's own reading fell in the second of the fresh one it ran over, and
        // another command's rejection saw that reading before the Fable command rebuilt.
        let fresh = labReading(secondsAgo: 600)
        let t = try rejectedLab(storing: fresh)
        var late = StatusObservations()
        late.add([AccountRefresh(label: "lab", status: .fresh(fresh), fable: .probed)])
        try StatusBuilder.rebuild(context: t.context, observations: late)
        #expect(StatusBuilder.probeFoundSignInRejected(context: t.context, account: lab))
    }

    // MARK: a stored reading newer than the latest the status had seen

    @Test func aStoredReadingEndsAProbesRejectionOnlyWhenItIsNewerThanTheLatestTheStatusHadSeen()
        throws
    {
        // A rebuild that observes nothing, as the menu's each minute, after the reading the
        // rejection's rebuild saw was replaced by a newer one, kept, or replaced by an older one.
        for (shift, ends) in [(300.0, true), (0.0, false), (-300.0, false)] {
            let seen = labReading(secondsAgo: 600)
            let t = try rejectedLab(storing: seen)
            var stored = seen
            stored.readAt = seen.readAt.addingTimeInterval(shift)
            try ReadingStore(context: t.context).save(stored, label: "lab")
            try StatusBuilder.rebuild(context: t.context)
            #expect(
                StatusBuilder.probeFoundSignInRejected(context: t.context, account: lab) == !ends,
                "\(shift)")
        }
    }

    @Test func aStoredReadingNewerThanTheLatestSeenEndsALoginOrFolderAccountsRejection() throws {
        let main = Account(
            label: "main", kind: Kind.login, role: Role.pool, email: "main@example.com")
        for other in [main, account] {
            let t = try TestHome()
            try ConfigStore(context: t.context).save(Config(accounts: [other]))
            let store = ReadingStore(context: t.context)
            let seen = labReading(secondsAgo: 600)
            try store.save(seen, label: other.label)
            try StatusBuilder.rebuild(
                context: t.context,
                observations: StatusObservations(probe: [
                    other.label: ProbeObservation(error: rejection)
                ]))
            try #require(
                StatusBuilder.probeFoundSignInRejected(context: t.context, account: other),
                "\(other.kind)")
            // Another command's working probe stored a newer reading; the menu's rebuild sees it.
            var newer = seen
            newer.readAt = seen.readAt.addingTimeInterval(300)
            try store.save(newer, label: other.label)
            try StatusBuilder.rebuild(context: t.context)
            #expect(
                !StatusBuilder.probeFoundSignInRejected(context: t.context, account: other),
                "\(other.kind)")
        }
    }

    @Test func aRejectionWhoseRebuildHasNoReadingAtAllEndsOnlyOnALaterReading() throws {
        // The status has seen no reading of lab, and the rejection's rebuild ran two minutes ago,
        // partway through a second.
        let rejected = StatusObservations(probe: ["lab": ProbeObservation(error: rejection)])
        let second = labReading(secondsAgo: 120).readAt
        let rebuiltAt = second.addingTimeInterval(0.75)
        let later = second.addingTimeInterval(1)
        // The first reading a rebuild reads after the rejection: one dated before the rejection's
        // rebuild, one dated in its second, or one dated a second later.
        let firstReads: [(String, Date, Bool)] = [
            ("dated before", second.addingTimeInterval(-60), false),
            ("same second", second, false), ("a second later", later, true),
        ]
        for (name, dated, ends) in firstReads {
            let t = try TestHome()
            try ConfigStore(context: t.context).save(Config(accounts: [lab]))
            try StatusBuilder.rebuild(context: t.context, observations: rejected, now: rebuiltAt)
            // A rebuild with no reading that records no rejection keeps that time.
            try StatusBuilder.rebuild(context: t.context, now: rebuiltAt.addingTimeInterval(60))
            #expect(
                StatusBuilder.probeRejection(context: t.context, account: lab) == second,
                "\(name)")
            let store = ReadingStore(context: t.context)
            try store.save(Reading(readAt: dated), label: "lab")
            try StatusBuilder.rebuild(context: t.context)
            #expect(
                StatusBuilder.probeFoundSignInRejected(context: t.context, account: lab) == !ends,
                "\(name)")
            // A reading a working probe stores a second after the rejection ends it.
            try store.save(Reading(readAt: later), label: "lab")
            try StatusBuilder.rebuild(context: t.context)
            #expect(
                !StatusBuilder.probeFoundSignInRejected(context: t.context, account: lab),
                "\(name)")
        }
    }

    @Test func aRejectionObservedInTheSameRebuildAsANewerStoredReadingStands() throws {
        // Another command's probe that worked stored the newer reading before this command's probe
        // was rejected, or this command's plain probe stored it and its Fable probe was rejected.
        let seen = labReading(secondsAgo: 600)
        var newer = seen
        newer.readAt = seen.readAt.addingTimeInterval(300)
        var fable = StatusObservations()
        fable.add([
            AccountRefresh(label: "lab", status: .probed(newer), fable: .failed(rejection))
        ])
        let forms: [(String, StatusObservations)] = [
            ("plain", StatusObservations(probe: ["lab": ProbeObservation(error: rejection)])),
            ("fable", fable),
        ]
        for (name, observations) in forms {
            let t = try rejectedLab(storing: seen)
            try ReadingStore(context: t.context).save(newer, label: "lab")
            try StatusBuilder.rebuild(context: t.context, observations: observations)
            #expect(
                StatusBuilder.probeFoundSignInRejected(context: t.context, account: lab), "\(name)")
            // That rebuild saw the newer reading, so a later one that observes nothing keeps it.
            try StatusBuilder.rebuild(context: t.context)
            #expect(
                StatusBuilder.probeFoundSignInRejected(context: t.context, account: lab), "\(name)")
        }
    }

    // MARK: the time a standing rejection keeps

    @Test func whileAProbesRejectionStandsNoRebuildMovesItsTimeBack() throws {
        // The rejection's rebuild read a reading, or had none and was dated to its own second.
        let seen = labReading(secondsAgo: 300)
        let rebuiltAt = seen.readAt.addingTimeInterval(120.5)
        for hadReading in [true, false] {
            let t = try TestHome()
            try ConfigStore(context: t.context).save(Config(accounts: [lab]))
            let store = ReadingStore(context: t.context)
            if hadReading { try store.save(seen, label: "lab") }
            try StatusBuilder.rebuild(
                context: t.context,
                observations: StatusObservations(probe: ["lab": ProbeObservation(error: rejection)]
                ),
                now: rebuiltAt)
            let dated = try #require(StatusBuilder.probeRejection(context: t.context, account: lab))
            let second = Date(timeIntervalSince1970: floor(rebuiltAt.timeIntervalSince1970))
            #expect(dated == (hadReading ? seen.readAt : second), "\(hadReading)")
            // A copy an hour older is put in place, and rebuilds read it.
            var older = seen
            older.readAt = seen.readAt.addingTimeInterval(-3600)
            try store.save(older, label: "lab")
            try StatusBuilder.rebuild(context: t.context, now: rebuiltAt.addingTimeInterval(60))
            try StatusBuilder.rebuild(context: t.context)
            #expect(
                StatusBuilder.probeRejection(context: t.context, account: lab) == dated,
                "\(hadReading)")
            // So the reading the rejection saw, put back, does not end it either.
            try store.save(seen, label: "lab")
            try StatusBuilder.rebuild(context: t.context)
            #expect(
                StatusBuilder.probeFoundSignInRejected(context: t.context, account: lab),
                "\(hadReading)")
        }
    }

    @Test func aRejectionIsDatedNoEarlierThanTheLatestReadingTheStatusHadSeen() throws {
        // The rejection's rebuild read an older copy, or none with its clock set back before it.
        let seen = labReading(secondsAgo: 300)
        for hadReading in [true, false] {
            let t = try TestHome()
            try ConfigStore(context: t.context).save(Config(accounts: [lab]))
            let store = ReadingStore(context: t.context)
            try store.save(seen, label: "lab")
            try StatusBuilder.rebuild(context: t.context, now: seen.readAt)
            if hadReading {
                var older = seen
                older.readAt = seen.readAt.addingTimeInterval(-3600)
                try store.save(older, label: "lab")
            } else {
                try store.delete(label: "lab")
            }
            try StatusBuilder.rebuild(
                context: t.context,
                observations: StatusObservations(probe: ["lab": ProbeObservation(error: rejection)]
                ),
                now: seen.readAt.addingTimeInterval(-30))
            #expect(
                StatusBuilder.probeRejection(context: t.context, account: lab) == seen.readAt,
                "\(hadReading)")
            // The reading the status had seen, back in place, does not end the rejection.
            try store.save(seen, label: "lab")
            try StatusBuilder.rebuild(context: t.context)
            #expect(
                StatusBuilder.probeFoundSignInRejected(context: t.context, account: lab),
                "\(hadReading)")
            // A reading a second newer does.
            var newer = seen
            newer.readAt = seen.readAt.addingTimeInterval(1)
            try store.save(newer, label: "lab")
            try StatusBuilder.rebuild(context: t.context)
            #expect(
                !StatusBuilder.probeFoundSignInRejected(context: t.context, account: lab),
                "\(hadReading)")
        }
    }

    @Test func aLoginOrFolderAccountsRejectionWithNoUsableReadingIsDatedToItsRebuild() throws {
        let main = Account(
            label: "main", kind: Kind.login, role: Role.pool, email: "main@example.com")
        func rejected(_ label: String) -> StatusObservations {
            StatusObservations(probe: [label: ProbeObservation(error: rejection)])
        }
        // The rejection's rebuild ran partway through a second, with no usable reading.
        let seen = labReading(secondsAgo: 600)
        let rebuiltAt = seen.readAt.addingTimeInterval(480.75)
        let second = seen.readAt.addingTimeInterval(480)
        let firstReads: [(String, Date, Bool)] = [
            ("dated before", seen.readAt.addingTimeInterval(300), false),
            ("same second", second, false), ("a second later", second.addingTimeInterval(1), true),
        ]
        for other in [main, account] {
            for unreadable in [false, true] {
                for (name, dated, ends) in firstReads {
                    let form = "\(other.kind), \(unreadable ? "cannot be read" : "none"), \(name)"
                    let t = try TestHome()
                    try ConfigStore(context: t.context).save(Config(accounts: [other]))
                    let store = ReadingStore(context: t.context)
                    if unreadable {
                        try store.save(seen, label: other.label)
                        try StatusBuilder.rebuild(context: t.context, now: seen.readAt)
                        try whileReadingCannotBeRead(t, other.label) {
                            try StatusBuilder.rebuild(
                                context: t.context, observations: rejected(other.label),
                                now: rebuiltAt)
                        }
                    } else {
                        try StatusBuilder.rebuild(
                            context: t.context, observations: rejected(other.label),
                            now: rebuiltAt)
                    }
                    // A rebuild with no usable reading that records no rejection keeps that time.
                    if !unreadable {
                        try StatusBuilder.rebuild(
                            context: t.context, now: rebuiltAt.addingTimeInterval(60))
                    }
                    #expect(
                        StatusBuilder.probeRejection(context: t.context, account: other) == second,
                        "\(form)")
                    var reading = seen
                    reading.readAt = dated
                    try store.save(reading, label: other.label)
                    try StatusBuilder.rebuild(context: t.context)
                    #expect(
                        StatusBuilder.probeFoundSignInRejected(context: t.context, account: other)
                            == !ends, "\(form)")
                }
            }
        }
    }

    // MARK: a stored reading the rejection's rebuild cannot read

    /// Runs `body` while the stored reading of `label` exists but cannot be read, then makes it
    /// readable again, pass or fail.
    func whileReadingCannotBeRead(_ t: TestHome, _ label: String, _ body: () throws -> Void)
        throws
    {
        let path = t.context.dataRoot.appendingPathComponent("state/readings/\(label).json").path
        try #require(chmod(path, 0) == 0)
        defer { chmod(path, 0o600) }
        #expect(throws: (any Error).self) {
            try ReadingStore(context: t.context).load(label: label)
        }
        try body()
    }

    /// Runs `body` while lab's stored reading exists but cannot be read, then makes it readable
    /// again, pass or fail.
    func whileLabReadingCannotBeRead(_ t: TestHome, _ body: () throws -> Void) throws {
        try whileReadingCannotBeRead(t, "lab", body)
    }

    @Test func aRejectionWhoseRebuildCannotReadTheStoredReadingEndsOnlyOnALaterReading() throws {
        // The rejecting command's plain probe was rejected, or its plain probe stored the reading
        // and its Fable probe was rejected. Either way the reading was stored before the rebuild.
        let seen = labReading(secondsAgo: 600)
        var before = seen
        before.readAt = seen.readAt.addingTimeInterval(300)
        var fable = StatusObservations()
        fable.add([
            AccountRefresh(label: "lab", status: .probed(before), fable: .failed(rejection))
        ])
        let forms: [(String, StatusObservations)] = [
            ("plain", StatusObservations(probe: ["lab": ProbeObservation(error: rejection)])),
            ("fable", fable),
        ]
        // The rejection's rebuild ran two minutes ago, partway through a second.
        let rebuiltAt = seen.readAt.addingTimeInterval(480.75)
        let second = seen.readAt.addingTimeInterval(480)
        let later = second.addingTimeInterval(1)
        // The first reading a rebuild reads after the rejection: the one stored before it, one
        // dated in the second of the rejection's rebuild, or one dated a second later.
        let firstReads: [(String, Date?, Bool)] = [
            ("stored before", nil, false), ("same second", second, false),
            ("a second later", later, true),
        ]
        for (form, observations) in forms {
            for (name, dated, ends) in firstReads {
                let t = try TestHome()
                try ConfigStore(context: t.context).save(Config(accounts: [lab]))
                let store = ReadingStore(context: t.context)
                try store.save(seen, label: "lab")
                try StatusBuilder.rebuild(context: t.context, now: seen.readAt)
                try store.save(before, label: "lab")
                try whileLabReadingCannotBeRead(t) {
                    try StatusBuilder.rebuild(
                        context: t.context, observations: observations, now: rebuiltAt)
                    // A rebuild that cannot read it and records no rejection keeps that time.
                    try StatusBuilder.rebuild(
                        context: t.context, now: rebuiltAt.addingTimeInterval(60))
                }
                #expect(
                    StatusBuilder.probeRejection(context: t.context, account: lab) == second,
                    "\(form), \(name)")
                if let dated {
                    var stored = before
                    stored.readAt = dated
                    try store.save(stored, label: "lab")
                }
                try StatusBuilder.rebuild(context: t.context)
                #expect(
                    StatusBuilder.probeFoundSignInRejected(context: t.context, account: lab)
                        == !ends, "\(form), \(name)")
                // A reading a working probe stores a second after the rejection ends it.
                var newer = before
                newer.readAt = later
                try store.save(newer, label: "lab")
                try StatusBuilder.rebuild(context: t.context)
                #expect(
                    !StatusBuilder.probeFoundSignInRejected(context: t.context, account: lab),
                    "\(form), \(name)")
            }
        }
    }

    /// Each file a status rebuild writes that is there now, by name, with its file number and
    /// bytes, so a rewrite shows even when the bytes stay the same.
    func rebuildFiles(_ t: TestHome) throws -> [String: String] {
        let places =
            [
                StatusBuilder.currentName, StatusBuilder.statusName, StatusBuilder.rejectionsName,
                StatusBuilder.checksName, EventLog.fileName,
            ].map { (Layout.stateFolders, $0) }
            + [(ReadingHistory.folders, ReadingHistory.fileName("lab"))]
        var files: [String: String] = [:]
        for (folders, name) in places {
            let url = (folders + [name]).reduce(t.context.dataRoot) {
                $0.appendingPathComponent($1)
            }
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let number = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            let data = try Data(contentsOf: url)
            files[name] = "\(number) \(data.base64EncodedString())"
        }
        return files
    }

    @Test func aRebuildThatCannotTakeTheTokenRecordsLockSavesNothing() throws {
        // lab's token was rejected, and a new token's first check stored a newer reading and
        // worked while its own rebuild saved no state, so `login` kept that check.
        let t = try rejectedLab(storing: labReading(secondsAgo: 600))
        let checked = labReading(secondsAgo: 300)
        try ReadingStore(context: t.context).save(checked, label: "lab")
        try #require(
            StatusBuilder.markNewToken(context: t.context, account: lab, at: checked.readAt))
        let before = try rebuildFiles(t)
        // A later probe of the new token, as a `pick` runs one, finds it rejected.
        var later = StatusObservations()
        later.add([AccountRefresh(label: "lab", status: .failed(rejection), fable: .notRun)])
        let held = try #require(
            try NoFollowWriter(root: t.context.dataRoot).acquireLock(
                folders: Layout.locksFolders, name: StatusBuilder.recordsLockName, wait: 120))
        let first = try StatusBuilder.rebuilt(
            context: t.context, observations: later, now: Date(), lockWait: 0.2)
        held.release()
        #expect(first == nil)
        #expect(try rebuildFiles(t) == before)
        let log = try String(
            contentsOf: t.context.dataRoot.appendingPathComponent("logs/agent-balancer.log"),
            encoding: .utf8)
        #expect(log.contains("status rebuild skipped: the token records lock stayed held"))
        // A result whose rebuild saved no state goes to the next rebuild, as `refresh` does.
        try StatusBuilder.rebuild(
            context: t.context,
            observations: first?.savedState == true ? StatusObservations() : later)
        #expect(StatusBuilder.probeFoundSignInRejected(context: t.context, account: lab))
        // The kept check went with the state that folded it, so a later rebuild keeps the rejection.
        try StatusBuilder.rebuild(context: t.context)
        #expect(StatusBuilder.probeFoundSignInRejected(context: t.context, account: lab))
    }
}

// MARK: the token records a rebuild reads at its start and saves at its end

extension ProbeRejectionRecordTests {
    /// The bytes of `name` in `state/`, nil when it is not there.
    func stateBytes(_ t: TestHome, _ name: String) throws -> Data? {
        try NoFollowReader(root: t.context.dataRoot).read(folders: Layout.stateFolders, name: name)
    }

    /// True while `state/token-checks.json` keeps a new token's check of lab.
    func labCheckKept(_ t: TestHome) -> Bool {
        let reader = NoFollowReader(root: t.context.dataRoot)
        return StatusBuilder.loadRecords(reader, name: StatusBuilder.checksName).file.tokens["lab"]
            != nil
    }

    func logText(_ t: TestHome) -> String {
        let log = t.context.dataRoot.appendingPathComponent("logs/agent-balancer.log")
        return (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    }

    /// The path of `name` in `state/`.
    func statePath(_ t: TestHome, _ name: String) -> String {
        t.context.dataRoot.appendingPathComponent("state").appendingPathComponent(name).path
    }

    /// lab rejected after a reading stored while the clock ran an hour ahead, then a new token
    /// whose first check worked, kept by `login` because its own rebuild saved no state.
    func labRejectedAheadWithAKeptCheck() throws -> TestHome {
        let t = try rejectedLab(storing: labReading(secondsAgo: -3600))
        let checked = labReading(secondsAgo: 1)
        try ReadingStore(context: t.context).save(checked, label: "lab")
        try #require(
            StatusBuilder.markNewToken(context: t.context, account: lab, at: checked.readAt))
        return t
    }

    /// Puts a folder in place of `state/token-checks.json`. Returns how to undo it.
    func breakChecks(_ t: TestHome) throws -> () throws -> Void {
        let path = statePath(t, StatusBuilder.checksName)
        let aside = t.home.appendingPathComponent("aside-checks").path
        try #require(rename(path, aside) == 0)
        try FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: false)
        return {
            try FileManager.default.removeItem(atPath: path)
            try #require(rename(aside, path) == 0)
        }
    }

    @Test func aRejectionKeptWhileARebuildRunsOutlivesThatRebuild() throws {
        // lab's token was rejected, and a probe that worked then stored a newer reading.
        let t = try rejectedLab(storing: labReading(secondsAgo: 600))
        try ReadingStore(context: t.context).save(labReading(secondsAgo: 300), label: "lab")
        // While another command's rebuild runs, a later probe finds the token rejected again and
        // `refresh` keeps that rejection.
        let rebuilt = try StatusBuilder.rebuilt(
            context: t.context, observations: StatusObservations(), now: Date(), lockWait: nil,
            afterRecordsRead: {
                #expect(StatusBuilder.keepRejection(context: t.context, account: lab))
            })
        #expect(rebuilt?.savedState == true)
        // The newer reading ends the rejection that rebuild saw, not the one kept after it.
        #expect(StatusBuilder.probeRejection(context: t.context, account: lab) != nil)
        try StatusBuilder.rebuild(context: t.context)
        #expect(StatusBuilder.probeRejection(context: t.context, account: lab) != nil)
    }

    @Test(arguments: [true, false])
    func aNewTokenCheckKeptWhileARebuildRunsIsFoldedByTheNextRebuild(recordThere: Bool) throws {
        // lab's token was rejected after a reading stored while the clock ran an hour ahead.
        let t = try rejectedLab(storing: labReading(secondsAgo: -3600))
        if !recordThere {
            // Only `current.json` holds the rejection, as after its record could not be saved.
            try NoFollowWriter(root: t.context.dataRoot).put(
                try EventLog.encoder().encode(StatusBuilder.RejectionsFile()) + Data([0x0A]),
                folders: Layout.stateFolders, name: StatusBuilder.rejectionsName)
        }
        // While another command's rebuild runs, a new token's first check works and `login`
        // keeps it.
        let rebuilt = try StatusBuilder.rebuilt(
            context: t.context, observations: StatusObservations(), now: Date(), lockWait: nil,
            afterRecordsRead: {
                let checked = labReading(secondsAgo: 1)
                #expect((try? ReadingStore(context: t.context).save(checked, label: "lab")) != nil)
                #expect(
                    StatusBuilder.markNewToken(
                        context: t.context, account: lab, at: checked.readAt))
            })
        #expect(rebuilt?.savedState == true)
        // That rebuild read the records before the check, so it leaves the check to the next.
        #expect(labCheckKept(t))
        try StatusBuilder.rebuild(context: t.context)
        #expect(StatusBuilder.probeRejection(context: t.context, account: lab) == nil)
        #expect(!labCheckKept(t))
    }

    @Test func aRebuildThatCannotReadTheKeptChecksSavesNothing() throws {
        let t = try labRejectedAheadWithAKeptCheck()
        // A later probe of the new token, as a `pick` runs one, finds it rejected.
        var later = StatusObservations()
        later.add([AccountRefresh(label: "lab", status: .failed(rejection), fable: .notRun)])
        let before = try rebuildFiles(t)
        let undo = try breakChecks(t)
        let first = try StatusBuilder.rebuilt(
            context: t.context, observations: later, now: Date(), lockWait: nil)
        try undo()
        #expect(first == nil)
        #expect(try rebuildFiles(t) == before)
        #expect(
            logText(t).contains(
                "status rebuild skipped: state/token-checks.json could not be read"))
        // A result whose rebuild saved no state goes to the next rebuild, as `refresh` does.
        try StatusBuilder.rebuild(context: t.context, observations: later)
        #expect(StatusBuilder.probeFoundSignInRejected(context: t.context, account: lab))
        try StatusBuilder.rebuild(context: t.context)
        #expect(StatusBuilder.probeFoundSignInRejected(context: t.context, account: lab))
    }

    @Test func aRebuildThatCannotReadTheKeptChecksAtItsEndSavesNoState() throws {
        let t = try labRejectedAheadWithAKeptCheck()
        let current = try stateBytes(t, StatusBuilder.currentName)
        let rejections = try stateBytes(t, StatusBuilder.rejectionsName)
        let checks = try stateBytes(t, StatusBuilder.checksName)
        var undo: (() throws -> Void)?
        let rebuilt = try StatusBuilder.rebuilt(
            context: t.context, observations: StatusObservations(), now: Date(), lockWait: nil,
            afterRecordsRead: { undo = try? breakChecks(t) })
        try #require(undo != nil)
        try undo?()
        #expect(rebuilt?.savedState == false)
        #expect(
            logText(t).contains(
                "token records step skipped: state/token-checks.json could not be read"))
        #expect(try stateBytes(t, StatusBuilder.currentName) == current)
        #expect(try stateBytes(t, StatusBuilder.rejectionsName) == rejections)
        #expect(try stateBytes(t, StatusBuilder.checksName) == checks)
        try StatusBuilder.rebuild(context: t.context)
        #expect(StatusBuilder.probeRejection(context: t.context, account: lab) == nil)
    }

    @Test func aKeptCheckStaysWhenTheRebuildThatFoldsItCannotSaveTheState() throws {
        let t = try labRejectedAheadWithAKeptCheck()
        let current = statePath(t, StatusBuilder.currentName)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: current)
        defer {
            try? FileManager.default.setAttributes(
                [.immutable: false], ofItemAtPath: statePath(t, StatusBuilder.currentName))
        }
        #expect(throws: (any Error).self) { try StatusBuilder.rebuild(context: t.context) }
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: current)
        #expect(labCheckKept(t))
        try StatusBuilder.rebuild(context: t.context)
        #expect(StatusBuilder.probeRejection(context: t.context, account: lab) == nil)
    }

    @Test func aRebuildThatCannotClearAKeptCheckItFoldedSavesNoState() throws {
        let t = try labRejectedAheadWithAKeptCheck()
        let current = try stateBytes(t, StatusBuilder.currentName)
        let checks = statePath(t, StatusBuilder.checksName)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: checks)
        defer {
            try? FileManager.default.setAttributes(
                [.immutable: false], ofItemAtPath: statePath(t, StatusBuilder.checksName))
        }
        let rebuilt = try StatusBuilder.rebuilt(
            context: t.context, observations: StatusObservations(), now: Date(), lockWait: nil)
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: checks)
        #expect(rebuilt?.savedState == false)
        #expect(logText(t).contains("token checks step failed"))
        #expect(try stateBytes(t, StatusBuilder.currentName) == current)
        #expect(labCheckKept(t))
        try StatusBuilder.rebuild(context: t.context)
        #expect(StatusBuilder.probeRejection(context: t.context, account: lab) == nil)
    }

    @Test func aRejectionKeptAfterAKeptNewTokenCheckOutlivesTheFoldOfThatCheck() throws {
        let t = try rejectedLab(storing: labReading(secondsAgo: 600))
        let checked = labReading(secondsAgo: 300)
        try ReadingStore(context: t.context).save(checked, label: "lab")
        try #require(
            StatusBuilder.markNewToken(context: t.context, account: lab, at: checked.readAt))
        // The new token is rejected too, and `refresh` keeps that before any rebuild saves state.
        try #require(StatusBuilder.keepRejection(context: t.context, account: lab))
        try StatusBuilder.rebuild(context: t.context)
        #expect(StatusBuilder.probeRejection(context: t.context, account: lab) != nil)
    }

    @Test func aKeptCheckOfAnotherAccountUnderTheLabelLeavesItsRejection() throws {
        let t = try rejectedLab(storing: labReading(secondsAgo: 600))
        // A check kept for the account the label held before, not yet folded.
        let other = Account(label: "lab", kind: Kind.token, role: Role.pool)
        try #require(other.accountKey != lab.accountKey)
        try #require(
            StatusBuilder.markNewToken(
                context: t.context, account: other, at: labReading(secondsAgo: 300).readAt))
        try StatusBuilder.rebuild(context: t.context)
        #expect(StatusBuilder.probeRejection(context: t.context, account: lab) != nil)
        #expect(StatusBuilder.probeFoundSignInRejected(context: t.context, account: lab))
    }

    @Test func aWorkingProbeOfTheLabelsFormerAccountLeavesTheNewAccountsRejection() throws {
        // A new token account under the label, with no stored reading, whose first check was
        // rejected.
        let t = try TestHome()
        try ConfigStore(context: t.context).save(Config(accounts: [lab]))
        try StatusBuilder.rebuild(
            context: t.context,
            observations: StatusObservations(probe: [
                "lab": ProbeObservation(error: rejection, accountKey: lab.accountKey)
            ]))
        try #require(StatusBuilder.probeFoundSignInRejected(context: t.context, account: lab))
        // The probe of the account the label held before worked, with a reading dated after the
        // rejection, as when the wall clock was set back in between.
        let later = Date().addingTimeInterval(120)
        try StatusBuilder.rebuild(
            context: t.context,
            observations: StatusObservations(probe: [
                "lab": ProbeObservation(error: nil, readAt: .at(later), accountKey: "renamed")
            ]))
        #expect(StatusBuilder.probeFoundSignInRejected(context: t.context, account: lab))
    }
}
