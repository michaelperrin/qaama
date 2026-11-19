// Feasibility probe for importing photos from an SD card with ImageCaptureCore, run inside the
// App Sandbox. See README.md for what it answers and how to build it. Not part of the app.

import Foundation
import ImageCaptureCore
import ImageIO

// MARK: - Output

func say(_ text: String) {
    print(text)
    fflush(stdout)
}

func milliseconds(_ duration: Duration) -> String {
    let value = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    return String(format: "%.0f ms", value)
}

func megabytes(_ bytes: Int64) -> String {
    String(format: "%.1f MB", Double(bytes) / 1_000_000)
}

/// Pixel size of encoded image data, read from its header.
func pixelSize(of data: Data) -> String {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int
    else { return "not an image" }
    return "\(width) × \(height)"
}

// MARK: - Arguments

/// What to do besides the read-only tests. Deleting only ever touches the one file named here.
struct Options {
    var deleteName: String?
    /// A mounted volume to read with ImageIO as well, for comparison (unsandboxed builds only).
    var directVolume: String?
    /// Only this device is opened; any other plugged in (a phone) is left alone.
    var deviceName: String?
    /// Asks the device to announce its files newest first.
    var chronological = false
    /// Stops once the catalog is complete: only the listing is measured.
    var listingOnly = false
    var thumbnailCount = 48

    init(arguments: [String]) {
        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--delete": deleteName = iterator.next()
            case "--direct": directVolume = iterator.next()
            case "--device": deviceName = iterator.next()
            case "--chronological": chronological = true
            case "--listing": listingOnly = true
            case "--thumbnails": thumbnailCount = max(1, iterator.next().flatMap(Int.init) ?? thumbnailCount)
            default: say("Unknown argument \(argument)")
            }
        }
    }
}

// MARK: - Helpers

enum ProbeError: Error { case timedOut }

/// Resumes a continuation with whichever answer comes first, and ignores the others.
@MainActor
final class OnceAnswer<Value: Sendable> {
    var continuation: CheckedContinuation<Value, Never>?

    func resume(_ value: Value) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

/// Waits for a number of answers, or gives up.
@MainActor
final class Countdown {
    var continuation: CheckedContinuation<Void, Never>?
    private(set) var succeeded = 0
    private var remaining: Int

    init(_ count: Int) {
        remaining = count
    }

    func finishOne(succeeded: Bool) {
        if succeeded {
            self.succeeded += 1
        }
        remaining -= 1
        if remaining == 0 {
            giveUp()
        }
    }

    func giveUp() {
        continuation?.resume()
        continuation = nil
    }
}

// MARK: - Probe

/// Finds the first mass-storage camera device, opens it and runs the tests once its catalog is
/// complete. Every ImageCaptureCore callback arrives on the main thread, which is what lets the
/// delegate methods stay on the main actor (`@preconcurrency`).
@MainActor
final class Probe: NSObject, @preconcurrency ICDeviceBrowserDelegate, @preconcurrency ICCameraDeviceDelegate {
    private let options: Options
    private let browser = ICDeviceBrowser()
    private let clock = ContinuousClock()
    private var camera: ICCameraDevice?
    var foundDevice: Bool {
        camera != nil
    }

    private var sessionStart = ContinuousClock.now
    private var started = false
    private var addedItems = 0
    private var addedBatches = 0

    init(options: Options) {
        self.options = options
        super.init()
    }

    func start() {
        browser.delegate = self
        let mask = ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: mask) ?? .camera
        say("== Browsing for devices (sandboxed: \(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil))")
        browser.start()
    }

    // MARK: Browser

    func deviceBrowser(_: ICDeviceBrowser, didAdd device: ICDevice, moreComing _: Bool) {
        say("Device: \(device.name ?? "?") | transport \(device.transportType ?? "?") | type \(device.type.rawValue)")
        guard camera == nil, let found = device as? ICCameraDevice else { return }
        if let wanted = options.deviceName, found.name != wanted {
            return
        }
        camera = found
        found.delegate = self
        sessionStart = clock.now
        if options.chronological {
            found.requestOpenSession(options: [.enumerationChronologicalOrder: true]) { _ in }
        } else {
            found.requestOpenSession()
        }
    }

    func deviceBrowser(_: ICDeviceBrowser, didRemove device: ICDevice, moreGoing _: Bool) {
        say("Device removed: \(device.name ?? "?")")
    }

    // MARK: Device

    func device(_: ICDevice, didOpenSessionWithError error: (any Error)?) {
        say("Session opened after \(milliseconds(clock.now - sessionStart)), error: \(error.map { "\($0)" } ?? "none")")
    }

    func device(_: ICDevice, didCloseSessionWithError error: (any Error)?) {
        say("Session closed, error: \(error.map { "\($0)" } ?? "none")")
    }

    func didRemove(_: ICDevice) {}

    func device(_: ICDevice, didEncounterError error: (any Error)?) {
        say("Device error: \(error.map { "\($0)" } ?? "none")")
    }

    func cameraDevice(_: ICCameraDevice, didAdd items: [ICCameraItem]) {
        addedItems += items.count
        addedBatches += 1
        if addedBatches <= 3 || addedBatches % 100 == 0 {
            // What the device says of its progress, and the total that would follow from it.
            let percent = camera?.contentCatalogPercentCompleted ?? 0
            let estimate = percent > 0 ? "\(addedItems * 100 / Int(percent))" : "?"
            let date = (items.last as? ICCameraFile)?.creationDate.map { "\($0)".prefix(10) } ?? "?"
            say("  batch \(addedBatches): \(addedItems) items after \(milliseconds(clock.now - sessionStart)), \(percent) % done, total estimated \(estimate), last file of \(date) (\(items.last?.name ?? "?"))")
        }
    }

    func cameraDevice(_: ICCameraDevice, didRemove items: [ICCameraItem]) {
        say("Items removed: \(items.compactMap(\.name))")
    }

    func cameraDevice(_: ICCameraDevice, didReceiveThumbnail _: CGImage?, for _: ICCameraItem, error _: (any Error)?) {}
    func cameraDevice(_: ICCameraDevice, didReceiveMetadata _: [AnyHashable: Any]?, for _: ICCameraItem, error _: (any Error)?) {}
    func cameraDevice(_: ICCameraDevice, didRenameItems _: [ICCameraItem]) {}
    func cameraDeviceDidChangeCapability(_: ICCameraDevice) {}
    func cameraDevice(_: ICCameraDevice, didReceivePTPEvent _: Data) {}
    func cameraDeviceDidRemoveAccessRestriction(_: ICDevice) {}
    func cameraDeviceDidEnableAccessRestriction(_: ICDevice) {}

    func deviceDidBecomeReady(withCompleteContentCatalog _: ICCameraDevice) {
        guard !started, let camera else { return }
        started = true
        say("Catalog complete after \(milliseconds(clock.now - sessionStart))")
        Task {
            await self.runTests(on: camera)
            exit(0)
        }
    }

    // MARK: Tests

    private func runTests(on camera: ICCameraDevice) async {
        let files = (camera.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }
        describe(camera, files: files)
        if options.listingOnly {
            return
        }
        guard !files.isEmpty else { return }
        // Deleting is a run of its own: nothing else is read from the card.
        if let name = options.deleteName {
            await delete(named: name, in: files, camera: camera)
            return
        }

        // The catalog only says "public.image": tell a JPEG by its extension.
        let jpeg = files.first { ($0.name ?? "").uppercased().hasSuffix(".JPG") }
        let raw = files.first(where: \.isRaw)

        // Three different slices of the card, so that no run profits from what another one read.
        let count = options.thumbnailCount
        let slices = stride(from: 0, to: min(files.count, count * 3), by: count).map { Array(files[$0 ..< min($0 + count, files.count)]) }
        await gridThumbnails(of: slices[0], maxPixelSize: nil)
        if slices.count > 1 {
            await gridThumbnails(of: slices[1], maxPixelSize: 400)
        }
        if slices.count > 2 {
            await gridThumbnailsAtOnce(of: slices[2], maxPixelSize: 400)
        }
        // Files from the other end of the card, untouched by the runs above.
        await embeddedThumbnails(of: Array(files.suffix(count)))
        if let volume = options.directVolume {
            directThumbnails(onVolume: volume, count: count)
        }
        for file in [jpeg, raw].compactMap(\.self) {
            for size in [1024, 2048, 4096] {
                await largeThumbnail(of: file, maxPixelSize: size)
            }
            await metadata(of: file)
            directRead(of: file)
            await download(file)
        }
        if let mountPoint = camera.mountPoint {
            let listing = try? FileManager.default.contentsOfDirectory(atPath: mountPoint)
            say("== Listing the mount point directly: \(listing.map { "\($0.count) entries" } ?? "refused")")
        }
    }

    private func describe(_ camera: ICCameraDevice, files: [ICCameraFile]) {
        say("== Device")
        say("mount point: \(camera.mountPoint ?? "none") | locked: \(camera.isLocked) | ejectable: \(camera.isEjectable)")
        say("capabilities: \(camera.capabilities.sorted())")
        say("== Catalog: \(files.count) media files, \(camera.contents?.count ?? 0) top-level items")
        let byType = Dictionary(grouping: files) { $0.uti ?? "?" }.mapValues(\.count)
        for (type, count) in byType.sorted(by: { $0.key < $1.key }) {
            say("  \(type): \(count)")
        }
        say("raw: \(files.count(where: \.isRaw)) | locked files: \(files.count(where: \.isLocked))")
        let stems = Dictionary(grouping: files) { file in
            ((file.fileSystemPath ?? file.name ?? "") as NSString).deletingPathExtension
        }
        say("stems shared by several files (pairs, video thumbnails): \(stems.values.count { $0.count > 1 })")
        for file in files.prefix(3) {
            say("  \(file.name ?? "?") | \(file.uti ?? "?") | \(megabytes(Int64(file.fileSize))) | \(file.width) × \(file.height)"
                + " | created \(file.creationDate.map { "\($0)" } ?? "?") | path \(file.fileSystemPath ?? "none")")
        }
    }

    /// A request the device never answers must not hang the probe: it gives up after 10 s.
    /// The callbacks are `@Sendable` because some arrive off the main thread (the download's does),
    /// where a closure inferred as main-actor traps.
    private func thumbnailData(of file: ICCameraFile, options: [ICCameraItemThumbnailOption: Any]?) async -> (Data?, (any Error)?) {
        let answer = OnceAnswer<(Data?, (any Error)?)>()
        return await withCheckedContinuation { continuation in
            answer.continuation = continuation
            file.requestThumbnailData(options: options) { @Sendable data, error in
                Task { @MainActor in answer.resume((data, error)) }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                answer.resume((nil, ProbeError.timedOut))
            }
        }
    }

    private func gridThumbnails(of files: [ICCameraFile], maxPixelSize: Int?) async {
        say("== Grid thumbnails, \(maxPixelSize.map { "\($0) px" } ?? "default size"), one after the other")
        let options: [ICCameraItemThumbnailOption: Any]? = maxPixelSize.map { [.imageSourceThumbnailMaxPixelSize: $0] }
        let start = clock.now
        var failures = 0
        var sample = ""
        for file in files {
            let (data, error) = await thumbnailData(of: file, options: options)
            if let data, error == nil {
                if sample.isEmpty {
                    sample = "\(pixelSize(of: data)), \(data.count / 1000) kB"
                }
            } else if case ProbeError.timedOut? = error as? ProbeError, failures >= 2 {
                say("  three requests without an answer: giving up on the grid thumbnails")
                return
            } else {
                failures += 1
                if failures == 1 {
                    say("  first failure on \(file.name ?? "?"): \(error.map { "\($0)" } ?? "no data")")
                }
            }
        }
        let elapsed = clock.now - start
        say("\(files.count) thumbnails in \(milliseconds(elapsed)) (\(milliseconds(elapsed / max(files.count, 1))) each), failures: \(failures), first: \(sample)")
    }

    /// Every request sent before any answer, as a grid scrolled onto a new screen would do.
    private func gridThumbnailsAtOnce(of files: [ICCameraFile], maxPixelSize: Int) async {
        say("== Grid thumbnails, \(maxPixelSize) px, all asked at once")
        let start = clock.now
        let countdown = Countdown(files.count)
        await withCheckedContinuation { continuation in
            countdown.continuation = continuation
            for file in files {
                file.requestThumbnailData(options: [.imageSourceThumbnailMaxPixelSize: maxPixelSize]) { @Sendable data, _ in
                    let succeeded = data != nil
                    Task { @MainActor in countdown.finishOne(succeeded: succeeded) }
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(60))
                countdown.giveUp()
            }
        }
        let elapsed = clock.now - start
        say("\(countdown.succeeded) of \(files.count) thumbnails in \(milliseconds(elapsed)) (\(milliseconds(elapsed / max(files.count, 1))) each)")
    }

    /// Reads only the head of each file, where the EXIF thumbnail lives, instead of asking the
    /// device for a thumbnail (which, measured, costs as much as reading the whole file).
    private func embeddedThumbnails(of files: [ICCameraFile]) async {
        let length = 131_072
        say("== Embedded thumbnails from the first \(length / 1024) kB of each file")
        let start = clock.now
        var found = 0
        var sample = ""
        var firstFailure = ""
        var sizes: [String: Int] = [:]
        for file in files {
            let (data, error): (Data?, (any Error)?) = await withCheckedContinuation { continuation in
                file.requestReadData(atOffset: 0, length: off_t(min(length, Int(file.fileSize)))) { @Sendable data, error in
                    continuation.resume(returning: (data, error))
                }
            }
            guard let data else {
                if firstFailure.isEmpty {
                    firstFailure = "\(file.name ?? "?"): read failed, \(error.map { "\($0)" } ?? "no data")"
                }
                continue
            }
            // An EXIF thumbnail is 160 px and comes back as it is; 320 px wide would mean ImageIO
            // decoded the truncated image instead, which must not count.
            let embeddedOnly: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                kCGImageSourceCreateThumbnailFromImageAlways: false,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 320,
            ]
            if let source = CGImageSourceCreateWithData(data as CFData, nil),
               let image = CGImageSourceCreateThumbnailAtIndex(source, 0, embeddedOnly as CFDictionary)
            {
                found += 1
                sizes["\(image.width) × \(image.height)", default: 0] += 1
                if sample.isEmpty {
                    sample = "\(file.name ?? "?"), \(data.count) bytes read"
                }
            } else if firstFailure.isEmpty {
                firstFailure = "\(file.name ?? "?"): \(data.count) bytes read, no embedded thumbnail found"
            }
        }
        let elapsed = clock.now - start
        say("\(found) of \(files.count) in \(milliseconds(elapsed)) (\(milliseconds(elapsed / max(files.count, 1))) each), sizes: \(sizes), first: \(sample)\(firstFailure.isEmpty ? "" : ", first failure: " + firstFailure)")
    }

    /// The same thumbnails read straight from the mounted volume with ImageIO, as the app would
    /// if the user had handed it the card as a folder. Only possible where the sandbox allows it.
    private func directThumbnails(onVolume volume: String, count: Int) {
        say("== ImageIO straight from \(volume)")
        let root = URL(fileURLWithPath: volume).appendingPathComponent("DCIM")
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            say("refused: could not enumerate \(root.path)")
            return
        }
        let listStart = clock.now
        let jpegs = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension.uppercased() == "JPG" }.sorted { $0.path < $1.path }
        say("\(jpegs.count) JPEG files listed in \(milliseconds(clock.now - listStart))")
        // The middle of the card: neither end has been read by the runs above.
        let middle = Array(jpegs.dropFirst(jpegs.count / 2).prefix(count * 2))
        let runs: [(String, [URL], [CFString: Any])] = [
            ("embedded EXIF thumbnail", Array(middle.prefix(count)), [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 320,
            ]),
            ("400 px decoded from the image", Array(middle.dropFirst(count)), [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 400,
            ]),
        ]
        for (label, urls, thumbnailOptions) in runs {
            let start = clock.now
            var sample = ""
            var found = 0
            for url in urls {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
                else { continue }
                found += 1
                if sample.isEmpty {
                    sample = "\(image.width) × \(image.height)"
                }
            }
            let elapsed = clock.now - start
            say("\(label): \(found) of \(urls.count) in \(milliseconds(elapsed)) (\(milliseconds(elapsed / max(urls.count, 1))) each), first: \(sample)")
        }
    }

    private func largeThumbnail(of file: ICCameraFile, maxPixelSize: Int) async {
        let start = clock.now
        let (data, error) = await thumbnailData(of: file, options: [.imageSourceThumbnailMaxPixelSize: maxPixelSize])
        let result = data.map { "\(pixelSize(of: $0)), \($0.count / 1000) kB" } ?? "failed: \(error.map { "\($0)" } ?? "no data")"
        say("Thumbnail of \(file.name ?? "?") asked at \(maxPixelSize): \(result) in \(milliseconds(clock.now - start))")
    }

    private func metadata(of file: ICCameraFile) async {
        let start = clock.now
        // Only the keys leave the callback: the dictionary itself is not Sendable.
        let (keys, error): ([String], (any Error)?) = await withCheckedContinuation { continuation in
            file.requestMetadataDictionary(options: nil) { @Sendable metadata, error in
                continuation.resume(returning: ((metadata ?? [:]).keys.map { "\($0)" }.sorted(), error))
            }
        }
        say("Metadata of \(file.name ?? "?") in \(milliseconds(clock.now - start)): \(keys.count) keys \(keys.prefix(12)), error: \(error.map { "\($0)" } ?? "none")")
    }

    /// Reads the file through the file system, as ImageIOKit would, instead of asking the device.
    private func directRead(of file: ICCameraFile) {
        guard let path = file.fileSystemPath else {
            say("Direct read of \(file.name ?? "?"): no file system path")
            return
        }
        let url = URL(fileURLWithPath: path)
        do {
            let handle = try FileHandle(forReadingFrom: url)
            let head = try handle.read(upToCount: 65536) ?? Data()
            try handle.close()
            say("Direct read of \(path): allowed, \(head.count) bytes")
        } catch {
            say("Direct read of \(path): refused, \(error)")
            return
        }
        let start = clock.now
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
        ]
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
        {
            say("  ImageIO 2048 px preview from the card: \(image.width) × \(image.height) in \(milliseconds(clock.now - start))")
        } else {
            say("  ImageIO could not decode it from the card")
        }
    }

    private func download(_ file: ICCameraFile) async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("card-import-probe", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let start = clock.now
        let (name, error): (String?, (any Error)?) = await withCheckedContinuation { continuation in
            _ = file.requestDownload(options: [.downloadsDirectoryURL: folder, .overwrite: true]) { @Sendable name, error in
                continuation.resume(returning: (name, error))
            }
        }
        guard let name, error == nil else {
            say("Download of \(file.name ?? "?"): failed, \(error.map { "\($0)" } ?? "no name")")
            return
        }
        let copy = folder.appendingPathComponent(name)
        let size = (try? FileManager.default.attributesOfItem(atPath: copy.path)[.size] as? Int64) ?? -1
        let elapsed = clock.now - start
        say("Download of \(file.name ?? "?"): \(megabytes(size)) in \(milliseconds(elapsed)), size matches: \(size == Int64(file.fileSize)), into \(folder.path)")
        try? FileManager.default.removeItem(at: copy)
    }

    private func delete(named name: String, in files: [ICCameraFile], camera: ICCameraDevice) async {
        say("== Delete \(name)")
        let matches = files.filter { $0.name == name }
        guard matches.count == 1, let file = matches.first else {
            say("Expected exactly one file named \(name), found \(matches.count): nothing deleted")
            return
        }
        let start = clock.now
        let summary: String = await withCheckedContinuation { continuation in
            _ = camera.requestDeleteFiles(
                [file],
                deleteFailed: { @Sendable failed in say("  failed: \(failed.keys.map(\.rawValue))") },
                completion: { @Sendable result, error in
                    let counts = result.map { "\($0.key.rawValue): \($0.value.count)" }.sorted()
                    continuation.resume(returning: "\(counts), error: \(error.map { "\($0)" } ?? "none")")
                }
            )
        }
        say("Delete finished in \(milliseconds(clock.now - start)): \(summary)")
        let remaining = (camera.mediaFiles ?? []).count { $0.name == name }
        say("Files named \(name) left in the catalog: \(remaining)")
    }
}

// MARK: - Entry point

let probe = Probe(options: Options(arguments: CommandLine.arguments))
probe.start()
DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
    guard !probe.foundDevice else { return }
    say("No device announced after 20 s")
    exit(2)
}

DispatchQueue.main.asyncAfter(deadline: .now() + 400) {
    say("Gave up after 400 s")
    exit(3)
}

RunLoop.main.run()
