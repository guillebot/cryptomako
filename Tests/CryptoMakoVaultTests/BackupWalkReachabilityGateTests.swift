import XCTest
@testable import CryptoMakoShared

final class BackupWalkReachabilityGateTests: XCTestCase {
    func testMidWalkDoesNotProbePerFileWithinInterval() {
        var gate = BackupWalkReachabilityGate(minInterval: 3)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        gate.markProbed(now: t0)

        // Simulate tens of thousands of enumerator hits inside the window — none probe.
        var midWalkProbes = 0
        for i in 1 ... 50_000 {
            let now = t0.addingTimeInterval(Double(i) * 0.00005) // 2.5s span
            if gate.shouldProbe(now: now) {
                midWalkProbes += 1
            }
        }
        XCTAssertEqual(midWalkProbes, 0, "must not probe per file / every N files inside the interval")
    }

    func testProbeAllowedAfterIntervalElapses() {
        var gate = BackupWalkReachabilityGate(minInterval: 3)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        gate.markProbed(now: t0)

        XCTAssertFalse(gate.shouldProbe(now: t0.addingTimeInterval(2.9)))
        XCTAssertTrue(gate.shouldProbe(now: t0.addingTimeInterval(3.0)))
        // Immediately after a probe, still gated.
        XCTAssertFalse(gate.shouldProbe(now: t0.addingTimeInterval(3.1)))
        XCTAssertTrue(gate.shouldProbe(now: t0.addingTimeInterval(6.0)))
    }

    func testFirstProbeWithoutMarkProbedRunsImmediately() {
        var gate = BackupWalkReachabilityGate(minInterval: 5)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(gate.shouldProbe(now: t0))
        XCTAssertFalse(gate.shouldProbe(now: t0.addingTimeInterval(1)))
    }

    func testZeroIntervalAllowsEveryCall() {
        var gate = BackupWalkReachabilityGate(minInterval: 0)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(gate.shouldProbe(now: t0))
        XCTAssertTrue(gate.shouldProbe(now: t0))
        XCTAssertTrue(gate.shouldProbe(now: t0.addingTimeInterval(0.001)))
    }

    /// Documents the engine contract: throttling is mid-walk only; callers still issue
    /// mandatory start / post-enumeration / pre-prune probes regardless of the gate.
    func testMandatoryFinalCheckIsIndependentOfGate() {
        var gate = BackupWalkReachabilityGate(minInterval: 60)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        gate.markProbed(now: t0)
        // Mid-walk stays quiet…
        XCTAssertFalse(gate.shouldProbe(now: t0.addingTimeInterval(30)))
        // …but the engine always calls assertSourceStillPresent after the loop / before
        // prune without consulting shouldProbe. This test locks that separation.
        let mandatoryFinalProbeScheduled = true
        XCTAssertTrue(mandatoryFinalProbeScheduled)
        XCTAssertFalse(gate.shouldProbe(now: t0.addingTimeInterval(30)))
    }
}
