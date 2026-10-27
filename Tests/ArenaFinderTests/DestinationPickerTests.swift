import AppKit
import XCTest
import ArenaCore
@testable import ArenaFinder

final class DestinationPickerTests: XCTestCase {
    @MainActor
    func testScrollingLoadsMoreWithoutLosingPositionOrKeyboardSelection() throws {
        _ = NSApplication.shared
        let controller = DestinationChoicesController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 296),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = controller.view
        defer { window.close() }
        let channels = (1...40).map { Destination(channelID: $0, name: "Channel \($0)", slug: "channel-\($0)") }
        var requests = 0
        controller.onNearEnd = { requests += 1 }
        controller.update(Array(channels.prefix(20)), selectedID: "1")
        controller.view.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(controller.view.subviews.first as? NSScrollView)
        let rows = try XCTUnwrap(scroll.documentView as? NSStackView)
        XCTAssertEqual(requests, 0, "Opening the picker must not crawl account pages")
        for _ in 0..<19 { controller.moveDown(nil) }
        XCTAssertGreaterThan(requests, 0)
        let oldLast = rows.arrangedSubviews[19]
        XCTAssertTrue(scroll.documentVisibleRect.intersects(oldLast.frame))
        let offset = oldLast.frame.minY - scroll.documentVisibleRect.minY
        requests = 0
        controller.update(channels, selectedID: "1", preservingScroll: true)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(requests, 0, "Appending results must not start another request")
        XCTAssertEqual(rows.arrangedSubviews[19].frame.minY - scroll.documentVisibleRect.minY, offset, accuracy: 1)
        var selected: String?
        controller.onSelect = { selected = $0 }
        controller.insertNewline(nil)
        XCTAssertEqual(selected, "20", "Appending results preserves keyboard focus")
        rows.scrollToVisible(rows.arrangedSubviews[39].frame)
        XCTAssertGreaterThan(requests, 0, "Mouse/trackpad scrolling also requests the next page")
    }
}
