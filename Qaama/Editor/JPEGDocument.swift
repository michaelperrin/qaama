import SwiftUI
import UniformTypeIdentifiers

/// Wraps encoded JPEG bytes so SwiftUI's file exporter can write them.
struct JPEGDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.jpeg]

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
