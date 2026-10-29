import CoreGraphics
import Photos

#if canImport(AppKit)
import AppKit

typealias PlatformImage = NSImage

/// Called from PhotoKit completion handlers that run off the main actor.
nonisolated extension NSImage {
    /// Converts the AppKit image handed out by PhotoKit into a `CGImage`, the only image type LibraryKit exposes.
    var asCGImage: CGImage? {
        cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
#elseif canImport(UIKit)
import UIKit

typealias PlatformImage = UIImage

nonisolated extension UIImage {
    var asCGImage: CGImage? {
        cgImage
    }
}
#endif
