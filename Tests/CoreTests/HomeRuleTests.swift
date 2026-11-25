import Foundation
import Testing

@testable import Core

/// One HOME rule roots the data folder for every command and the menu app, and the render flags
/// share it: an absolute path with no `..` segment.
@Suite struct HomeRuleTests {
    static let homes: [(home: String, usable: Bool)] = [
        ("x", false), ("./x", false), ("../x", false), ("x/..", false), ("..", false),
        ("/a/../b", false), ("/a/..", false), ("/..", false), ("~/x", false),
        ("/a/b", true), ("/a//b/", true), ("/a/.b", true), ("/a/..b", true), ("/a/b..", true),
        ("/a/./b", true), ("/", true),
    ]

    /// The home folder the user database names.
    static var userDatabaseHome: String? {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else { return nil }
        return String(cString: dir)
    }

    @Test(arguments: homes.map(\.home))
    func theContextAndTheRenderFlagsHoldOneRule(home: String) throws {
        let usable = try #require(Self.homes.first { $0.home == home }).usable
        #expect(ToolContext.isUsableHome(home) == usable)
        let context = try? ToolContext.current(environment: ["HOME": home])
        #expect((context != nil) == usable)
        #expect(context?.home.path == (usable ? URL(fileURLWithPath: home).path : nil))
        #expect(((try? RenderOutput.homes(environment: ["HOME": home])) != nil) == usable)
    }

    @Test func aRefusedHomeStopsWithAMessageThatNamesHome() {
        #expect(throws: ToolContext.homeRefusal) {
            try ToolContext.current(environment: ["HOME": "x", "PATH": "/usr/bin"])
        }
        #expect(ToolContext.homeRefusal.message.hasPrefix("HOME must be an absolute path"))
    }

    @Test(arguments: [[:], ["HOME": ""]] as [[String: String]])
    func anUnsetOrEmptyHomeFallsBackToTheUserDatabase(environment: [String: String]) throws {
        let database = try #require(Self.userDatabaseHome)
        let context = try ToolContext.current(environment: environment)
        #expect(context.home.path == database)
        #expect(context.ambient == environment)
    }

    @Test func anEmptyHomeStillStopsTheRenderFlags() {
        #expect(throws: RenderOutput.toolFolderRefusal) {
            try RenderOutput.homes(environment: ["HOME": ""])
        }
    }

    /// The fallback is the home folder the user database names, checked by the same rule, and a
    /// database that names no usable home stops the context.
    @Test func theFallbackIsTheUserDatabaseHomeUnderTheSameRule() throws {
        for environment in [[:], ["HOME": ""]] as [[String: String]] {
            let context = try ToolContext.current(
                environment: environment, userDatabaseHome: { "/Users/pat" })
            #expect(context.home.path == "/Users/pat")
        }
        for database in [nil, "", "x", "./x", "/a/../b"] as [String?] {
            #expect(throws: ToolContext.homeRefusal, "\(database ?? "none")") {
                try ToolContext.current(environment: [:], userDatabaseHome: { database })
            }
        }
        let given = try ToolContext.current(
            environment: ["HOME": "/a/b"], userDatabaseHome: { nil })
        #expect(given.home.path == "/a/b")
        #expect(Env.userDatabaseHome() == Self.userDatabaseHome)
    }

    /// Foundation's home follows `CFFIXED_USER_HOME`, which can name a folder under the current
    /// one, so neither the context nor the scrubber's own home name asks it.
    @Test func neitherTheContextNorTheScrubberTakesFoundationsHome() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Core")
        for file in ["Env/Env.swift", "Scrub/Scrubber.swift"] {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            #expect(!text.contains("NSHomeDirectory"), "\(file)")
            #expect(!text.contains("homeDirectory"), "\(file)")
            #expect(text.contains("userDatabaseHome()"), "\(file)")
        }
    }
}
