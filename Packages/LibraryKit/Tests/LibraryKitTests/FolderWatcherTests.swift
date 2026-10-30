import Foundation
@testable import LibraryKit
import Testing

struct FolderWatcherTests {
    @Test func reportsOnceAfterChangesSettle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FolderWatcherTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let counter = Counter()
        let watcher = try #require(FolderWatcher(url: root) { counter.increment() })
        defer { watcher.stop() }
        // FSEvents needs a moment to arm.
        try await Task.sleep(for: .milliseconds(300))

        // The watcher ignores this process's own writes (so Qaama's sidecar writes don't trigger rescans):
        // write from a child process, like the Finder or a camera import would.
        let shell = Process()
        shell.executableURL = URL(filePath: "/bin/sh")
        shell.arguments = ["-c", "for i in 0 1 2; do echo x > \"\(root.path)/file-$i.txt\"; done"]
        try shell.run()
        shell.waitUntilExit()
        for _ in 0 ..< 100 where counter.value == 0 {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(counter.value == 1, "three quick writes settle into one report, got \(counter.value)")
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}
