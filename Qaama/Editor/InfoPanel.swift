import ImageIOKit
import SwiftUI

/// What the file says about itself: camera settings and dimensions, as read from its header. Rows
/// the file has nothing to say for are left out. Shared by the editor's Info tab and the grid's
/// Info panel.
struct InfoPanel: View {
    let metadata: ImageMetadata?
    let fileName: String?

    var body: some View {
        if let metadata {
            if let camera = camera(metadata) {
                LabeledContent("Camera", value: camera)
            }
            if let lens = metadata.lens {
                LabeledContent("Lens", value: lens)
            }
            if let exposure = exposure(metadata) {
                LabeledContent("Exposure", value: exposure)
            }
            if metadata.pixelWidth > 0, metadata.pixelHeight > 0 {
                LabeledContent("Size", value: "\(metadata.pixelWidth) × \(metadata.pixelHeight)")
            }
            if let date = metadata.captureDate {
                LabeledContent("Captured", value: date.formatted(date: .abbreviated, time: .shortened))
            }
        } else {
            Text("No metadata").foregroundStyle(.secondary)
        }
        if let fileName {
            LabeledContent("File", value: fileName)
        }
    }

    private func camera(_ metadata: ImageMetadata) -> String? {
        let parts = [metadata.cameraMake, metadata.cameraModel].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// "1/250 s · f/2.8 · ISO 800 · 35 mm", skipping what the file doesn't say.
    private func exposure(_ metadata: ImageMetadata) -> String? {
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
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

#Preview {
    Form {
        Section("Info") {
            InfoPanel(metadata: ImageMetadata(pixelWidth: 6240, pixelHeight: 4160, captureDate: .now, cameraMake: "FUJIFILM",
                                              cameraModel: "X-T5", lens: "XF35mmF2 R WR", iso: 400, exposureTime: 0.004,
                                              aperture: 2.8, focalLength: 35),
                      fileName: "DSCF1234.RAF")
        }
    }
    .formStyle(.grouped)
    .frame(width: 280, height: 320)
}
