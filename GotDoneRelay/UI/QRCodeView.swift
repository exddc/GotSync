import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

struct QRCodeView: View {
    let url: URL

    var body: some View {
        Group {
            if let image = Self.image(for: url) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
            } else {
                Image(systemName: "qrcode")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .padding(32)
            }
        }
        .padding(12)
        .background(.white, in: RoundedRectangle(cornerRadius: 12))
    }

    private static func image(for url: URL) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"

        guard let output = filter.outputImage else {
            return nil
        }
        let scaled = output.transformed(
            by: CGAffineTransform(scaleX: 12, y: 12)
        )
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
