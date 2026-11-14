import Foundation
import Testing

@testable import Core

/// The own-folder check against the scrubber's `[redacted]` marker: what one marker may stand
/// for, two markers side by side, and the label segment, which only a label the scrubber redacts
/// can fill. The scrubber is asked directly for the runs it replaces.
@Suite struct RedactionMarkerTests {
    let marker = Scrubber.redacted

    /// The first `count` characters of a run of distinct lowercase letters and digits, so each is
    /// a valid label and as varied as a run of its length can be.
    static func varied(_ count: Int) -> String {
        String(Array("q7w2e9r4t1y8u3i6o5p0asdfghjklzxcvbnm").prefix(count))
    }

    func folder(_ label: String = "spare-account", home: String = "/home-folder") -> URL {
        URL(fileURLWithPath: "\(home)/.agent-balancer/accounts/\(label)/.claude")
    }

    func reported(label: String = "spare-account", home: String = "/home-folder") -> String {
        "\(home)/.agent-balancer/accounts/\(label)/.claude"
    }

    // MARK: One marker

    @Test func aMarkerStandsForAtLeastOneCharacter() {
        let folder = folder()
        for text in [
            reported(home: "/home-\(marker)"), reported(home: "/\(marker)-folder"),
            reported(home: "/\(marker)"), reported(home: "/h\(marker)r"),
        ] {
            #expect(FolderPaths.sameFolder(text, folder), "\(text)")
        }
        for text in [
            reported(home: "/home-folder\(marker)"), reported(home: "/\(marker)home-folder"),
            reported(home: "/home\(marker)-folder"),
            "/home-folder/.agent-balancer/accounts\(marker)/spare-account/.claude",
            "/home-folder/.agent-balancer/acc\(marker)ounts/spare-account/.claude",
        ] {
            #expect(!FolderPaths.sameFolder(text, folder), "\(text)")
        }
    }

    @Test func textBetweenMarkersMustSitBetweenAtLeastOneCharacterOnEachSide() {
        let text = reported(home: "/a\(marker)m\(marker)b")
        #expect(FolderPaths.sameFolder(text, folder(home: "/axmyb")))
        for home in ["/amxb", "/axmb", "/amb", "/axyb"] {
            #expect(!FolderPaths.sameFolder(text, folder(home: home)), "\(home)")
        }
    }

    // MARK: Two markers side by side

    @Test func adjacentMarkersNeedOneCharacterEachAndNeverMatchAnEmptySegment() {
        let inner = reported(home: "/a\(marker)\(marker)b")
        #expect(FolderPaths.sameFolder(inner, folder(home: "/axyb")))
        #expect(FolderPaths.sameFolder(inner, folder(home: "/axyzb")))
        for home in ["/ab", "/axb"] {
            #expect(!FolderPaths.sameFolder(inner, folder(home: home)), "\(home)")
        }
        let whole = reported(home: "/\(marker)\(marker)")
        #expect(FolderPaths.sameFolder(whole, folder(home: "/xy")))
        #expect(!FolderPaths.sameFolder(whole, folder(home: "/x")))
    }

    // MARK: The label segment

    /// The shortest prefix of `text` that the token pass turns into one marker on its own.
    func shortestRedactedPrefix(of text: String) -> Int? {
        (1...text.count).first { Scrubber.tokenPass(String(text.prefix($0))) == marker }
    }

    @Test func theLabelRuleStartsAtTheScrubbersShortestRedactedRuns() throws {
        // Both runs the token pass replaces, measured on the scrubber itself.
        let token = "sk-" + "ant-" + "oat"
        let prefixRun = try #require(shortestRedactedPrefix(of: token))
        let variedRun = try #require(
            (1...36).first { Scrubber.tokenPass(Self.varied($0)) == marker })
        #expect(prefixRun < variedRun)
        let path = reported(label: marker)

        let prefixLabel = String(token.prefix(prefixRun))
        #expect(ConfigValidator.isValidLabel(prefixLabel))
        #expect(FolderPaths.sameFolder(path, folder(prefixLabel)))
        #expect(!FolderPaths.sameFolder(path, folder(String(prefixLabel.dropLast()))))
        #expect(FolderPaths.sameFolder(path, folder(Self.varied(variedRun))))
        #expect(!FolderPaths.sameFolder(path, folder(Self.varied(variedRun - 1))))
        // No label shorter than the shortest redacted run can stand behind a marker.
        for length in 1..<prefixRun {
            #expect(!FolderPaths.sameFolder(path, folder(Self.varied(length))), "\(length)")
            #expect(
                !FolderPaths.sameFolder(path, folder(String(token.prefix(length)))), "\(length)")
        }
    }

    @Test func aMarkerInTheLabelMatchesOnlyALabelTheScrubberRedactsToThatText() throws {
        let token = "sk-" + "ant-" + "oat"
        let prefixRun = try #require(shortestRedactedPrefix(of: token))
        let holder = "ab-" + String(token.prefix(prefixRun)) + "cd"
        #expect(ConfigValidator.isValidLabel(holder))
        #expect(Scrubber.tokenPass(holder) == "ab-" + marker)
        #expect(FolderPaths.sameFolder(reported(label: "ab-" + marker), folder(holder)))
        #expect(!FolderPaths.sameFolder(reported(label: marker), folder(holder)))
        #expect(!FolderPaths.sameFolder(reported(label: marker + "cd"), folder(holder)))
        // Labels the scrubber leaves as they are, long ones included, never match a marker.
        for label in [
            "spare-account", Self.varied(31), String(repeating: "a", count: 32),
            String(repeating: "ab", count: 16),
        ] {
            #expect(ConfigValidator.isValidLabel(label))
            #expect(Scrubber.tokenPass(label) == label)
            #expect(!FolderPaths.sameFolder(reported(label: marker), folder(label)), "\(label)")
            #expect(!FolderPaths.sameFolder(reported(label: "sp\(marker)"), folder(label)))
        }
        // A report needs a segment besides the last with no marker, even for a label the
        // scrubber redacts whole.
        let long = Self.varied(32)
        #expect(Scrubber.tokenPass(long) == marker)
        #expect(FolderPaths.sameFolder(reported(label: marker), folder(long)))
        let allMarked = "/" + Array(repeating: marker, count: 4).joined(separator: "/") + "/.claude"
        #expect(!FolderPaths.sameFolder(allMarked, folder(long)))
    }

    // MARK: Dot segments

    @Test func aReportedFolderWithADotSegmentNeverMatches() {
        let folder = folder()
        #expect(FolderPaths.sameFolder(reported(), folder))
        for text in [
            "/home-folder/.agent-balancer/accounts/other/../spare-account/.claude",
            "/home-folder/./.agent-balancer/accounts/spare-account/.claude",
            "/home-folder/.agent-balancer/accounts/spare-account/.claude/.",
            "/home-folder/.agent-balancer/accounts/spare-account/.claude/x/..",
        ] {
            #expect(!FolderPaths.sameFolder(text, folder), "\(text)")
        }
    }
}
