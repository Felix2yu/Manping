import AppKit
import XCTest
@testable import ManpingApp

final class PlayerFullScreenTests: XCTestCase {
  @MainActor func testTerminalFailureClearsPreviousMediaClock() {
    let player = PlayerModel()
    player.time = 125
    player.duration = 600
    player.failPlayback("fixture failure")
    XCTAssertTrue(player.terminalFailure)
    XCTAssertEqual(player.time, 0)
    XCTAssertEqual(player.duration, 0)
    XCTAssertTrue(player.paused)
    XCTAssertFalse(player.eofReached)
    XCTAssertEqual(player.error, "fixture failure")
  }

  @MainActor func testDetachedWindowKeepsOneFullSizePlayerSurfaceAcrossResizes() throws {
    _ = NSApplication.shared
    let coordinator = M7PlaybackWindowCoordinator(savesFrame: false)
    let content = NSView(frame: CGRect(origin: .zero, size: M7PlaybackWindowCoordinator.defaultSize))
    var closeCalls = 0
    coordinator.present(content: content, mainWindow: nil, displayMode: nil) {
      closeCalls += 1
    }
    let window = try XCTUnwrap(coordinator.window)
    XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
    XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size, M7PlaybackWindowCoordinator.defaultSize)
    XCTAssertEqual(window.minSize, M7PlaybackWindowCoordinator.minimumSize)
    XCTAssertEqual(window.backgroundColor, Theme.stageNSColor)
    XCTAssertTrue(window.contentView === content)

    for size in [M7PlaybackWindowCoordinator.minimumSize, NSSize(width: 960, height: 540), wideSize] {
      window.setContentSize(size)
      XCTAssertTrue(window.contentView === content, "resizing must not create a second player owner")
    }

    coordinator.close(showMain: false)
    coordinator.close(showMain: false)
    XCTAssertNil(coordinator.window)
    XCTAssertNil(window.contentView)
    XCTAssertEqual(closeCalls, 1, "closing restores the main player exactly once")
  }

  @MainActor func testDetachedWindowLeavesTheMainWindowVisible() throws {
    _ = NSApplication.shared
    let mainWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    mainWindow.isReleasedWhenClosed = false
    mainWindow.orderFront(nil)
    defer { mainWindow.close() }
    let coordinator = M7PlaybackWindowCoordinator(savesFrame: false)
    coordinator.present(content: NSView(), mainWindow: mainWindow, displayMode: nil) {}
    XCTAssertTrue(mainWindow.isVisible)
    coordinator.close(showMain: false)
    XCTAssertTrue(mainWindow.isVisible)
  }

  @MainActor func testDetachedWindowDisplayModesKeepTheirExistingPlacementBehavior() throws {
    _ = NSApplication.shared
    let coordinator = M7PlaybackWindowCoordinator(savesFrame: false)
    coordinator.present(content: NSView(), mainWindow: nil, displayMode: nil) {}
    let window = try XCTUnwrap(coordinator.window)

    coordinator.applyDisplayMode("compact")
    XCTAssertEqual(window.level, .floating)
    XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size, NSSize(width: 800, height: 500))

    coordinator.applyDisplayMode("default")
    XCTAssertEqual(window.level, .normal)
    coordinator.close(showMain: false)
  }

  private let wideSize = NSSize(width: 1440, height: 810)

  func testExitFramesFitCurrentVisibleScreen() {
    let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
    let visible = NSRect(x: 0, y: 25, width: 1440, height: 850)
    let cases: [(NSRect, NSRect)] = [
      (NSRect(x: 100, y: 100, width: 800, height: 600), NSRect(x: 100, y: 100, width: 800, height: 600)),
      (NSRect(x: 100, y: 300, width: 800, height: 600), NSRect(x: 100, y: 275, width: 800, height: 600)),
      (screen, visible),
      (NSRect(x: 2000, y: 100, width: 800, height: 600), NSRect(x: 320, y: 150, width: 800, height: 600)),
      (NSRect(x: 0, y: 0, width: 1600, height: 1000), visible),
      (NSRect(x: 1300, y: 100, width: 800, height: 600), NSRect(x: 320, y: 150, width: 800, height: 600)),
    ]
    for (saved, expected) in cases {
      let result = playerExitFrame(saved, screen: screen, visible: visible)
      XCTAssertEqual(result, expected)
      XCTAssertTrue(visible.contains(result), "\(result) outside \(visible)")
    }
  }
}
