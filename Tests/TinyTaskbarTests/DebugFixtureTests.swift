#if DEBUG
import Testing

@testable import TinyTaskbar

struct DebugFixtureTests {
    @Test("debug fixture parsing accepts only the explicit supported names")
    func fixtureParsing() {
        #expect(
            DebugFixture.parse(arguments: ["TinyTaskbar", "--ui-test-fixture=normal"])
                == .normal)
        #expect(
            DebugFixture.parse(arguments: ["--ui-test-fixture=overflow"]) == .overflow)
        #expect(DebugFixture.parse(arguments: ["--ui-test-fixture=empty"]) == .empty)
        #expect(DebugFixture.parse(arguments: ["--ui-test-fixture=unknown"]) == nil)
        #expect(DebugFixture.parse(arguments: ["--fixture=normal"]) == nil)
    }
}
#endif
