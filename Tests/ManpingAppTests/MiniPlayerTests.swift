import AppKit
import ManpingCore
import XCTest
@testable import ManpingApp

final class MiniPlayerGeometryTests: XCTestCase {
  private let primary = MiniPlayerLayout.Screen(
    id: "built-in", frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
    visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 872), isPrimary: true)
  private let secondary = MiniPlayerLayout.Screen(
    id: "external", frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
    visibleFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1048))

  func testMiniWindowPresetsAreOrderedAndKeepVideoAspect() {
    XCTAssertEqual(MiniPlayerLayout.Preset.allCases.map(\.width), [360, 480, 720])
    XCTAssertEqual(MiniPlayerLayout.defaultWidth, 480)
    for preset in MiniPlayerLayout.Preset.allCases {
      let size = MiniPlayerLayout.size(aspect: 16.0 / 9, boxWidth: preset.width, screen: primary)
      XCTAssertEqual(size.width, preset.width)
      XCTAssertEqual(size.height / size.width, 9.0 / 16, accuracy: 0.001)
    }
    let portrait = MiniPlayerLayout.size(aspect: 9.0 / 16, boxWidth: 480, screen: primary)
    XCTAssertEqual(portrait.width, 270)
    XCTAssertEqual(portrait.height, 480)
  }

  func testMiniWindowFreeResizeProjectsOntoAspectAndClampsToBounds() {
    let screen = MiniPlayerLayout.Screen(frame: .zero, visibleFrame: CGRect(x: 0, y: 0, width: 500, height: 300))
    let enlarged = MiniPlayerLayout.resizedSize(start: CGSize(width: 480, height: 270),
      proposed: CGSize(width: 720, height: 500), aspect: 16.0 / 9, screen: primary)
    XCTAssertEqual(enlarged.height, 500, accuracy: 0.001)
    XCTAssertEqual(enlarged.width / enlarged.height, 16.0 / 9, accuracy: 0.001)
    let bounded = MiniPlayerLayout.resizedSize(start: CGSize(width: 480, height: 270),
      proposed: CGSize(width: 720, height: 500), aspect: 16.0 / 9, screen: screen)
    XCTAssertLessThanOrEqual(bounded.width, screen.visibleFrame.width - 2 * MiniPlayerLayout.margin)
    XCTAssertLessThanOrEqual(bounded.height, screen.visibleFrame.height - 2 * MiniPlayerLayout.margin)
    XCTAssertEqual(bounded.width / bounded.height, 16.0 / 9, accuracy: 0.001)

    let shrunk = MiniPlayerLayout.resizedSize(start: CGSize(width: 480, height: 270),
      proposed: CGSize(width: 100, height: 300), aspect: 16.0 / 9, screen: primary)
    XCTAssertEqual(shrunk.width, MiniPlayerLayout.widths.lowerBound)
    XCTAssertEqual(shrunk.height, 180)
  }

  func testMiniWindowRestoreClampsPartiallyOffscreenFrame() {
    let saved = CGRect(x: 3300, y: -100, width: 480, height: 270)
    let restored = MiniPlayerLayout.restoredFrame(saved: saved, aspect: 16.0 / 9,
      screens: [primary, secondary], preferredScreenID: nil)
    XCTAssertEqual(restored.screen.id, secondary.id)
    XCTAssertTrue(restored.keepFreePlacement)
    XCTAssertEqual(restored.frame.origin.x, 2864)
    XCTAssertEqual(restored.frame.origin.y, 16)
    XCTAssertTrue(secondary.visibleFrame.contains(restored.frame))
  }

  func testMiniWindowDisconnectedDisplayFallsBackToPrimary() {
    let saved = CGRect(x: 4000, y: 500, width: 720, height: 405)
    let restored = MiniPlayerLayout.restoredFrame(saved: saved, aspect: 16.0 / 9,
      screens: [primary], preferredScreenID: "unplugged")
    XCTAssertEqual(restored.screen.id, primary.id)
    XCTAssertFalse(restored.keepFreePlacement)
    XCTAssertEqual(restored.frame.width, 720)
    XCTAssertEqual(restored.frame.maxX, primary.visibleFrame.maxX - MiniPlayerLayout.margin)
    XCTAssertEqual(restored.frame.minY, primary.visibleFrame.minY + MiniPlayerLayout.margin)
  }

  func testMiniWindowReconnectedDisplayIDWinsOverOverlap() {
    let saved = CGRect(x: 100, y: 100, width: 480, height: 270)
    let restored = MiniPlayerLayout.restoredFrame(saved: saved, aspect: 16.0 / 9,
      screens: [primary, secondary], preferredScreenID: secondary.id)
    XCTAssertEqual(restored.screen.id, secondary.id)
    XCTAssertTrue(restored.keepFreePlacement)
    XCTAssertEqual(restored.frame.origin.x, secondary.visibleFrame.minX + MiniPlayerLayout.margin)
  }

  func testMiniWindowScreenSelectionUsesLargestVisibleOverlap() {
    let crossing = CGRect(x: 1300, y: 100, width: 500, height: 280)
    XCTAssertEqual(MiniPlayerLayout.screen(for: crossing, in: [primary, secondary]).id, secondary.id)
    let mostlyPrimary = CGRect(x: 1000, y: 100, width: 500, height: 280)
    XCTAssertEqual(MiniPlayerLayout.screen(for: mostlyPrimary, in: [primary, secondary]).id, primary.id)
  }

  func testMiniWindowScreenResolutionChangeFitsSizeAndOrigin() {
    let small = MiniPlayerLayout.Screen(id: "resized", frame: CGRect(x: 0, y: 0, width: 800, height: 600),
      visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 600), isPrimary: true)
    let fitted = MiniPlayerLayout.constrain(CGRect(x: 900, y: 500, width: 960, height: 540), to: small)
    XCTAssertEqual(fitted.width, 768)
    XCTAssertEqual(fitted.height, 432)
    XCTAssertEqual(fitted.origin.x, 16)
    XCTAssertEqual(fitted.origin.y, 152)
    XCTAssertTrue(small.visibleFrame.contains(fitted))
  }

  func testMiniWindowSnapUsesNearestCornerAndVisibleInsets() {
    let leftBottom = MiniPlayerLayout.snappedFrame(CGRect(x: 100, y: 100, width: 480, height: 270), on: primary)
    XCTAssertEqual(leftBottom.origin.x, 16)
    XCTAssertEqual(leftBottom.origin.y, 16)
    let rightTop = MiniPlayerLayout.snappedFrame(CGRect(x: 1300, y: 700, width: 480, height: 270), on: primary)
    XCTAssertEqual(rightTop.maxX, primary.visibleFrame.maxX - 16, accuracy: 0.001)
    XCTAssertEqual(rightTop.maxY, primary.visibleFrame.maxY - 16)
  }

  func testMiniWindowPlacementPersistsFrameModeAndDisplayIdentity() {
    let defaults = MemoryPreferences()
    let store = MiniPlayerPlacementStore(defaults: defaults)
    let frame = CGRect(x: 321.5, y: 123.25, width: 640, height: 360)
    store.save(frame: frame, free: true, screenID: "external")
    XCTAssertEqual(store.load(), .init(frame: frame, free: true, screenID: "external"))
    store.save(frame: frame, free: false, screenID: nil)
    XCTAssertEqual(store.load(), .init(frame: frame, free: false, screenID: nil))
  }

  func testMiniWindowMalformedLegacyFrameIsIgnored() {
    let defaults = MemoryPreferences(values: ["Manping.miniPlayerFrame": "{{0, 0}, {0, 0}}"])
    XCTAssertNil(MiniPlayerPlacementStore(defaults: defaults).load())
  }

  func testMiniWindowResizeHandleHasVisibleGlyphAndLargeHitRegion() {
    XCTAssertEqual(MiniPlayerLayout.resizeGlyphSize, 24)
    XCTAssertEqual(MiniPlayerLayout.resizeHitSize, 34)
    XCTAssertGreaterThan(MiniPlayerLayout.resizeHitSize, MiniPlayerLayout.resizeGlyphSize)
    XCTAssertGreaterThanOrEqual(MiniPlayerLayout.resizeHitSize, 32)
  }
}
