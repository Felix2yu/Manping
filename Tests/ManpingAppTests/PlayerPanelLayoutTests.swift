import XCTest
import ManpingCore

@testable import ManpingApp

@MainActor final class PlayerPanelLayoutTests: XCTestCase {
  func testCompactTimelineKeepsItsDraggingHitArea() {
    XCTAssertEqual(PlaybackTimeline.curveHeight, 8)
    XCTAssertEqual(PlaybackTimeline.hitHeight, 16)
    XCTAssertLessThan(PlaybackTimeline.curveHeight + PlaybackTimeline.hitHeight, 30)
  }

  func testControlPanelUsesCompactSpacingAndPrimaryButton() {
    XCTAssertEqual(PlayerPanelLayout.spacing, 4)
    XCTAssertEqual(PlayerPanelLayout.topPadding, 6)
    XCTAssertEqual(PlayerPanelLayout.bottomPadding, 8)
    let button = PlayerPlayButton(paused: true) {}
    XCTAssertEqual(button.size, 36)
  }

  func testFloatingPanelKeepsStageInsets() {
    XCTAssertEqual(PlayerPanelLayout(stageWidth: 900).width, 860)
    XCTAssertEqual(PlayerPanelLayout(stageWidth: 0).width, 0)
  }

  func testFixedPanelsMeetTheStageEdgesWithoutChangingThePicture() {
    XCTAssertEqual(PlayerPanelLayout(stageWidth: 900, position: .floating).width, 860)
    XCTAssertEqual(PlayerPanelLayout(stageWidth: 900, position: .top).width, 876)
    XCTAssertEqual(PlayerPanelLayout(stageWidth: 900, position: .bottom).width, 876)
    XCTAssertEqual(PlayerPanelLayout(stageWidth: 0, position: .top).width, 0)
    XCTAssertEqual(PlayerPanelLayout(stageWidth: 100, position: .bottom).width, 76)
  }

  func testChromeDelayCanChangeWithoutRecreatingVisibilityState() {
    let chrome = PlayerChromeState(idleDelay: 1.5)
    defer { chrome.stop() }
    XCTAssertEqual(chrome.idleDelay, 1.5)
    chrome.setIdleDelay(4.5)
    XCTAssertEqual(chrome.idleDelay, 4.5)
    XCTAssertTrue(chrome.visible)
  }

  func testCursorHidesOnlyWhilePlayingOverUnpinnedPicture() {
    XCTAssertTrue(PlayerCursorPolicy.hides(visible: false, playing: true, inside: true, pinned: false, overControls: false))
    XCTAssertFalse(PlayerCursorPolicy.hides(visible: true, playing: true, inside: true, pinned: false, overControls: false))
    XCTAssertFalse(PlayerCursorPolicy.hides(visible: false, playing: false, inside: true, pinned: false, overControls: false))
    XCTAssertFalse(PlayerCursorPolicy.hides(visible: false, playing: true, inside: false, pinned: false, overControls: false))
    XCTAssertFalse(PlayerCursorPolicy.hides(visible: false, playing: true, inside: true, pinned: true, overControls: false))
    XCTAssertFalse(PlayerCursorPolicy.hides(visible: false, playing: true, inside: true, pinned: false, overControls: true))
  }
}
