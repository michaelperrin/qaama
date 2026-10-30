import EditorKit
import ImageIOKit
import SwiftUI

/// What the file says about itself: camera settings and dimensions, as read from its header.
struct InfoPanel: View {
    let model: EditorModel

    var body: some View {
        if let metadata = model.metadata {
            LabeledContent("Camera", value: [metadata.cameraMake, metadata.cameraModel].compactMap { $0 }.joined(separator: " "))
            if let lens = metadata.lens {
                LabeledContent("Lens", value: lens)
            }
            LabeledContent("Exposure", value: exposure(metadata))
            LabeledContent("Size", value: "\(metadata.pixelWidth) × \(metadata.pixelHeight)")
            if let date = metadata.captureDate {
                LabeledContent("Captured", value: date.formatted(date: .abbreviated, time: .shortened))
            }
        } else {
            Text("No metadata").foregroundStyle(.secondary)
        }
        LabeledContent("File", value: model.baseName)
    }

    /// "1/250 s · f/2.8 · ISO 800 · 35 mm", skipping what the file doesn't say.
    private func exposure(_ metadata: ImageMetadata) -> String {
        var parts: [String] = []
        if let time = metadata.exposureTime {
            parts.append(time >= 1 ? "\(time.formatted(.number.precision(.fractionLength(0 ... 1)))) s" : "1/\(Int((1 / time).rounded())) s")
        }
        if let aperture = metadata.aperture {
            parts.append("f/\(aperture.formatted(.number.precision(.fractionLength(0 ... 1))))")
        }
        if let iso = metadata.iso {
            parts.append("ISO \(iso)")
        }
        if let focal = metadata.focalLength {
            parts.append("\(focal.formatted(.number.precision(.fractionLength(0)))) mm")
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
}
