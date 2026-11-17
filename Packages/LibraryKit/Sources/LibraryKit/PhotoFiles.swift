import Foundation

/// Where deleted files go: the system's Trash in the app, a folder in tests, which must leave the
/// user's Trash alone.
public nonisolated struct FileTrash: Sendable {
    /// Moves a file there and returns where it now is; nil when the system doesn't tell, and the
    /// file can't be put back.
    public var move: @Sendable (URL) throws -> URL?

    public init(move: @escaping @Sendable (URL) throws -> URL?) {
        self.move = move
    }

    /// The Trash of the volume the file is on. A sandboxed app can move a file there and back out of
    /// it for as long as it runs (checked with a sandboxed probe, see docs/PLAN.md).
    public static let system = FileTrash { url in
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }

    /// A folder standing in for the Trash. As the Trash does, it renames a file whose name is taken.
    public static func folder(_ directory: URL) -> FileTrash {
        FileTrash { url in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var destination = directory.appendingPathComponent(url.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
                destination = directory.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
            }
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
    }
}

/// A file moved to the trash: where it was, and where it is now.
nonisolated struct TrashedFile: Hashable, Sendable {
    var original: URL
    var trashed: URL
}

/// The files of the photos of a folder, handled as photos are: an image goes with its sidecar, and
/// a copy of a photo is a new photo with the same decisions. Every call blocks: run them off the
/// main actor.
nonisolated enum PhotoFiles {
    /// What a change to several files did: the images it went through for, the files it moved and the
    /// first failure. One file failing doesn't stop the others.
    struct Outcome: Sendable {
        /// The images moved or made, sidecars left out: one per photo.
        var images: [URL] = []
        /// Every file moved to the trash, sidecars included: what putting them back takes.
        var trashed: [TrashedFile] = []
        var firstError: (any Error)?
    }

    /// Moves images to the trash, each with its sidecar.
    static func trash(imagesAt urls: [URL], into trash: FileTrash) -> Outcome {
        var outcome = Outcome()
        for url in urls {
            do {
                let sidecar = Sidecar.url(for: url)
                let hasSidecar = FileManager.default.fileExists(atPath: sidecar.path(percentEncoded: false))
                if let trashed = try trash.move(url) {
                    outcome.trashed.append(TrashedFile(original: url, trashed: trashed))
                }
                outcome.images.append(url)
                // A sidecar left behind would only be an orphan; one that stays is no reason to fail.
                if hasSidecar, let trashed = try? trash.move(sidecar) {
                    outcome.trashed.append(TrashedFile(original: sidecar, trashed: trashed))
                }
            } catch {
                outcome.firstError = outcome.firstError ?? error
            }
        }
        return outcome
    }

    /// Moves files back from the trash to where they were. A file whose place was taken meanwhile
    /// stays in the trash.
    static func restore(_ files: [TrashedFile]) -> Outcome {
        var outcome = Outcome()
        for file in files {
            do {
                try FileManager.default.createDirectory(at: file.original.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: file.trashed, to: file.original)
                if !isSidecar(file.original) {
                    outcome.images.append(file.original)
                }
            } catch {
                outcome.firstError = outcome.firstError ?? error
            }
        }
        return outcome
    }

    /// Copies each photo next to itself. A photo is one image, or the images of a RAW + JPEG pair
    /// shown as one photo: they are copied under the same new name, so the copies pair up too.
    static func duplicate(_ photos: [[URL]]) -> Outcome {
        var outcome = Outcome()
        for images in photos {
            do {
                try outcome.images.append(contentsOf: duplicate(images))
            } catch {
                outcome.firstError = outcome.firstError ?? error
            }
        }
        return outcome
    }

    /// Copies the images of one photo, each with its sidecar, under the name the Finder gives a copy:
    /// "IMG_1 copy.jpg", then "IMG_1 copy 2.jpg". The copy's sidecar gets an identifier of its own: with
    /// the original's, the catalog would take one of the two files for the other.
    static func duplicate(_ images: [URL]) throws -> [URL] {
        guard let first = images.first else { return [] }
        let stem = copyStem(for: images)
        var made: [URL] = []
        do {
            for image in images {
                let copy = first.deletingLastPathComponent().appendingPathComponent(stem).appendingPathExtension(image.pathExtension)
                try FileManager.default.copyItem(at: image, to: copy)
                made.append(copy)
                if var sidecar = try Sidecar.read(forImageAt: image) {
                    sidecar.id = UUID()
                    try sidecar.write(forImageAt: copy)
                }
            }
        } catch {
            // Half a copy is no copy.
            for copy in made {
                try? FileManager.default.removeItem(at: copy)
                try? FileManager.default.removeItem(at: Sidecar.url(for: copy))
            }
            throw error
        }
        return made
    }

    /// The first name of a copy that is free for every image of the photo.
    private static func copyStem(for images: [URL]) -> String {
        let directory = images[0].deletingLastPathComponent()
        let base = images[0].deletingPathExtension().lastPathComponent
        var number = 1
        while true {
            let stem = number == 1 ? "\(base) copy" : "\(base) copy \(number)"
            let isTaken = images.contains { image in
                let copy = directory.appendingPathComponent(stem).appendingPathExtension(image.pathExtension)
                return [copy, Sidecar.url(for: copy)].contains { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
            }
            if !isTaken {
                return stem
            }
            number += 1
        }
    }

    static func isSidecar(_ url: URL) -> Bool {
        url.pathExtension == EditingFormat.sidecarExtension
    }
}
