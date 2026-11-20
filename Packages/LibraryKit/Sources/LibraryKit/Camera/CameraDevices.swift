import Foundation
import Observation
import OSLog

/// The cards and cameras plugged in right now, each as a source the grid can browse. The sidebar
/// lists them; a device that is pulled out leaves the list.
@Observable
public final class CameraDevices {
    public private(set) var sources: [CameraLibrarySource] = []

    private let browser: (any CameraBrowser)?
    /// What was imported so far; nil where nothing is remembered (tests of the rest).
    public let history: ImportHistory?
    private var isStarted = false
    private let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "CameraDevices")

    /// Without a browser nothing is ever listed: what tests and previews of the rest of the app get.
    public init(browser: (any CameraBrowser)? = nil, history: ImportHistory? = nil) {
        self.browser = browser
        self.history = history
        history?.onChange = { [weak self] in self?.sources.forEach { $0.refreshImported() } }
    }

    /// Starts watching for devices. Calling it again does nothing.
    public func start() {
        guard !isStarted, let browser else { return }
        isStarted = true
        browser.onConnect = { [weak self] connection in self?.connect(connection) }
        browser.onDisconnect = { [weak self] id in self?.disconnect(id) }
        browser.start()
    }

    public func source(id: CameraLibrarySource.ID) -> CameraLibrarySource? {
        sources.first { $0.id == id }
    }

    private func connect(_ connection: any CameraConnection) {
        guard source(id: connection.id) == nil else { return }
        logger.notice("Device connected: \(connection.name, privacy: .public)")
        sources.append(CameraLibrarySource(connection: connection, history: history))
    }

    private func disconnect(_ id: String) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        let source = sources.remove(at: index)
        logger.notice("Device disconnected: \(source.displayName, privacy: .public)")
        source.disconnect()
    }
}
