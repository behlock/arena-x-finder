import Foundation
import ImageIO
import UniformTypeIdentifiers

extension Store {
    static func prepareImage(_ url: URL, to output: URL) throws -> PreparedImage {
        guard url.isFileURL,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { throw BridgeError.message("Not a readable image.") }
        let type = CGImageSourceGetType(source) as String?
        let jpeg = type == UTType.jpeg.identifier
        let format = jpeg ? "jpeg" : "png"
        let target = output.appendingPathExtension(jpeg ? "jpg" : "png")
        let byteLimit = 10 * 1024 * 1024
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        // Keep already compatible images byte-for-byte, including transparency.
        // Animated images still use only their first frame, as before.
        if (jpeg || type == UTType.png.identifier), max(width, height) <= 4096,
           orientation == 1, CGImageSourceGetCount(source) == 1,
           (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= byteLimit {
            try FileManager.default.copyItem(at: url, to: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            return PreparedImage(format: format, width: width, height: height)
        }
        // Do not encode the same dimensions repeatedly for inputs under 4096px.
        let firstSize = min(4096, max(width, height))
        for maxPixels in [firstSize] + [3072, 2048, 1024].filter({ $0 < firstSize }) {
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels
              ] as CFDictionary)
            else { throw BridgeError.message("Not a readable image.") }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, (jpeg ? UTType.jpeg : UTType.png).identifier as CFString, 1, nil) else {
                throw BridgeError.message("Couldn’t prepare this image.")
            }
            let options = jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary : nil
            CGImageDestinationAddImage(destination, image, options)
            guard CGImageDestinationFinalize(destination) else {
                throw BridgeError.message("Couldn’t prepare this image.")
            }
            guard data.length <= byteLimit else { continue }
            try (data as Data).write(to: target, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            return PreparedImage(format: format, width: image.width, height: image.height)
        }
        throw BridgeError.message("Couldn’t fit the prepared image within 10 MB.")
    }

}
