import Foundation

/// Opt-in synthetic list sizes for explicit fixture performance runs only.
enum FixturePerformance {
  static let sampleCount = 600
  static let supportedTargets: Set<String> = [
    "recommended", "popular", "search", "moment", "moment-all", "history", "favorites", "later", "live",
    "article", "space", "following", "followers", "pgc",
  ]

  static func isEnabled(
    target: String,
    arguments: [String] = ProcessInfo.processInfo.arguments
  ) -> Bool {
    guard arguments.contains("--perf-fixture"),
      let index = arguments.firstIndex(of: "--perf-scroll"),
      arguments.indices.contains(index + 1),
      supportedTargets.contains(arguments[index + 1])
    else { return false }
    return arguments[index + 1] == target
  }

  static func indices(page: Int, pageSize: Int) -> Range<Int>? {
    guard page > 0, pageSize > 0, page - 1 <= sampleCount / pageSize else { return nil }
    let start = (page - 1) * pageSize
    guard start < sampleCount else { return nil }
    return start..<min(start + pageSize, sampleCount)
  }

  static func cover(_ index: Int) -> String {
    "https://fixture.invalid/cover/\(index)"
  }
}
