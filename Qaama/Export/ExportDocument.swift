import RenderEngine
import SwiftUI
import UniformTypeIdentifiers

/// Encoded bytes of an export, in any of the formats the exporter writes, for SwiftUI's file exporter.
struct ExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = ExportFormat.allCases.map(\.type)
    static let writableContentTypes: [UTType] = readableContentTypes

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
