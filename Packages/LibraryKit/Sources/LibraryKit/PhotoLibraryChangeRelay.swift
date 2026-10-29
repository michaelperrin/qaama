import Photos

/// Bridges PhotoKit's change notifications (delivered on an arbitrary queue) to the main actor.
final nonisolated class PhotoLibraryChangeRelay: NSObject, PHPhotoLibraryChangeObserver {
    private let handler: @MainActor (PHChange) -> Void

    init(handler: @escaping @MainActor (PHChange) -> Void) {
        self.handler = handler
        super.init()
        PHPhotoLibrary.shared().register(self)
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        let handler = self.handler
        Task { @MainActor in handler(changeInstance) }
    }
}
