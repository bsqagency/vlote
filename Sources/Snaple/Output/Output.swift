import AppKit
import ImageIO

enum ImageEncoder {
    /// Encodes with the image's own colour profile embedded and DPI set from the capture scale, so a
    /// Retina capture opens at its true point size everywhere.
    static func data(for image: CGImage, scale: CGFloat, format: ImageFormat, quality: CGFloat = 0.92) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, format.utType.identifier as CFString, 1, nil) else { return nil }
        var props: [CFString: Any] = [kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale]
        if format == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}

enum Output {
    static func copyToPasteboard(_ image: CGImage?, scale: CGFloat) {
        guard let image, let png = ImageEncoder.data(for: image, scale: scale, format: .png) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(png, forType: .png)
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        if let tiff = NSImage(cgImage: image, size: size).tiffRepresentation { pb.setData(tiff, forType: .tiff) }
    }

    static func copyText(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    static func fileName(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Snaple " + f.string(from: date)
    }

    /// Writes into `directory`, never overwriting an existing file.
    static func write(_ image: CGImage, scale: CGFloat, date: Date, format: ImageFormat, directory: URL) throws -> URL {
        guard let data = ImageEncoder.data(for: image, scale: scale, format: format) else {
            throw CaptureError.failed("Could not encode the image.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = fileName(for: date)
        var url = directory.appendingPathComponent(base).appendingPathExtension(format.fileExtension)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base) \(n)").appendingPathExtension(format.fileExtension)
            n += 1
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    static var dragCacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Snaple/drag", isDirectory: true)
    }

    static func playShutter() {
        guard Preferences.playSound else { return }
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        NSSound(contentsOfFile: path, byReference: true)?.play()
    }
}
