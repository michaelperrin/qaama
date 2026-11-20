import Foundation

/// Sends a device its requests one at a time, the ones the grid needs soonest first.
///
/// A card answers one request at a time whatever is asked of it, and a thumbnail costs the reading
/// of the whole file: measured on a 23 MB/s card, 650 ms per photo, the same for 40 thumbnails asked
/// at once as one after the other (`Experiments/card-import`). Left to the device, the thumbnails of
/// a screen scrolled past would all be read before those on screen. Here the quick requests (a file's
/// head, 80 ms) go before the slow ones, the photo being looked at large before the thumbnails of
/// the grid, each kind in the order asked, and a request whose task is
/// cancelled before its turn never reaches the device. The one the device is busy with can't be
/// taken back.
final class CameraRequestQueue {
    enum Lane: CaseIterable {
        /// Short reads, served first: what puts something on screen at once.
        case quick
        /// The whole-file read of the photo being looked at large: one, wanted now.
        case shown
        /// The files of an import: what the user asked for, before what the grid only shows.
        case copy
        /// Whole-file reads for the thumbnails of the grid: a screen of them.
        case slow
    }

    private struct Waiting {
        let ticket: Int
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var waiting: [Lane: [Waiting]] = [:]
    private var isBusy = false
    private var nextTicket = 0

    /// Runs `request` when its turn comes and returns its answer; nil when the task was cancelled
    /// while it waited.
    func run<Value: Sendable>(_ lane: Lane, _ request: () async -> Value?) async -> Value? {
        guard await waitForTurn(in: lane) else { return nil }
        defer { finishTurn() }
        guard !Task.isCancelled else { return nil }
        return await request()
    }

    /// How many requests wait for their turn, for tests.
    var waitingCount: Int {
        waiting.values.reduce(0) { $0 + $1.count }
    }

    /// False when the task is cancelled before the turn comes: the turn was then never taken.
    private func waitForTurn(in lane: Lane) async -> Bool {
        guard isBusy else {
            isBusy = true
            return true
        }
        let ticket = nextTicket
        nextTicket += 1
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Cancelled before getting here: the handler below found nothing to drop.
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiting[lane, default: []].append(Waiting(ticket: ticket, continuation: continuation))
                }
            }
        } onCancel: {
            Task { @MainActor in self.drop(ticket) }
        }
    }

    private func drop(_ ticket: Int) {
        for lane in Lane.allCases {
            if let index = waiting[lane]?.firstIndex(where: { $0.ticket == ticket }), let dropped = waiting[lane]?.remove(at: index) {
                dropped.continuation.resume(returning: false)
            }
        }
    }

    /// Hands the device to the next request: the oldest of the first lane that has one waiting.
    private func finishTurn() {
        for lane in Lane.allCases {
            if waiting[lane]?.isEmpty == false, let next = waiting[lane]?.removeFirst() {
                next.continuation.resume(returning: true)
                return
            }
        }
        isBusy = false
    }
}
