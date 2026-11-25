import Foundation

public enum AppIdentity {
  public static let bundleIdentifier = "im.yufei.manping"
  public static let debugBundleIdentifier = bundleIdentifier + ".debug"
  public static let perfBundleIdentifier = bundleIdentifier + ".perf"
  public static let urlScheme = "manpingx"
  public static let storageDirectoryName = bundleIdentifier

  public static var isDebugApp: Bool {
    Bundle.main.bundleIdentifier == debugBundleIdentifier
  }

  public static func variant(for identifier: String?) -> String? {
    guard let identifier else { return nil }
    if identifier == bundleIdentifier { return "" }
    let prefix = bundleIdentifier + "."
    guard identifier.hasPrefix(prefix) else { return nil }
    let suffix = identifier.dropFirst(prefix.count)
    return suffix.isEmpty ? nil : "-" + String(suffix)
  }

  public static var applicationSupportDirectory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent(storageDirectoryName, isDirectory: true)
  }

  public static var cachesDirectory: URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent(storageDirectoryName, isDirectory: true)
  }
}
