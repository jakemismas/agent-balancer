import Foundation
import Testing

@testable import Core

/// The plain-email rule `login --browser` applies before it passes an email to claude: the whole
/// text must be one address, so nothing after it rides along.
@Suite struct PlainEmailRuleTests {
    @Test func anAddressFollowedByASpaceOrANewlineAndMoreTextIsNotPlain() {
        #expect(ConfigValidator.isPlainEmail("lab@example.com"))
        for tail in [" more", " --x", "\nmore", "\n--x", "\r\nmore", "\tmore"] {
            #expect(
                !ConfigValidator.isPlainEmail("lab@example.com" + tail), "\(tail.debugDescription)")
        }
        // A newline alone at the end is no address either.
        #expect(!ConfigValidator.isPlainEmail("lab@example.com\n"))
    }
}
