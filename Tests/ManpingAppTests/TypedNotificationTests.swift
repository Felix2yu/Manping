import AppKit
import XCTest

@MainActor final class TypedNotificationTests: XCTestCase {
  func testUserDefaultsMessageObservesLegacyPosts() async {
    let received = expectation(description: "typed UserDefaults message")
    let token = NotificationCenter.default.addObserver(for: UserDefaults.DidChangeMessage.self) { _ in
      received.fulfill()
    }
    defer { NotificationCenter.default.removeObserver(token) }
    NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
    await fulfillment(of: [received], timeout: 1)
  }

  func testWindowMessageObservesLegacyPosts() async {
    _ = NSApplication.shared
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled],
      backing: .buffered, defer: false)
    let received = expectation(description: "typed window message")
    let token = NotificationCenter.default.addObserver(for: NSWindow.DidEnterFullScreenMessage.self) { _ in
      received.fulfill()
    }
    defer { NotificationCenter.default.removeObserver(token) }
    NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: window)
    await fulfillment(of: [received], timeout: 1)
  }
}