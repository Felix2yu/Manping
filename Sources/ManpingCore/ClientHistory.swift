import Foundation

/// The wire contract of bili-history's client channel (`/api/client/*`). These
/// types mirror `internal/models/client.go`; the archive is a server-side copy of
/// what the account has already watched, so nothing here is editable — 满屏 only
/// reads it and writes play positions through the existing `/watch-progress`
/// channel.
public struct ArchiveVideo: Decodable, Identifiable, Equatable, Sendable {
  public let bvid: String
  public let title: String
  public let cover: String
  public let author: String
  public let authorMID: Int64
  public let duration: Int
  public let progress: Int
  public let viewAt: Int64
  public let finished: Bool
  public let business: String?

  public var id: String { bvid + "-\(viewAt)" }
  /// Fraction drawn under a cover; a finished play fills the bar.
  public var fraction: Double {
    if finished { return 1 }
    guard duration > 0, progress > 0 else { return 0 }
    return min(1, Double(progress) / Double(duration))
  }

  /// Only ordinary videos can be opened by bvid; live replays and articles carry
  /// ids this client does not resolve.
  public var isPlayable: Bool {
    let kind = business ?? ""
    return !bvid.isEmpty && !["live", "article", "article-list"].contains(kind)
  }

  /// A `Video` for the shared card view. The archive has no stats or partition,
  /// so those stay empty rather than being invented.
  public var video: Video {
    Video(
      bvid: bvid, title: title, cover: URL(string: cover), author: author,
      duration: duration, aid: nil, authorID: authorMID > 0 ? authorMID : nil)
  }

  enum CodingKeys: String, CodingKey {
    case bvid, title, cover, author, duration, progress, finished, business
    case authorMID = "author_mid"
    case viewAt = "view_at"
  }
}

public struct ArchivePage: Decodable, Equatable, Sendable {
  public let records: [ArchiveVideo]
  /// The cursor for the next page; 0 means the archive has no more rows.
  public let next: Int64

  public init(records: [ArchiveVideo] = [], next: Int64 = 0) {
    self.records = records
    self.next = next
  }
}

/// The one-line summary above the archive list. `seconds` is the sum of the
/// videos' lengths, matching the web monthly report — it is not time spent.
public struct ArchiveSummary: Decodable, Equatable, Sendable {
  public let year: Int
  public let month: Int
  public let videos: Int
  public let seconds: Int64
  public let uniqueAuthors: Int
  public let uniqueDays: Int
  public let finished: Int
  public let finishedRate: Double
  public let lateNightRatio: Double

  enum CodingKeys: String, CodingKey {
    case year, month, videos, seconds, finished
    case uniqueAuthors = "unique_authors"
    case uniqueDays = "unique_days"
    case finishedRate = "finished_rate"
    case lateNightRatio = "late_night_ratio"
  }
}

public struct ArchiveWatchLaterItem: Decodable, Identifiable, Equatable, Sendable {
  public let bvid: String
  public let title: String
  public let cover: String
  public let author: String
  public let duration: Int
  public let addAt: Int64
  public let view: Int

  public var id: String { bvid }
  public var video: Video {
    Video(bvid: bvid, title: title, cover: URL(string: cover), author: author, duration: duration, views: view)
  }

  enum CodingKeys: String, CodingKey {
    case bvid, title, cover, author, duration, view
    case addAt = "add_at"
  }
}

public struct ArchiveFavoriteFolder: Decodable, Identifiable, Equatable, Sendable {
  public let mediaID: Int64
  public let title: String
  public let cover: String
  public let mediaCount: Int
  public let mtime: Int64

  public var id: Int64 { mediaID }

  enum CodingKeys: String, CodingKey {
    case title, cover, mtime
    case mediaID = "media_id"
    case mediaCount = "media_count"
  }
}

public struct ArchiveFavoriteItem: Decodable, Identifiable, Equatable, Sendable {
  public let bvid: String
  public let title: String
  public let cover: String
  public let author: String
  public let authorMID: Int64
  public let duration: Int
  public let favTime: Int64

  public var id: String { bvid.isEmpty ? "fav-\(favTime)-\(title)" : bvid }
  public var video: Video {
    Video(
      bvid: bvid, title: title, cover: URL(string: cover), author: author,
      duration: duration, authorID: authorMID > 0 ? authorMID : nil)
  }

  enum CodingKeys: String, CodingKey {
    case bvid, title, cover, author, duration
    case authorMID = "author_mid"
    case favTime = "fav_time"
  }
}

public extension BiliHistoryConfig {
  /// The client channel lives beside `/api/watch-progress` on the same host.
  static func clientEndpoint(_ base: String, path: String) -> URL? {
    guard let base = normalizedBaseURL(base), !base.isEmpty else { return nil }
    return URL(string: base + "/api/client/" + path)
  }
}
