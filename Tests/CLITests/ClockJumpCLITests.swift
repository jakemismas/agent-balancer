import Core
import Foundation
import Testing

@testable import Core

/// A wall clock that moved forward makes nothing in use look old to `refresh`: its launch file
/// upkeep judges ages at the newest time the tool recorded before its probes began.
extension PersonCommandsCLITests {
    @Test func aRefreshAfterTheClockMovedForwardKeepsTheLaunchFileOfAPickNoRecordNamesYet()
        throws
    {
        let cli = try setUp(token: Canary.realShapeToken())
        defer { cli.cleanup() }
        try cli.fakeProbe("ok.jsonl")
        let context = ToolContext(home: cli.home, ambient: [:])
        // A first refresh stores a reading of each account.
        #expect(try cli.run(["refresh"]).status == 0)

        // A pick of 'pool-a' whose session has not started: its lease and its launch file, and
        // what the tool recorded, an hour behind the clock, as after the clock moved an hour
        // forward.
        let back = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 3_600)
        try LeaseStore(context: context).save([
            Lease(id: "l-0a0b0c0d", label: "pool-a", model: "default", at: back)
        ])
        try NoFollowWriter(root: context.dataRoot).put(
            Data("{}".utf8), folders: LaunchFiles.folders(label: "pool-a"),
            name: "l-0a0b0c0d.json")
        let file = try LaunchFiles.fileURL(
            context: context, label: "pool-a", leaseId: "l-0a0b0c0d")
        try FileManager.default.setAttributes([.modificationDate: back], ofItemAtPath: file.path)
        let store = ReadingStore(context: context)
        for label in ["main", "pool-a"] {
            var reading = try #require(try store.load(label: label))
            reading.readAt = back
            try store.save(reading, label: label)
        }
        #expect(Upkeep.newestRecorded(context: context, labels: ["main", "pool-a"]) == back)

        // Its probes store readings at the clock, and its upkeep judges by what the tool recorded
        // before them, so the lease still holds the file.
        #expect(try cli.run(["refresh"]).status == 0)
        let read = try #require(try store.load(label: "pool-a")).readAt
        #expect(read > back.addingTimeInterval(1_800))
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}
