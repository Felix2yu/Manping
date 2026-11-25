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
  public let mainCategory: String?
  public let subCategory: String?

  public init(bvid: String, title: String, cover: String, author: String, authorMID: Int64,
    duration: Int, progress: Int, viewAt: Int64, finished: Bool, business: String? = nil,
    mainCategory: String? = nil, subCategory: String? = nil)
  {
    self.bvid = bvid
    self.title = title
    self.cover = cover
    self.author = author
    self.authorMID = authorMID
    self.duration = duration
    self.progress = progress
    self.viewAt = viewAt
    self.finished = finished
    self.business = business
    self.mainCategory = mainCategory
    self.subCategory = subCategory
  }

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

  /// A `Video` for the shared card view. Statistics stay empty rather than being
  /// invented; partition names come from the archive when it has them.
  public var video: Video {
    Video(
      bvid: bvid, title: title, cover: URL(string: cover), author: author,
      duration: duration, aid: nil, authorID: authorMID > 0 ? authorMID : nil,
      partitionName: mainCategory, subpartitionName: subCategory)
  }

  enum CodingKeys: String, CodingKey {
    case bvid, title, cover, author, duration, progress, finished, business
    case authorMID = "author_mid"
    case viewAt = "view_at"
    case mainCategory = "main_category"
    case subCategory = "sub_category"
  }
}

public struct ArchiveHistoryFilter: Equatable, Sendable {
  public var mainCategory = ""
  public var subCategory = ""
  public var duration = ArchiveDurationFilter.all

  public init() {}

  public var isEmpty: Bool { mainCategory.isEmpty && subCategory.isEmpty && duration == .all }
  public var activeCount: Int { (mainCategory.isEmpty ? 0 : 1) + (duration == .all ? 0 : 1) }
}

public enum ArchiveDurationFilter: String, CaseIterable, Identifiable, Sendable {
  case all
  case upTo5Minutes
  case fiveToTwentyMinutes
  case twentyToSixtyMinutes
  case overSixtyMinutes

  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .all: "全部时长"
    case .upTo5Minutes: "5 分钟内"
    case .fiveToTwentyMinutes: "5–20 分钟"
    case .twentyToSixtyMinutes: "20–60 分钟"
    case .overSixtyMinutes: "60 分钟以上"
    }
  }
  public var minimumSeconds: Int? {
    switch self {
    case .all: nil
    case .upTo5Minutes: 1
    case .fiveToTwentyMinutes: 301
    case .twentyToSixtyMinutes: 1201
    case .overSixtyMinutes: 3601
    }
  }
  public var maximumSeconds: Int? {
    switch self {
    case .all, .overSixtyMinutes: nil
    case .upTo5Minutes: 300
    case .fiveToTwentyMinutes: 1200
    case .twentyToSixtyMinutes: 3600
    }
  }
  func contains(_ duration: Int) -> Bool {
    guard duration > 0 else { return self == .all }
    return (minimumSeconds.map { duration >= $0 } ?? true)
      && (maximumSeconds.map { duration <= $0 } ?? true)
  }
}

public struct ArchiveCategory: Decodable, Identifiable, Equatable, Sendable {
  public let name: String
  public let subCategories: [ArchiveSubcategory]

  public var id: String { name }
  enum CodingKeys: String, CodingKey { case name, subCategories = "sub_categories" }
}

public struct ArchiveSubcategory: Decodable, Identifiable, Equatable, Sendable {
  public let name: String
  public let tid: Int
  public var id: String { name }

  enum CodingKeys: String, CodingKey { case name, tid }
}

public struct ArchivePage: Decodable, Equatable, Sendable {
  public let records: [ArchiveVideo]
  /// The cursor for the next page; 0 means the archive has no more rows.
  public let next: Int64
  /// Older servers omit capability metadata; filters stay disabled until a page
  /// explicitly confirms that the server understands them.
  public let supportsFiltering: Bool?

  public init(records: [ArchiveVideo] = [], next: Int64 = 0, supportsFiltering: Bool? = nil) {
    self.records = records
    self.next = next
    self.supportsFiltering = supportsFiltering
  }

  enum CodingKeys: String, CodingKey { case records, next, supportsFiltering = "supports_filtering" }
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
  public let mainCategory: String?
  public let subCategory: String?

  public var id: String { bvid }
  public var video: Video {
    Video(
      bvid: bvid, title: title, cover: URL(string: cover), author: author,
      duration: duration, views: view, partitionName: mainCategory, subpartitionName: subCategory)
  }

  enum CodingKeys: String, CodingKey {
    case bvid, title, cover, author, duration, view
    case addAt = "add_at"
    case mainCategory = "main_category"
    case subCategory = "sub_category"
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
