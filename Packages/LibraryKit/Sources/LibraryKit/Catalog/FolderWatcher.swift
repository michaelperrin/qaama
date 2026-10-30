import CoreServices
import Foundation
import OSLog

/// Watches a folder tree with FSEvents and calls back once changes settle. Any change (file added,
/// removed, renamed, sidecar written) counts: the indexer is fast enough to rescan the whole folder.
final nonisolated class FolderWatcher: @unchecked Sendable {
    /// How long to wait after the last event before reporting, so a copy of many files reports once.
    static let settleDelay: TimeInterval = 1.5

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "fr.michaelperrin.qaama.folder-watcher")
    private let handler: @Sendable () -> Void
    private var pending: DispatchWorkItem?
    private let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "FolderWatcher")

    /// Starts watching immediately. The handler runs on a background queue.
    init?(url: URL, handler: @escaping @Sendable () -> Void) {
        self.handler = handler
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().changed()
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagIgnoreSelf)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [url.path(percentEncoded: false)] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags)
        else {
            return nil
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            return nil
        }
        logger.notice("Watching \(url.lastPathComponent, privacy: .public)")
    }

    deinit {
        stop()
    }

    func stop() {
        queue.sync {
            pending?.cancel()
            pending = nil
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    /// Called on `queue` for every batch of events; reports once the folder has been quiet for a while.
    private func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [handler] in handler() }
        pending = work
        queue.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }
}
