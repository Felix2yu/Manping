import Foundation

/// Compact viewing state returned by bili-history's `/api/watch-progress/query`.
public struct WatchRecord: Codable, Equatable, Sendable {
  public let bvid: String
  public let watched: Bool
  public let progress: Int
  public let duration: Int
  public let finished: Bool
  public let viewAt: Int64

  public init(bvid: String, watched: Bool, progress: Int, duration: Int, finished: Bool, viewAt: Int64) {
    self.bvid = bvid; self.watched = watched; self.progress = progress
    self.duration = duration; self.finished = finished; self.viewAt = viewAt
  }

  enum CodingKeys: String, CodingKey {
    case bvid, watched, progress, duration, finished
    case viewAt = "view_at"
  }

  /// The fraction drawn under the cover; a finished video fills the whole bar.
  public var fraction: Double {
    guard watched else { return 0 }
    if finished { return 1 }
    guard duration > 0, progress > 0 else { return 0 }
    return min(1, Double(progress) / Double(duration))
  }
}

/// Shared configuration plumbing for the external history service. The URL is a
/// preference; the token is a credential and lives in the local secret vault.
public enum BiliHistoryConfig {
  public static let tokenEntry = "bili-history-token"

  public static func readToken() -> String {
    guard let data = try? LocalSecretVault.shared.read(tokenEntry) else { return "" }
    return String(data: data, encoding: .utf8) ?? ""
  }

  @discardableResult public static func writeToken(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    do {
      if trimmed.isEmpty { try LocalSecretVault.shared.delete(tokenEntry) }
      else { try LocalSecretVault.shared.write(tokenEntry, Data(trimmed.utf8)) }
      return true
    } catch { return false }
  }

  /// Accepts an empty value (sync off) or an http(s) host. A pasted `/api` suffix is removed so
  /// the address is always the server root, the same form bili-history documents.
  public static func normalizedBaseURL(_ raw: String) -> String? {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.isEmpty { return "" }
    guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
      let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
    var base = value
    while base.hasSuffix("/") { base.removeLast() }
    if base.lowercased().hasSuffix("/api") { base = String(base.dropLast(4)) }
    return base
  }

  public static func endpoint(_ base: String, path: String) -> URL? {
    guard let base = normalizedBaseURL(base), !base.isEmpty else { return nil }
    return URL(string: base + "/api/watch-progress/" + path)
  }

  /// Backoff after consecutive failures: 1, 2, 4, 8, 16 then a 30-minute ceiling. An office
  /// machine may be off VPN for eight hours; probing every five minutes is pointless, while a
  /// cap of 30 minutes still lets a VPN session restore within a reasonable time. A successful
  /// report or 测试连接 resets it immediately.
  public static func backoffSeconds(afterFailures count: Int) -> Double {
    guard count > 0 else { return 0 }
    return min(1800, 60 * pow(2, Double(min(count - 1, 5))))
  }
}

/// Merges the permanent bili-history base with Bilibili's live history. The two sources can
/// disagree because bili-history only crawls once an hour; the more recent viewing wins.
public enum WatchHistoryMerge {
  public static func choose(_ current: WatchRecord?, _ incoming: WatchRecord) -> WatchRecord {
    guard let current else { return incoming }
    if incoming.viewAt != current.viewAt { return incoming.viewAt > current.viewAt ? incoming : current }
    // Same second: a completed play and the furthest progress are the safer display.
    if incoming.finished != current.finished { return incoming.finished ? incoming : current }
    return incoming.progress >= current.progress ? incoming : current
  }
}

/// Converts one page of the official history into the same compact state used by covers.
/// Only ordinary videos carry a bvid — the only key bili-history understands.
public enum OfficialWatchHistory {
  public static func records(from page: RPCHistoryPage) -> [String: WatchRecord] {
    var result: [String: WatchRecord] = [:]
    for item in page.items {
      guard case .video(let card, let progress) = item.content, !card.bvid.isEmpty else { continue }
      let duration = max(0, Int(card.duration))
      let finished = progress < 0 || (duration > 0 && progress >= Int64(duration))
      let seconds = progress < 0 ? duration : max(0, Int(progress))
      result[card.bvid] = WatchRecord(bvid: card.bvid, watched: true, progress: seconds,
        duration: duration, finished: finished, viewAt: item.viewedAt)
    }
    return result
  }
}

/// Disk cache for the viewing states. Plain JSON under Application Support: no credential,
/// shared only within one app variant (release / debug / tests). Every entry the app has ever
/// seen is kept — 5000 entries are under 1 MB, and dropping old ones would lose exactly the
/// permanent history bili-history exists to preserve.
public enum WatchHistoryCache {
  public static func fileURL() -> URL? { cacheFileURL("watch-history") }
  public static func outboxFileURL() -> URL? { cacheFileURL("watch-history-outbox") }

  static func cacheFileURL(_ name: String, variant: String? = LocalSecretVault.appVariant) -> URL? {
    guard let variant else { return nil } // tests and tools: memory only
    return AppIdentity.applicationSupportDirectory.appendingPathComponent("\(name)-guest\(variant).json")
  }

  public static func load(from url: URL) -> [String: WatchRecord] {
    guard let data = try? Data(contentsOf: url),
      let decoded = try? JSONDecoder().decode([String: WatchRecord].self, from: data) else { return [:] }
    return decoded
  }

  @discardableResult public static func save(_ records: [String: WatchRecord], to url: URL) -> [String: WatchRecord] {
    guard let data = try? JSONEncoder().encode(records) else { return records }
    let folder = url.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try? data.write(to: url, options: .atomic)
    return records
  }
}
