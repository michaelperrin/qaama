import Foundation
import os
import OSLog
import Photos

/// Deleting and duplicating photos of the Apple Photos library, through PhotoKit change requests.
/// Photos are named by identifier. Every call may take a while: none runs on the main actor.
nonisolated enum PhotoKitAssetChanges {
    private static let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "PhotoKitAssetChanges")

    /// Asks Photos to delete photos: they go to its Recently Deleted album, for thirty days. The
    /// system asks the user first, with an alert of its own that an app can neither skip nor word.
    /// False when the user declined.
    static func delete(_ ids: [String]) async throws -> Bool {
        let assets = assets(ids)
        guard !assets.isEmpty else { throw LibrarySourceError.assetUnavailable }
        do {
            try await PHPhotoLibrary.shared().performChanges { @Sendable in
                PHAssetChangeRequest.deleteAssets(assets as NSArray)
            }
        } catch let error as PHPhotosError where error.code == .userCancelled {
            logger.notice("Deleting \(assets.count) photos was declined")
            return false
        } catch {
            logger.error("Deleting \(assets.count) photos failed: \(error.localizedDescription, privacy: .public)")
            throw LibrarySourceError.deletionFailed(error.localizedDescription)
        }
        logger.notice("Deleted \(assets.count) photos")
        return true
    }

    /// Makes a new photo from the files of another, with its date, place, favorite, rating and
    /// keywords, and returns its identifier. `albumID` is an album to add the copy to: the one the
    /// original is being looked at in. Files that are in iCloud are downloaded first.
    static func duplicate(_ id: String, intoAlbum albumID: String?) async throws -> String {
        guard let asset = assets([id]).first else { throw LibrarySourceError.assetUnavailable }
        let clock = ContinuousClock()
        let start = clock.now
        let resources = resourcesToCopy(of: asset)
        guard !resources.isEmpty else { throw LibrarySourceError.duplicationFailed("the photo has no original") }

        // Photos reads the files of a new photo from disk: the resources go through a folder of the
        // app's, which Photos empties as it takes them (`shouldMoveFile`).
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Duplicate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var files: [(type: PHAssetResourceType, name: String, url: URL)] = []
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            for (number, resource) in resources.enumerated() {
                let name = resource.filename ?? "resource-\(number)"
                let url = directory.appendingPathComponent("\(number)-\(name)")
                try await PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options)
                files.append((resource.type, name, url))
            }
        } catch {
            logger.error("Reading the files of \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            throw LibrarySourceError.duplicationFailed(error.localizedDescription)
        }
        let read = clock.now
        let copied = files

        let keywords = asset.extendedMetadata.keywords
        // A change request for an album that refuses additions is nil, and would do nothing in silence.
        let album = albumID.flatMap { PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [$0], options: nil).firstObject }
            .flatMap { $0.canPerform(.addContent) ? $0 : nil }
        // The identifier is only known inside the change block, which PhotoKit runs on its own queue.
        let created = OSAllocatedUnfairLock<String?>(initialState: nil)
        do {
            try await PHPhotoLibrary.shared().performChanges { @Sendable in
                let request = PHAssetCreationRequest.forAsset()
                for file in copied {
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = file.name
                    options.shouldMoveFile = true
                    request.addResource(with: file.type, fileURL: file.url, options: options)
                }
                request.creationDate = asset.creationDate
                request.location = asset.location
                request.isFavorite = asset.isFavorite
                request.rating = asset.rating
                keywords.forEach { request.addKeyword($0) }
                guard let placeholder = request.placeholderForCreatedAsset else { return }
                if let album {
                    PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
                }
                created.withLock { $0 = placeholder.localIdentifier }
            }
        } catch {
            logger.error("Duplicating \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            throw LibrarySourceError.duplicationFailed(error.localizedDescription)
        }
        guard let copy = created.withLock({ $0 }) else { throw LibrarySourceError.duplicationFailed("no photo was created") }
        let format = Duration.UnitsFormatStyle.units(allowed: [.milliseconds])
        logger.notice("Duplicated \(id, privacy: .public) as \(copy, privacy: .public) from \(copied.map(\.type.rawValue), privacy: .public): files read in \((read - start).formatted(format), privacy: .public), photo created in \((clock.now - read).formatted(format), privacy: .public)")
        return copy
    }

    /// Makes a photo from files copied from a card or a camera, and returns its identifier. A RAW
    /// that comes with its JPEG becomes one photo, the JPEG being the one shown and the RAW its
    /// alternate, as a camera's pair is in Photos. Photos reads the date and the place from the
    /// files, and takes the files away (`shouldMoveFile`). `albumID` is an album to add the photo to.
    static func create(from photo: ImportedPhoto, intoAlbum albumID: String?) async throws -> String {
        let jpeg = photo.files.first { !$0.isRAW }
        let resources: [(type: PHAssetResourceType, file: ImportedPhoto.File)] = photo.files.map { file in
            (file.isRAW && jpeg != nil ? .alternatePhoto : .photo, file)
        }
        guard !resources.isEmpty else { throw LibrarySourceError.assetUnavailable }
        // A change request for an album that refuses additions is nil, and would do nothing in silence.
        let album = albumID.flatMap { PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [$0], options: nil).firstObject }
            .flatMap { $0.canPerform(.addContent) ? $0 : nil }
        // The identifier is only known inside the change block, which PhotoKit runs on its own queue.
        let created = OSAllocatedUnfairLock<String?>(initialState: nil)
        do {
            try await PHPhotoLibrary.shared().performChanges { @Sendable in
                let request = PHAssetCreationRequest.forAsset()
                for resource in resources {
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = resource.file.name
                    options.shouldMoveFile = true
                    request.addResource(with: resource.type, fileURL: resource.file.url, options: options)
                }
                guard let placeholder = request.placeholderForCreatedAsset else { return }
                if let album {
                    PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
                }
                created.withLock { $0 = placeholder.localIdentifier }
            }
        } catch {
            let names = photo.files.map(\.name).joined(separator: ", ")
            logger.error("Importing \(names, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            throw LibrarySourceError.editingFailed("Photos refused “\(names)”: \(error.localizedDescription)")
        }
        guard let id = created.withLock({ $0 }) else { throw LibrarySourceError.editingFailed("no photo was created") }
        return id
    }

    /// The files a copy is made from: the original and the other half of a RAW + JPEG pair and, for
    /// an edited photo, its current version and the adjustment data behind it, so the copy carries
    /// the same edit, which Photos can revert and Qaama reopen as it does the original's. Should
    /// Photos refuse to create a photo from that set, the originals alone are copied: the copy then
    /// comes without the edit.
    private static func resourcesToCopy(of asset: PHAsset) -> [PHAssetResource] {
        let resources = PHAssetResource.assetResources(for: asset)
        let originals = resources.filter { $0.type == .photo || $0.type == .alternatePhoto }
        let edit = resources.filter { $0.type == .fullSizePhoto || $0.type == .adjustmentData || $0.type == .adjustmentBasePhoto }
        let isEdited = edit.contains { $0.type == .fullSizePhoto } && edit.contains { $0.type == .adjustmentData }
        guard isEdited else { return originals }
        let types = (originals + edit).map { NSNumber(value: $0.type.rawValue) }
        guard PHAssetCreationRequest.supportsAssetResourceTypes(types) else {
            logger.notice("Photos can't create a photo from \(types, privacy: .public): the copy of \(asset.localIdentifier, privacy: .public) comes without its edit")
            return originals
        }
        return originals + edit
    }

    /// The assets behind identifiers, in the order given; a fetch by identifier promises no order.
    private static func assets(_ ids: [String]) -> [PHAsset] {
        guard !ids.isEmpty else { return [] }
        var byID: [String: PHAsset] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in
            byID[asset.localIdentifier] = asset
        }
        return ids.compactMap { byID.removeValue(forKey: $0) }
    }
}
