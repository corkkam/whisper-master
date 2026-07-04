import AppKit
import CoreImage.CIFilterBuiltins

// MARK: - QRCode
//
// Generates a crisp QR image for a short string (the Tailscale pairing URL). No
// dependency — CoreImage's built-in generator. `.interpolation(.none)` at the
// call site keeps the modules sharp when scaled.

enum QRCode {
    static func image(from string: String, scale: CGFloat = 12) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}
