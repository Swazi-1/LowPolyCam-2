import Foundation
import Dispatch

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

private final class ConcurrentDrain {
    let mailbox = LatestValueMailbox<Int>()
    let completed = DispatchSemaphore(value: 0)
    private let queue = DispatchQueue(label: "zoomRegression.consumer")

    func submit(_ value: Int) {
        if mailbox.submit(value) { schedule() }
    }

    private func schedule() {
        queue.async {
            if let value = self.mailbox.take(), value == Int.max {
                self.completed.signal()
            }
            if self.mailbox.finish() { self.schedule() }
        }
    }
}

@main
private enum ZoomRegressionTests {
    static func main() {
        opticalRouting()
        latestPendingValue()
        producerDuringConsumption()
        pendingReconciliation()
        concurrentProducers()
        previewTransitionOwnership()
        levelMeterMath()
        levelMeterLifecyclePolicy()
        print("Zoom regression tests passed")
    }

    private static func opticalRouting() {
        let bases: [CGFloat] = [1, 0.5]
        expect(ZoomRoutingPolicy.opticalBase(for: 0.5, availableBases: bases) == 0.5,
               "0.5x must use an available Ultra Wide lens")
        expect(ZoomRoutingPolicy.opticalBase(for: 1, availableBases: bases,
                                            currentBase: 0.5, interactive: true) == 1,
               "A held drag crossing 1x must switch to Wide before finger release")
        expect(ZoomRoutingPolicy.opticalBase(for: 1.8, availableBases: bases,
                                            currentBase: 0.5, interactive: true) == 1,
               "A large held drag must not leave Ultra Wide selected above 1x")
        expect(ZoomRoutingPolicy.opticalBase(for: 0.98, availableBases: bases,
                                            currentBase: 1, interactive: true) == 1,
               "Boundary jitter must not immediately swap back to Ultra Wide")
        expect(ZoomRoutingPolicy.opticalBase(for: 0.95, availableBases: bases,
                                            currentBase: 1, interactive: true) == 0.5,
               "A deliberate reverse drag must leave the Wide hysteresis band")
        expect(ZoomRoutingPolicy.opticalBase(for: 0.7, availableBases: [1],
                                            currentBase: 1, interactive: true) == 1,
               "Unsupported Ultra Wide must never be invented for a selected format")
        expect(ZoomRoutingPolicy.opticalBase(for: 3, availableBases: [0.5, 3, 1]) == 3,
               "Select the longest legal optical lens from unordered capabilities")
        expect(ZoomRoutingPolicy.opticalBase(for: 1, availableBases: []) == nil,
               "No capability must yield no route")
        expect(ZoomRoutingPolicy.opticalBase(for: .nan, availableBases: bases) == nil,
               "An invalid gesture value must not choose a lens")
        expect(ZoomRoutingPolicy.opticalBase(for: 1, availableBases: [.nan, -1, 0, 1]) == 1,
               "Invalid optical bases must not corrupt capability selection")

        expect(ZoomRoutingPolicy.clamp(0.5, to: 1...8) == 1,
               "A Wide-only recording range must clamp a request for another physical input")
        expect(ZoomRoutingPolicy.clamp(2, to: 0.5...4) == 2,
               "Ultra Wide digital zoom above 1x must remain possible while recording")
        expect(ZoomRoutingPolicy.clamp(.nan, to: 1...8) == 1,
               "An invalid zoom must resolve to a safe active minimum")
        expect(ZoomRoutingPolicy.settledZoom(0.98, in: 0.5...8) == 1,
               "Gesture settlement must snap near 1x before final optical routing")
        let settled = ZoomRoutingPolicy.settledZoom(0.98, in: 0.5...8)
        expect(ZoomRoutingPolicy.opticalBase(for: settled, availableBases: bases) == 1,
               "A settled 1x request must use Wide rather than a digital Ultra Wide crop")
        expect(ZoomRoutingPolicy.settledZoom(0.55, in: 0.5...8) == 0.5,
               "Settling near the available Ultra Wide base must return exactly 0.5x")
        expect(ZoomRoutingPolicy.settledZoom(2.4, in: 1...8) == 2.4,
               "Settlement must preserve arbitrary zoom away from optical detents")
    }

    private static func latestPendingValue() {
        let mailbox = LatestValueMailbox<Int>()
        expect(mailbox.submit(1), "The first pending value must schedule a consumer")
        expect(!mailbox.submit(2), "Overwriting a pending value must not schedule a second consumer")
        expect(mailbox.take() == 2, "A busy queue must consume the latest value, not the stale first one")
        expect(!mailbox.finish(), "An empty mailbox must release consumer ownership")
        expect(mailbox.submit(3), "A producer arriving after idle must wake a fresh consumer")
        expect(mailbox.take() == 3, "The next drain must receive the wakeup value")
        expect(!mailbox.finish(), "The fresh consumer must return to idle after draining")
    }

    private static func producerDuringConsumption() {
        let mailbox = LatestValueMailbox<Int>()
        expect(mailbox.submit(10), "Begin one drain")
        expect(mailbox.take() == 10, "Begin processing the first value")

        // This producer runs after take() but before finish(), precisely the handoff window
        // that used to lose an interactive update when the consumer dropped its busy flag.
        let producerFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            expect(!mailbox.submit(20), "The existing consumer owns updates submitted during processing")
            expect(!mailbox.submit(30), "Only the newest in-flight update needs another queue turn")
            producerFinished.signal()
        }
        expect(producerFinished.wait(timeout: .now() + 5) == .success, "Producer failed to complete")
        expect(mailbox.finish(), "A producer during processing must request another drain turn")
        expect(mailbox.take() == 30, "The follow-up turn must consume the newest in-flight update")
        expect(!mailbox.finish(), "The consumer must become idle when no work remains")
        expect(mailbox.submit(40), "A producer after ownership release must schedule the next drain")
        expect(mailbox.take() == 40, "No wakeup may be lost at the idle handoff")
        expect(!mailbox.finish(), "Drain the final value")
    }

    private static func pendingReconciliation() {
        struct TaggedZoom {
            let generation: Int
            let value: Int
        }

        let mailbox = LatestValueMailbox<TaggedZoom>()
        expect(mailbox.submit(TaggedZoom(generation: 1, value: 100)), "Boundary zoom must acquire the consumer")
        expect(mailbox.take()?.value == 100, "The consumer must begin at the optical boundary")
        expect(!mailbox.submit(TaggedZoom(generation: 1, value: 115)), "Held drag stays under one consumer")
        expect(!mailbox.submit(TaggedZoom(generation: 1, value: 127)), "Intermediate held values coalesce")
        expect(!mailbox.submit(TaggedZoom(generation: 1, value: 134)), "The latest held value replaces the old one")
        expect(mailbox.take(where: { $0.generation == 1 })?.value == 134,
               "A physical handoff must reconcile the newest same-gesture zoom before preview reveal")
        expect(!mailbox.finish(), "Consuming the pre-reveal value must release ownership when no work remains")
        expect(mailbox.isIdle, "The mailbox must report idle after a complete pre-reveal reconciliation")

        expect(mailbox.submit(TaggedZoom(generation: 2, value: 70)), "A reverse drag must start a fresh consumer")
        expect(mailbox.take(where: { $0.generation == 1 }) == nil,
               "An old handoff must never steal a newer zoom generation")
        expect(mailbox.take(where: { $0.generation == 2 })?.value == 70,
               "The newer reverse request must remain available for its own handoff")
        expect(!mailbox.finish(), "The reverse request must release ownership exactly once")
    }

    private static func concurrentProducers() {
        // Exercise real concurrent submit/take/finish interleavings. Intermediate values may
        // coalesce, but the last request must always reach the single serial consumer.
        for _ in 0..<20 {
            let drain = ConcurrentDrain()
            let producers = DispatchGroup()
            for producer in 0..<4 {
                producers.enter()
                DispatchQueue.global().async {
                    for update in 0..<500 { drain.submit(producer * 500 + update) }
                    producers.leave()
                }
            }
            expect(producers.wait(timeout: .now() + 10) == .success, "Concurrent producers stalled")
            drain.submit(Int.max)
            expect(drain.completed.wait(timeout: .now() + 5) == .success,
                   "The last zoom request was lost during a producer/consumer handoff")
        }
    }
    private static func previewTransitionOwnership() {
        var transitions = PreviewTransitionStateMachine()
        let a = PreviewTransitionRequest(id: 1, reason: .lens, targetDeviceID: "wide", blocksControls: false)
        let b = PreviewTransitionRequest(id: 2, reason: .lens, targetDeviceID: "ultra", blocksControls: false)

        expect(a.usesScenePreservingOpticalBlend, "Physical lens handoffs must use the scene-preserving optical blend")
        expect(PreviewTransitionRequest(id: 10, reason: .whiteBalanceInput, targetDeviceID: nil, blocksControls: false).usesScenePreservingOpticalBlend,
               "WB input swaps must use the same scene-preserving physical handoff")
        expect(!PreviewTransitionRequest(id: 11, reason: .cameraFlip, targetDeviceID: nil, blocksControls: true).usesScenePreservingOpticalBlend,
               "Front/back flipping keeps its separate transition policy")
        expect(!PreviewTransitionRequest(id: 12, reason: .configuration, targetDeviceID: nil, blocksControls: true).usesScenePreservingOpticalBlend,
               "Ordinary configuration covers must not pretend to be an optical handoff")

        expect(transitions.begin(a) == nil, "The first transition must acquire visual ownership")
        expect(transitions.acknowledgeCovered(id: 1), "The current transition may acknowledge its cover")
        expect(transitions.begin(b) == a, "A reverse request must replace the old transition without clearing ownership")
        expect(!transitions.acknowledgeCovered(id: 1), "An invalidated cover acknowledgement must not apply old hardware")
        expect(!transitions.hardwareCommitted(id: 1, deviceID: "wide"), "Old transition A cannot commit after B owns the cover")
        expect(transitions.acknowledgeCovered(id: 2), "The replacement transition owns the cover")
        expect(transitions.hardwareCommitted(id: 2, deviceID: "ultra"), "The current target can commit")
        expect(!transitions.previewResumed(id: 1, deviceID: "wide"), "Old transition A cannot dismiss newer transition B")
        expect(!transitions.previewResumed(id: 2, deviceID: "wide"), "Readiness from the wrong physical device cannot dismiss the cover")
        expect(transitions.previewResumed(id: 2, deviceID: "ultra"), "The committed target can dismiss its own cover")
        expect(transitions.activeRequest == nil, "Successful readiness must release visual ownership")

        let unbound = PreviewTransitionRequest(id: 3, reason: .cameraFlip, targetDeviceID: nil, blocksControls: true)
        _ = transitions.begin(unbound)
        expect(transitions.acknowledgeCovered(id: 3), "A camera flip can acknowledge before the exact selected input is known")
        expect(transitions.hardwareCommitted(id: 3, deviceID: "front-wide"), "Commit binds an initially unknown target identity")
        expect(transitions.activeRequest?.targetDeviceID == "front-wide", "The committed device identity must be retained")
        expect(transitions.cancel(id: 3), "Cancellation releases ownership once")
        expect(!transitions.cancel(id: 3), "Cancellation must not release the same ownership twice")
    }

    private static func levelMeterMath() {
        func gravity(_ degrees: Double) -> (Double, Double) {
            let radians = degrees * Double.pi / 180
            return (sin(radians), -cos(radians))
        }
        func angle(_ degrees: Double) -> Double {
            let vector = gravity(degrees)
            return CameraLevelMath.indicatorAngle(gravityX: vector.0, gravityY: vector.1) ?? .nan
        }

        for cardinal in [0.0, 90.0, 180.0, 270.0] {
            expect(abs(angle(cardinal)) < 0.000_001,
                   "The level indicator must be horizontal at every cardinal device orientation")
        }
        let fortyFour = angle(44)
        let fortyFive = angle(45)
        let fortySix = angle(46)
        expect(abs(fortyFive - fortyFour) < 2 * Double.pi / 180,
               "Approaching 45 degrees must stay continuous")
        expect(abs(fortySix - fortyFive) < 2 * Double.pi / 180,
               "Passing 45 degrees must not snap to the opposite side")
        expect(abs(angle(30) - 30 * Double.pi / 180) < 0.000_001,
               "Portrait-side tilt must track the visible deviation")
        expect(abs(angle(60) - 30 * Double.pi / 180) < 0.000_001,
               "Landscape-side tilt must fold smoothly toward level")
        expect(CameraLevelMath.indicatorAngle(gravityX: 0, gravityY: 0) == nil,
               "Face-up/down roll with no horizontal gravity must be treated as unavailable")
    }

    private static func levelMeterLifecyclePolicy() {
        expect(CameraLevelLifecyclePolicy.shouldRetryStartup(
            wantsMonitoring: true, receivedValidSample: false, retryCount: 0),
               "A persisted ON level must retry when launch has not produced a valid sample")
        expect(!CameraLevelLifecyclePolicy.shouldRetryStartup(
            wantsMonitoring: true, receivedValidSample: true, retryCount: 0),
               "One valid gravity sample must stop launch retries")
        expect(!CameraLevelLifecyclePolicy.shouldRetryStartup(
            wantsMonitoring: false, receivedValidSample: false, retryCount: 0),
               "Turning Level OFF must suppress every retry")
        expect(!CameraLevelLifecyclePolicy.shouldRetryStartup(
            wantsMonitoring: true, receivedValidSample: false,
            retryCount: CameraLevelLifecyclePolicy.maximumStartupRetries),
               "Launch recovery must remain bounded")
        expect(!CameraLevelLifecyclePolicy.streamIsStale(now: 10, lastDelivery: 9.5),
               "A recent Core Motion delivery is healthy")
        expect(CameraLevelLifecyclePolicy.streamIsStale(now: 10, lastDelivery: 8),
               "An active-but-silent Core Motion stream must be recoverable")
        expect(CameraLevelLifecyclePolicy.streamIsStale(now: 10, lastDelivery: nil),
               "A stream that never delivered must be treated as stale")
    }

}
