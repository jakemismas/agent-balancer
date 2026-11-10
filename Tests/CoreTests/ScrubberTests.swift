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
}
