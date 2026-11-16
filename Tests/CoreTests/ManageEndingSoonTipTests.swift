import Foundation
import Testing

@testable import Core

/// The ending-soon tip gives its two rules in two sentences, so it cannot be read as ending an
/// account that has no 5-hour reading.
extension ManageViewModelTests {
    @Test func theEndingSoonTipGivesEachRuleInASentenceOfItsOwn() {
        let tip = ManageTips.endingSoon
        #expect(
            tip
                == "Used up first unless it has no 5-hour reading. Treated as ended once its plan drops."
        )
        #expect(Self.sentenceCount(tip) == 2)
        let sentences = tip.split(separator: ". ", maxSplits: 1).map(String.init)
        #expect(sentences.count == 2)
        #expect(sentences.first == "Used up first unless it has no 5-hour reading")
        #expect(sentences.last == "Treated as ended once its plan drops.")
        #expect(ManageTips.all().contains(tip))
    }
}
