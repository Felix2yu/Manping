import AppKit
import SwiftUI
import XCTest

@testable import ManpingApp

@MainActor final class SegmentedTabsTests: XCTestCase {
  func testSelectedTabUsesSolidAccentInBothAppearances() {
    for scheme in [ColorScheme.light, .dark] {
      XCTAssertEqual(SegmentedTabAppearance.fill(selected: true), Theme.accent)
      XCTAssertEqual(SegmentedTabAppearance.foreground(selected: true, scheme: scheme), Theme.onAccent)
      XCTAssertEqual(SegmentedTabAppearance.fill(selected: false), .clear)
      XCTAssertEqual(SegmentedTabAppearance.foreground(selected: false, scheme: scheme), Theme.secondaryText(scheme))
    }
  }

  func testSelectedTabTextMeetsHighContrastTarget() throws {
    for scheme in [ColorScheme.light, .dark] {
      let foreground = try components(SegmentedTabAppearance.foreground(selected: true, scheme: scheme))
      let background = try components(Theme.accent)
      XCTAssertGreaterThanOrEqual(contrast(foreground, background), 7)
    }
  }

  func testFocusRingIsAbsentUnlessTheTabIsFocused() {
    for scheme in [ColorScheme.light, .dark] {
      XCTAssertEqual(SegmentedTabAppearance.focusStroke(focused: false, scheme: scheme), .clear)
      XCTAssertEqual(SegmentedTabAppearance.focusStroke(focused: true, scheme: scheme), Theme.accentText(scheme))
    }
  }

  private func components(_ color: Color) throws -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
    let resolved = try XCTUnwrap(NSColor(color).usingColorSpace(.sRGB))
    return (resolved.redComponent, resolved.greenComponent, resolved.blueComponent)
  }

  private func contrast(_ first: (red: CGFloat, green: CGFloat, blue: CGFloat),
                        _ second: (red: CGFloat, green: CGFloat, blue: CGFloat)) -> CGFloat {
    func luminance(_ value: (red: CGFloat, green: CGFloat, blue: CGFloat)) -> CGFloat {
      func linear(_ component: CGFloat) -> CGFloat {
        component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
      }
      return 0.2126 * linear(value.red) + 0.7152 * linear(value.green) + 0.0722 * linear(value.blue)
    }
    let a = luminance(first), b = luminance(second)
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
  }
}
