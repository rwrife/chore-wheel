#if canImport(ChoreWheelCore)
import ChoreWheelCore
#elseif canImport(ChoreWheel)
@testable import ChoreWheel
#endif
import Testing

@Suite("Scaffold")
struct ScaffoldTests {
    @Test("scaffold version is pinned")
    func scaffoldVersion() {
        #expect(ChoreWheelScaffold.scaffoldVersion == 1)
    }
}
