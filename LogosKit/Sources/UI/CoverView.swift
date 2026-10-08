import SwiftUI
import UIKit

/// A Book's cover, at a fixed size: a solid placeholder until the downscaled image is ready, so rows never jump.
///
/// Decoding happens off the main thread (``CoverImages``); a cover already decoded at this size shows in the first
/// frame. Reads ``CoverImages`` from the environment; without one it's just the placeholder. Use it in rows
/// (`side: 48`) and on Book detail (`side: 240` or so; the file is ~600 px, so detail shows it at full size).
struct CoverView: View {
    let bookID: String
    /// The width and height in points.
    let side: CGFloat
    var cornerRadius: CGFloat = 6

    @Environment(CoverImages.self) private var images: CoverImages?
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        let version = images?.version(ofBook: bookID)
        let shown = version == nil ? nil : (image ?? images?.cachedImage(forBook: bookID, maxPixelSize: pixelSize))
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color(uiColor: .systemGray5))
            .overlay {
                if let shown {
                    Image(uiImage: shown)
                        .resizable()
                        .scaledToFill()
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .accessibilityHidden(true)
            .task(id: version) {
                guard let images, let version else {
                    image = nil
                    return
                }
                image = await images.image(forBook: bookID, version: version, maxPixelSize: pixelSize)
            }
    }

    private var pixelSize: Int {
        Int((side * displayScale).rounded(.up))
    }
}
