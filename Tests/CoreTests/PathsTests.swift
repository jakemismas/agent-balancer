import Foundation
import Testing

@testable import Core

@Suite struct PathsTests {
    func mode(_ url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.posixPermissions] as! NSNumber).intValue
    }

    @Test func writesFilesAt0600AndFoldersAt0700() throws {
        let t = try TestHome()
        let writer = NoFollowWriter(root: t.context.dataRoot)
        try writer.put(Data("x".utf8), folders: ["state", "readings"], name: "a.json")
        #expect(try mode(t.context.dataRoot) == 0o700)
        #expect(try mode(t.context.dataRoot.appendingPathComponent("state")) == 0o700)
        #expect(
            try mode(t.context.dataRoot.appendingPathComponent("state/readings/a.json")) == 0o600)
    }

    @Test func replacingAFileLeavesNoTemporaryName() throws {
        let t = try TestHome()
        let writer = NoFollowWriter(root: t.context.dataRoot)
        try writer.put(Data("one".utf8), folders: [], name: "a.json")
        try writer.put(Data("two".utf8), folders: [], name: "a.json")
        let names = try FileManager.default.contentsOfDirectory(atPath: t.context.dataRoot.path)
        #expect(names == ["a.json"])
        let read = try NoFollowReader(root: t.context.dataRoot).read(folders: [], name: "a.json")
        #expect(read == Data("two".utf8))
    }

    @Test func aSymlinkedSubfolderIsRefused() throws {
        let t = try TestHome()
        let writer = NoFollowWriter(root: t.context.dataRoot)
        try writer.prepare(folders: [])
        let outside = t.home.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: t.context.dataRoot.appendingPathComponent("state"), withDestinationURL: outside)
        #expect(throws: ToolError.self) {
            try writer.put(Data("x".utf8), folders: ["state"], name: "a.json")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func aSymlinkedFinalNameIsRefused() throws {
        let t = try TestHome()
        let writer = NoFollowWriter(root: t.context.dataRoot)
        try writer.prepare(folders: [])
        let target = t.home.appendingPathComponent("victim.txt")
        try "keep".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: t.context.dataRoot.appendingPathComponent("links.json"), withDestinationURL: target)
        #expect(throws: ToolError.self) {
            try writer.put(Data("x".utf8), folders: [], name: "links.json")
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "keep")
    }

    @Test func aSymlinkedDataRootIsRefused() throws {
        let t = try TestHome()
        let outside = t.home.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: t.context.dataRoot, withDestinationURL: outside)
        #expect(throws: ToolError.self) {
            try NoFollowWriter(root: t.context.dataRoot).put(
                Data("x".utf8), folders: [], name: "a.json")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func aWideFolderIsRefused() throws {
        let t = try TestHome()
        let writer = NoFollowWriter(root: t.context.dataRoot)
        try writer.prepare(folders: ["state"])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: t.context.dataRoot.appendingPathComponent("state").path)
        #expect(throws: ToolError.self) {
            try writer.put(Data("x".utf8), folders: ["state"], name: "a.json")
        }
    }

    @Test func readRefusesALinkedFileAndReturnsNilForAMissingOne() throws {
        let t = try TestHome()
        let writer = NoFollowWriter(root: t.context.dataRoot)
        try writer.prepare(folders: [])
        let reader = NoFollowReader(root: t.context.dataRoot)
        #expect(try reader.read(folders: [], name: "nope.json") == nil)
        #expect(try reader.read(folders: ["nofolder"], name: "nope.json") == nil)
        let target = t.home.appendingPathComponent("t.txt")
        try "x".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: t.context.dataRoot.appendingPathComponent("l.json"), withDestinationURL: target)
        #expect(throws: ToolError.self) { try reader.read(folders: [], name: "l.json") }
    }

    @Test func unsafeNamesAreRefused() throws {
        let t = try TestHome()
        let writer = NoFollowWriter(root: t.context.dataRoot)
        for bad in ["", ".", "..", "a/b"] {
            #expect(throws: ToolError.self) { try writer.put(Data(), folders: [], name: bad) }
        }
        #expect(throws: ToolError.self) { try writer.put(Data(), folders: [".."], name: "a") }
    }
}
