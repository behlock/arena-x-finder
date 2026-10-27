import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ArenaFinder

final class IconRendererTests: XCTestCase {
    func testWebsitePreviewProducesTransparentRoundedPNGAtFinderSize() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 128, height: 96,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 128, height: 96))
        let image = try IconRenderer.render(screenshot: XCTUnwrap(context.makeImage()),
                                            websiteURL: URL(string: "https://example.com")!)
        let png = try IconRenderer.pngData(image)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.png.identifier)
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, 512)
        XCTAssertEqual(decoded.height, 512)
        let pixels = try XCTUnwrap(CGContext(data: nil, width: 512, height: 512,
            bitsPerComponent: 8, bytesPerRow: 512 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        pixels.draw(decoded, in: CGRect(x: 0, y: 0, width: 512, height: 512))
        let bytes = try XCTUnwrap(pixels.data).assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(bytes[3], 0, "Rounded corners retain transparency")
        let center = (256 * 512 + 256) * 4
        XCTAssertEqual(bytes[center + 3], 255)
        XCTAssertGreaterThan(bytes[center + 2], bytes[center], "The website screenshot remains visible")
    }
}
