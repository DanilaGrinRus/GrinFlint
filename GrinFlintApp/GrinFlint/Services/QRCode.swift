import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// QR-код для адреса или Slatepack.
enum QRCode {
    /// Возвращает изображение QR-кода (чёрное на прозрачном фоне — для скан-кода
    /// на экране нужен белый подложечный фон, его рисует вызывающий экран).
    static func image(for text: String, scale: CGFloat = 12) -> UIImage? {
        guard !text.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        )
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
