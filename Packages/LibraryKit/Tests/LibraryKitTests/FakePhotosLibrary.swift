import Foundation
import ImageIOKit
@testable import LibraryKit

/// A photo library in memory, standing in for PhotoKit: assets in listing order, a RAW set, and a
/// change history addressed by tokens that can expire.
actor FakePhotosLibrary: PhotosIndexLibrary {
    private var assets: [PhotosAssetReading]
    private var rawIDs: Set<String>
    private var token = 1
    /// Changes that led to each token.
    private var history: [(token: Int, upserted: Set<String>, deleted: Set<String>)] = []
    /// Tokens older than this one are no longer in the history.
    private var oldestToken = 0
    /// Every batch of identifiers asked for, in order.
    private(set) var readRequests: [[String]] = []

    private nonisolated let notifications: AsyncStream<Void>
    private nonisolated let continuation: AsyncStream<Void>.Continuation

    init(_ assets: [PhotosAssetReading], rawIDs: Set<String> = []) {
        self.assets = assets
        self.rawIDs = rawIDs
        (notifications, continuation) = AsyncStream.makeStream()
    }

    static func reading(_ id: String, _ fileName: String?, at second: TimeInterval = 0, keywords: [String] = [],
                        location: GeoCoordinate? = nil) -> PhotosAssetReading
    {
        PhotosAssetReading(id: id, fileName: fileName, captureDate: Date(timeIntervalSince1970: second), keywords: keywords, location: location)
    }

    // MARK: - Changing the library

    func add(_ reading: PhotosAssetReading, isRAW: Bool = false) {
        assets.insert(reading, at: 0)
        if isRAW {
            rawIDs.insert(reading.id)
        }
        record(upserted: [reading.id])
    }

    func rename(_ id: String, to fileName: String) {
        guard let index = assets.firstIndex(where: { $0.id == id }) else { return }
        assets[index].fileName = fileName
        record(upserted: [id])
    }

    func setKeywords(_ keywords: [String], of id: String) {
        guard let index = assets.firstIndex(where: { $0.id == id }) else { return }
        assets[index].keywords = keywords
        record(upserted: [id])
    }

    func setLocation(_ location: GeoCoordinate?, of id: String) {
        guard let index = assets.firstIndex(where: { $0.id == id }) else { return }
        assets[index].location = location
        record(upserted: [id])
    }

    func remove(_ id: String) {
        assets.removeAll { $0.id == id }
        rawIDs.remove(id)
        record(deleted: [id])
    }

    func setRAW(_ ids: Set<String>) {
        rawIDs = ids
    }

    /// Forgets the whole history: every token handed out so far is too old.
    func expireHistory() {
        oldestToken = token + 1
        token += 1
    }

    private func record(upserted: Set<String> = [], deleted: Set<String> = []) {
        token += 1
        history.append((token, upserted, deleted))
        continuation.yield()
    }

    // MARK: - PhotosIndexLibrary

    func assetIDs() -> [String] {
        assets.map(\.id)
    }

    func rawAssetIDs() -> Set<String> {
        rawIDs
    }

    func readings(for ids: [String]) -> [PhotosAssetReading] {
        readRequests.append(ids)
        let wanted = Set(ids)
        return assets.filter { wanted.contains($0.id) }
    }

    func currentChangeToken() -> Data? {
        Data("\(token)".utf8)
    }

    func changes(since data: Data) throws -> PhotosLibraryChanges {
        guard let since = Int(String(decoding: data, as: UTF8.self)), since >= oldestToken else {
            throw PhotosIndexError.unreadableChangeToken
        }
        var upserted: Set<String> = []
        var deleted: Set<String> = []
        for change in history where change.token > since {
            upserted.formUnion(change.upserted)
            upserted.subtract(change.deleted)
            deleted.formUnion(change.deleted)
        }
        return PhotosLibraryChanges(upserted: upserted, deleted: deleted, token: Data("\(token)".utf8))
    }

    nonisolated func changeNotifications() -> AsyncStream<Void> {
        notifications
    }
}
