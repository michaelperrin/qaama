import Foundation
@testable import LibraryKit
import Testing

@MainActor
struct CameraRequestQueueTests {
    /// Holds a request until the test lets it go, as a device busy reading a file.
    @MainActor
    private final class Gate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }

    /// What reached the device, in order.
    @MainActor
    private final class Log {
        var served: [String] = []
    }

    @Test func oneRequestAtATimeQuickOnesFirstEachKindInTheOrderAsked() async {
        let queue = CameraRequestQueue()
        let gate = Gate()
        let log = Log()
        // The device is busy with a first request.
        let first = Task { await queue.run(.slow) { log.served.append("first"); await gate.wait(); return "first" } }
        await waitUntil { log.served == ["first"] }

        var tasks: [Task<String?, Never>] = []
        for (name, lane) in [("slow A", CameraRequestQueue.Lane.slow), ("slow B", .slow), ("shown E", .shown), ("quick C", .quick), ("quick D", .quick)] {
            tasks.append(Task { await queue.run(lane) { log.served.append(name); return name } })
            await waitUntil { queue.waitingCount == tasks.count }
        }
        // Nothing else reaches the device while it is busy.
        #expect(log.served == ["first"])

        gate.open()
        #expect(await first.value == "first")
        var answers: [String?] = []
        for task in tasks {
            await answers.append(task.value)
        }
        #expect(answers == ["slow A", "slow B", "shown E", "quick C", "quick D"])
        // The photo looked at large goes before the thumbnails of the grid asked earlier.
        #expect(log.served == ["first", "quick C", "quick D", "shown E", "slow A", "slow B"])
        #expect(queue.waitingCount == 0)
    }

    @Test func aRequestCancelledWhileWaitingNeverReachesTheDevice() async {
        let queue = CameraRequestQueue()
        let gate = Gate()
        let log = Log()
        let first = Task { await queue.run(.slow) { log.served.append("first"); await gate.wait(); return "first" } }
        await waitUntil { log.served == ["first"] }
        // A thumbnail scrolled off the screen before its turn, and one still wanted.
        let scrolledAway = Task { await queue.run(.slow) { log.served.append("scrolled away"); return "scrolled away" } }
        await waitUntil { queue.waitingCount == 1 }
        let wanted = Task { await queue.run(.slow) { log.served.append("wanted"); return "wanted" } }
        await waitUntil { queue.waitingCount == 2 }

        scrolledAway.cancel()
        #expect(await scrolledAway.value == nil)
        #expect(queue.waitingCount == 1)

        gate.open()
        _ = await first.value
        #expect(await wanted.value == "wanted")
        #expect(log.served == ["first", "wanted"])
    }

    @Test func theQueueIsFreeAgainOnceEveryRequestIsServed() async {
        let queue = CameraRequestQueue()
        #expect(await queue.run(.quick) { 1 } == 1)
        #expect(await queue.run(.slow) { 2 } == 2)
        // A request that answers nothing still gives its turn back.
        #expect(await queue.run(.slow) { nil as Int? } == nil)
        #expect(await queue.run(.quick) { 3 } == 3)
    }
}
