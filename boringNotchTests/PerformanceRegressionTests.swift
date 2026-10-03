import AppKit
import XCTest
@testable import boringNotch

@MainActor
final class PerformanceRegressionTests: XCTestCase {
    func testArtworkDecodeBoundsPixelsAndRetainsAspectRatio() async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1600, height: 800,
            bitsPerComponent: 8, bytesPerRow: 1600 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 1600, height: 800))
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let image = try XCTUnwrap(NSImage.downsampledArtwork(from: data))
        let thumbnail = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(thumbnail.width, 256)
        XCTAssertEqual(thumbnail.height, 128)
        let average = try XCTUnwrap(await image.averageColor()?.usingColorSpace(.sRGB))
        XCTAssertEqual(Double(average.redComponent), 1, accuracy: 0.01)
        XCTAssertEqual(Double(average.greenComponent), 0, accuracy: 0.01)
        XCTAssertEqual(Double(average.blueComponent), 0, accuracy: 0.01)
        XCTAssertNil(NSImage.downsampledArtwork(from: Data()))
    }

    // Override occlusion to exercise AppKit lifecycle without displaying windows.
    private final class VisibilityWindow: NSWindow {
        var testVisible = true
        override var occlusionState: NSWindow.OcclusionState { testVisible ? [.visible] : [] }
    }

    func testDetachedAndHiddenVisualizerStopsLayerAnimations() {
        let window = VisibilityWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 30),
            styleMask: [], backing: .buffered, defer: true)
        let view = MusicVisualizerModel(frame: CGRect(x: 0, y: 0, width: 20, height: 14))
        view.setPlaying(true)
        XCTAssertNil(view.layer?.sublayers?.first?.animation(forKey: "scaleAnimation"))
        window.contentView?.addSubview(view)
        XCTAssertTrue(view.layer?.sublayers?.first?.animation(forKey: "scaleAnimation") != nil)
        window.testVisible = false
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        XCTAssertNil(view.layer?.sublayers?.first?.animation(forKey: "scaleAnimation"))
        window.testVisible = true
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        XCTAssertTrue(view.layer?.sublayers?.first?.animation(forKey: "scaleAnimation") != nil)
        view.isHidden = true
        XCTAssertNil(view.layer?.sublayers?.first?.animation(forKey: "scaleAnimation"))
        view.isHidden = false
        XCTAssertTrue(view.layer?.sublayers?.first?.animation(forKey: "scaleAnimation") != nil)
        view.removeFromSuperview()
        XCTAssertNil(view.layer?.sublayers?.first?.animation(forKey: "scaleAnimation"))
    }
}
