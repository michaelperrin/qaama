import Photos

/// Access state for the Apple Photos library, expressed without exposing PhotoKit to callers.
nonisolated public enum PhotoLibraryAccess: Sendable {
    case notDetermined
    case authorized
    case limited
    case denied

    /// Current state, without prompting the user.
    public static var current: PhotoLibraryAccess {
        PhotoLibraryAccess(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    /// Requests read/write access if the user has not decided yet.
    public static func request() async -> PhotoLibraryAccess {
        PhotoLibraryAccess(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    init(_ status: PHAuthorizationStatus) {
        switch status {
        case .authorized: self = .authorized
        case .limited: self = .limited
        case .denied, .restricted: self = .denied
        case .notDetermined: self = .notDetermined
        @unknown default: self = .denied
        }
    }
}
