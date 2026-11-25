import AppKit
import XCTest

@testable import ManpingApp

@MainActor final class PlaybackKeyboardShortcutTests: XCTestCase {
  private func event(_ key: String, modifiers: NSEvent.ModifierFlags = [], keyCode: UInt16 = 0) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
      context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: keyCode)!
  }

  func testClientShortcuts() {
    let cases: [(String, NSEvent.ModifierFlags, PlaybackShortcut)] = [
      ("a", [], .home), ("b", [], .player), ("g", [], .zoom), ("s", [], .compact),
      ("x", [], .info), ("c", [], .comments), ("v", [], .share), ("d", [], .toggleDanmaku),
      ("m", [], .mute), ("f", [], .fullScreen), ("\u{1b}", [], .exitFullScreen),
      ("\t", .control, .cycleWindows),
    ]
    for (key, modifiers, expected) in cases {
      XCTAssertEqual(PlaybackShortcut.match(event(key, modifiers: modifiers, keyCode: key == "\t" ? 48 : 0)), expected)
    }
  }

  func testPlayerShortcutsAndModifiedVariants() {
    let left = "\u{f703}", right = "\u{f702}", up = "\u{f700}", down = "\u{f701}"
    let cases: [(String, NSEvent.ModifierFlags, PlaybackShortcut)] = [
      ("q", [], .like), ("w", [], .coin), ("e", [], .favorite), ("r", [], .triple),
      (" ", [], .playPause), ("\r", [], .composeDanmaku),
      (left, [], .seekBackward), (right, [], .seekForward), (up, [], .volumeUp), (down, [], .volumeDown),
      (left, [.shift, .function], .speedDown), (right, [.shift, .function], .speedUp),
      (up, [.shift, .function], .volumeUp), (down, [.shift, .function], .volumeDown),
      ("[", [], .previousAdjacent), ("]", [], .nextAdjacent),
      ("<", [], .previousAdjacent), (">", [], .nextAdjacent),
      ("<", .shift, .previousHistory), (">", .shift, .nextHistory),
    ]
    for (key, modifiers, expected) in cases {
      XCTAssertEqual(PlaybackShortcut.match(event(key, modifiers: modifiers)), expected)
    }
  }

  func testAdjacentPartKeysUsePhysicalKeyCodes() {
    XCTAssertEqual(PlaybackShortcut.match(event(",", keyCode: 43)), .previousAdjacent)
    XCTAssertEqual(PlaybackShortcut.match(event(".", keyCode: 45)), .nextAdjacent)
    XCTAssertEqual(PlaybackShortcut.match(event("]", keyCode: 30)), .nextAdjacent)
    XCTAssertEqual(PlaybackShortcut.match(event("[", keyCode: 33)), .previousAdjacent)
    XCTAssertEqual(PlaybackShortcut.match(event("<", modifiers: .shift, keyCode: 43)), .previousHistory)
    XCTAssertEqual(PlaybackShortcut.match(event(">", modifiers: .shift, keyCode: 45)), .nextHistory)
  }

  func testArrowShortcutsUsePhysicalKeyCodes() {
    XCTAssertEqual(PlaybackShortcut.match(event("\u{f703}", keyCode: 124)), .seekForward)
    XCTAssertEqual(PlaybackShortcut.match(event("\u{f702}", modifiers: .shift, keyCode: 123)), .speedDown)
    XCTAssertEqual(PlaybackShortcut.match(event("\u{f703}", modifiers: .shift, keyCode: 124)), .speedUp)
    XCTAssertEqual(PlaybackShortcut.match(event("\u{f701}", modifiers: .shift, keyCode: 125)), .volumeUp)
    XCTAssertEqual(PlaybackShortcut.match(event("\u{f700}", modifiers: .shift, keyCode: 126)), .volumeDown)
  }

  func testShiftNumberKeysUsePhysicalKeyCodes() {
    XCTAssertEqual(PlaybackShortcut.match(event("!", modifiers: .shift, keyCode: 18)), .normalSpeed)
    XCTAssertEqual(PlaybackShortcut.match(event("@", modifiers: .shift, keyCode: 19)), .doubleSpeed)
    XCTAssertNil(PlaybackShortcut.match(event("1", modifiers: .shift, keyCode: 0)))
  }

  func testSystemShortcutsAndUnknownKeysAreNotIntercepted() {
    for modifiers in [NSEvent.ModifierFlags.command, [.command, .shift], .option] {
      XCTAssertNil(PlaybackShortcut.match(event("q", modifiers: modifiers)))
    }
    XCTAssertNil(PlaybackShortcut.match(event("q", modifiers: .control)))
    XCTAssertNil(PlaybackShortcut.match(event("z")))
  }

  func testCapsLockDoesNotDisableShortcuts() {
    XCTAssertEqual(PlaybackShortcut.match(event("Q", modifiers: .capsLock)), .like)
  }

  func testFunctionAndNumericPadFlagsDoNotDisablePlaybackKeys() {
    XCTAssertEqual(PlaybackShortcut.match(event(" ", modifiers: .numericPad, keyCode: 49)), .playPause)
    XCTAssertEqual(PlaybackShortcut.match(event("\u{f702}", modifiers: .function, keyCode: 124)), .seekForward)
    XCTAssertEqual(PlaybackShortcut.match(event("\r", modifiers: .numericPad, keyCode: 76)), .composeDanmaku)
  }

  func testEditableTextBlocksPlaybackShortcuts() {
    let editor = NSTextView(frame: .zero)
    editor.isEditable = true
    XCTAssertTrue(PlaybackKeyboardInput.blocksShortcut(editor))
    editor.isEditable = false
    XCTAssertFalse(PlaybackKeyboardInput.blocksShortcut(editor))
    XCTAssertFalse(PlaybackKeyboardInput.blocksShortcut(nil))
  }

  func testHeldKeyMatchesOnlyItsOwnRelease() {
    let right = event(rightKey, keyCode: 124)
    XCTAssertTrue(PlaybackShortcut.seekForward.matchesKeyUp(right))
    XCTAssertFalse(PlaybackShortcut.like.matchesKeyUp(right))
    XCTAssertTrue(PlaybackShortcut.like.matchesKeyUp(event("q")))
    XCTAssertTrue(PlaybackShortcut.triple.matchesKeyUp(event("r")))
  }

  private let rightKey = "\u{f702}"
}
