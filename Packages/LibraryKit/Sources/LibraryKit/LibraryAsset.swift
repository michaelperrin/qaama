import Foundation

/// Une photo de la bibliothèque, indépendante de sa source (Photos, fichier).
///
/// Volontairement sans référence à PhotoKit ni à AppKit pour rester portable :
/// l'identifiant suffit à retrouver l'objet d'origine dans la source.
nonisolated public struct LibraryAsset: Identifiable, Hashable, Sendable {
    public let id: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let creationDate: Date?
    public let isFavorite: Bool

    public init(id: String, pixelWidth: Int, pixelHeight: Int, creationDate: Date?, isFavorite: Bool) {
        self.id = id
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.creationDate = creationDate
        self.isFavorite = isFavorite
    }

    /// Ratio largeur / hauteur, ou 1 si les dimensions sont inconnues.
    public var aspectRatio: Double {
        guard pixelWidth > 0, pixelHeight > 0 else { return 1 }
        return Double(pixelWidth) / Double(pixelHeight)
    }
}
