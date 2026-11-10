import Testing

@testable import Core

@Suite struct VersionTests {
    @Test func versionIsSemantic() {
        let parts = Version.current.split(separator: ".")
        #expect(parts.count == 3)
        #expect(parts.allSatisfy { Int($0) != nil })
    }
}
