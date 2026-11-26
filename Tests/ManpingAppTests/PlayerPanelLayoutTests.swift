import AppKit
import SwiftUI
import XCTest
import ManpingCore

@testable import ManpingApp

@MainActor private final class PlaybackTimelineLayoutProbe {
  var width: CGFloat = 0
  var updates = 0
}

@MainActor final class PlayerPanelLayoutTests: XCTestCase {
  func testCompactTimelineKeepsItsDraggingHitArea() {
    XCTAssertEqual(PlaybackTimeline.curveHeight, 8)
    XCTAssertEqual(PlaybackTimeline.hitHeight, 16)
    XCTAssertLessThan(PlaybackTimeline.curveHeight + PlaybackTimeline.hitHeight, 30)
  }

  func testPlaybackUpdatesDoNotRepeatedlyResizeTheTimeline() async throws {
    _ = NSApplication.shared
    let clock = PlaybackClock(), probe = PlaybackTimelineLayoutProbe()
    let timeline = PlaybackTimeline(
      clock: clock,
      duration: 120,
      density: Array(repeating: 0.6, count: 64),
      chapters: (1...4).map { PlaybackChapter(index: $0 - 1, title: "章节 \($0)", time: Double($0 * 24)) },
      markers: [12, 36, 60, 84],
      bookmarkTimes: [18, 54],
      bufferedAhead: { 20 },
      seek: { _ in }
    )
    let host = NSHostingView(rootView: timeline
      .frame(width: 860)
      .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
        probe.width = $0
        probe.updates += 1
      })
    host.frame = CGRect(x: 0, y: 0, width: 860, height: 24)
    try await settle(host)
    let settledWidth = probe.width
    let settledUpdates = probe.updates
    XCTAssertEqual(settledWidth, 860, accuracy: 0.5)

    for tick in 1...100 {
      clock.time = Double(tick) / 10
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(5))
    }

    XCTAssertEqual(probe.width, settledWidth, accuracy: 0.5)
    XCTAssertEqual(probe.updates, settledUpdates, "clock ticks must not feed the track's geometry back into layout")
  }

  private func settle(_ view: NSView) async throws {
    for _ in 0..<8 {
      view.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(10))
    }
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
