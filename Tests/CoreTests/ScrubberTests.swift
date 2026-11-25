import Foundation
import Testing

@testable import Core

@Suite struct ScrubberTests {
    @Test func redactsPrefixedTokens() {
        let secret = Canaries.oauth()
        let out = Scrubber.tokenPass("before \(secret) after")
        #expect(!out.contains(secret))
        #expect(out.contains("before") && out.contains("after"))
    }

    @Test func redactsShortPrefixedToken() {
        let out = Scrubber.tokenPass("key sk-" + "ant-abc end")
        #expect(!out.contains("ant-abc"))
    }

    @Test func redactsHighEntropyRun() {
        let run = Canaries.tail(48)
        #expect(!Scrubber.tokenPass("value=\(run);").contains(run))
    }

    @Test func keepsLowEntropyAndShortRuns() {
        let flat = String(repeating: "a", count: 40)
        let short = Canaries.tail(20)
        let out = Scrubber.tokenPass("\(flat) \(short)")
        #expect(out.contains(flat))
        #expect(out.contains(short))
    }

    @Test func tokenPassLeavesEmailsAlone() {
        let mail = "main@example.com"
        #expect(Scrubber.tokenPass("{\"email\":\"\(mail)\"}").contains(mail))
    }

    @Test func personalPassRedactsEmailUuidAndUserPath() {
        let mail = Canaries.email()
        let org = Canaries.orgId()
        let path = Canaries.homePath()
        let out = Scrubber.personalPass("a \(mail) b \(org) c \(path)")
        #expect(!out.contains(mail))
        #expect(!out.contains(org))
        #expect(!out.contains(path))
        #expect(out.contains("/Users/[user]/work"))
    }

    @Test func scrubTextRunsBothPasses() {
        let secret = Canaries.apiKey()
        let mail = Canaries.email()
        let out = Scrubber.scrubText("\(secret) \(mail)")
        #expect(!out.contains(secret))
        #expect(!out.contains(mail))
    }

    @Test func wholeBufferCatchesValueAcrossReadBoundary() {
        let secret = Canaries.oauth()
        let padding = String(repeating: "x ", count: 2046)
        // The secret straddles byte 4096 of the buffer.
        let out = Scrubber.tokenPass(String(padding.prefix(4090)) + secret + " tail")
        #expect(!out.contains(secret))
    }

    @Test func positiveControlDetectorFires() {
        let secret = Canaries.oauth()
        #expect(secret.contains("sk-" + "ant-"))
        #expect(Scrubber.tokenPass(secret) != secret)
    }

    @Test func emailScanMatchesTheAddressForms() {
        #expect(Scrubber.personalPass("mail a.b+c@mail.example.com now") == "mail [email] now")
        #expect(Scrubber.personalPass("x@y z@w.example.com") == "[email] [email]")
        #expect(Scrubber.personalPass("a@b@c.example.com") == "[email]")
        #expect(Scrubber.personalPass("@x.example.com a@ a@b.") == "@x.example.com a@ [email].")
    }

    @Test func anAddressWithALocalPartOutsideASCIIIsRedacted() {
        #expect(Scrubber.personalPass("to j\u{F6}s\u{E9}@example.com now") == "to [email] now")
        #expect(Scrubber.personalPass("to \u{5C71}\u{7530}@example.com now") == "to [email] now")
        #expect(Scrubber.personalPass("to jose\u{301}@example.com now") == "to [email] now")
        #expect(
            Scrubber.personalPass("\u{300C}pat@example.com\u{300D}") == "\u{300C}[email]\u{300D}")
    }

    @Test func anAddressAtABareHostIsRedacted() {
        #expect(Scrubber.personalPass("ssh pat@mailhost failed") == "ssh [email] failed")
        #expect(Scrubber.personalPass("(pat@localhost).") == "([email]).")
    }

    @Test func aHostLabelOutsideASCIIIsRedacted() {
        #expect(Scrubber.personalPass("to pat@\u{4F8B}\u{3048}.jp now") == "to [email] now")
    }

    /// Many separate addresses cost linear time too, since the walk builds its output once.
    @Test func manySeparateAddressesScrubInLinearTime() {
        let count = 1_000_000
        let start = Date()
        let out = Scrubber.personalPass(String(repeating: "a@b ", count: count))
        let seconds = Date().timeIntervalSince(start)
        #expect(seconds < 60, "\(seconds) s")
        let everyAddressRedacted = out == String(repeating: "[email] ", count: count)
        #expect(everyAddressRedacted)
    }

    /// Each rule is one walk over its input, so a long run outside ASCII costs linear time too.
    @Test func aLongRunOutsideASCIIScrubsInLinearTime() {
        let start = Date()
        _ = Scrubber.personalPass(String(repeating: "\u{E9}", count: 262_144) + "@x")
        _ = Scrubber.personalPass(String(repeating: "\u{E9}@", count: 100_000))
        _ = Scrubber.personalPass(String(repeating: "/Users/a b", count: 100_000))
        #expect(Date().timeIntervalSince(start) < 60)
    }

    @Test func aLongRunWithNoAtSignScrubsInLinearTime() {
        let run = String(repeating: "a", count: 1_048_576)
        let start = Date()
        _ = Scrubber.personalPass(run)
        _ = Scrubber.personalPass(String(repeating: "a@", count: 200_000))
        #expect(Date().timeIntervalSince(start) < 5)
    }
}
