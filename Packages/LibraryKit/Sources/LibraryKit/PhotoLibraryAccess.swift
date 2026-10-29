import Photos

/// État d'accès à la photothèque Apple, exprimé sans exposer PhotoKit aux appelants.
nonisolated public enum PhotoLibraryAccess: Sendable {
    case notDetermined
    case authorized
    case limited
    case denied

    /// État courant, sans déclencher de demande.
    public static var current: PhotoLibraryAccess {
        PhotoLibraryAccess(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    /// Demande l'accès en lecture/écriture si l'utilisateur ne s'est pas encore prononcé.
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
