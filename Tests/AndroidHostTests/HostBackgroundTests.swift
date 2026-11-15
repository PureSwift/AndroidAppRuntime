@testable import AndroidHost
import Testing

/// A foreground service that runs what the manifest declares.
final class FakeBackgroundSystem: BackgroundSystem {

    var declared: Int32 = HostBackground.Work.location.rawValue

    var runs: [Int32] = []

    func run(types: Int32) -> Int32 {
        runs.append(types)
        return types & declared
    }
}

/// Serialized: `HostBackground` is global.
@Suite(.serialized) struct HostBackgroundTests {

    let system = FakeBackgroundSystem()

    init() {
        HostBackground.reset()
        HostBackground.system = system
    }

    @Test func runsWhileAnyoneHoldsWork() {
        let first = NSObjectLike(), second = NSObjectLike()
        #expect(HostBackground.set(.location, true, for: first))
        #expect(HostBackground.set(.location, true, for: second))
        #expect(system.runs == [8], "the second holder changes nothing")
        HostBackground.set(.location, false, for: first)
        #expect(HostBackground.running == 8)
        HostBackground.set(.location, false, for: second)
        #expect(system.runs == [8, 0])
        #expect(HostBackground.running == 0)
    }

    @Test func runsOnlyWhatTheManifestDeclares() {
        let owner = NSObjectLike()
        #expect(!HostBackground.set(.bluetooth, true, for: owner), "no connectedDevice service in the manifest")
        #expect(HostBackground.set(.location, true, for: owner))
        #expect(system.runs == [16, 24])
        #expect(HostBackground.running == 8)
        HostBackground.set(.bluetooth, false, for: owner)
        HostBackground.set(.location, false, for: owner)
        #expect(system.runs.last == 0)
    }

    @Test func doesNothingWithoutASystem() {
        HostBackground.system = nil
        #expect(!HostBackground.set(.location, true, for: NSObjectLike()))
    }
}

final class NSObjectLike {}
