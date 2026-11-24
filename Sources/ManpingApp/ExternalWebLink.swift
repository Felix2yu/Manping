import AppKit
import Foundation

@MainActor enum ExternalWebLink {
  @discardableResult static func open(_ url: URL) -> Bool {
    guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil,
      NSWorkspace.shared.open(url) else {
      let alert = NSAlert()
      alert.messageText = "没能打开浏览器"
      alert.informativeText = "请检查链接是否安全，以及默认浏览器设置。"
      alert.alertStyle = .warning
      alert.addButton(withTitle: "好")
      alert.runModal()
      return false
    }
    return true
  }
}
