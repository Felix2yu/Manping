import Foundation

public enum RecommendationRuleKind: String, CaseIterable, Codable, Sendable {
  case primaryPartition
  case subpartition
  case author

  public var title: String {
    switch self {
    case .primaryPartition: "一级分区"
    case .subpartition: "二级分区"
    case .author: "UP 主"
    }
  }
}

public struct RecommendationFilterRule: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public let kind: RecommendationRuleKind
  public let valueID: Int64
  public let name: String

  public init(id: UUID = UUID(), kind: RecommendationRuleKind, valueID: Int64, name: String) {
    self.id = id
    self.kind = kind
    self.valueID = valueID
    self.name = name
  }
}

/// A locally hidden recommendation. Its identity prefers BV and falls back to av for feeds that
/// do not provide a BV identifier; the title is only for display in settings.
public struct RecommendationHiddenVideo: Identifiable, Codable, Equatable, Sendable {
  public let bvid: String
  public let aid: Int64?
  public let title: String

  public init(bvid: String, aid: Int64?, title: String) {
    self.bvid = bvid
    self.aid = aid
    self.title = title
  }

  public init(video: Video) {
    self.init(bvid: video.bvid.trimmingCharacters(in: .whitespacesAndNewlines),
      aid: video.aid.flatMap { $0 > 0 ? $0 : nil }, title: video.title)
  }

  public var id: String { Self.identity(bvid: bvid, aid: aid) ?? "" }

  public static func identity(bvid: String, aid: Int64?) -> String? {
    let bvid = bvid.trimmingCharacters(in: .whitespacesAndNewlines)
    if !bvid.isEmpty { return "bvid:\(bvid)" }
    guard let aid, aid > 0 else { return nil }
    return "av:\(aid)"
  }
}

/// Local recommendation rules. They only hide matching rows from 首页推荐; the server's
/// recommendation cursor is untouched so filtered pages still advance normally.
public struct RecommendationFilter: Codable, Equatable, Sendable {
  public private(set) var rules: [RecommendationFilterRule] = []
  public private(set) var hiddenVideos: [RecommendationHiddenVideo] = []

  public init() {}

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init()
    for rule in try container.decodeIfPresent([RecommendationFilterRule].self, forKey: .rules) ?? [] { add(rule) }
    // Missing in filters written before single-video feedback existed. Invalid and duplicate
    // records are dropped just like duplicate/invalid rules.
    for video in try container.decodeIfPresent([RecommendationHiddenVideo].self, forKey: .hiddenVideos) ?? [] {
      _ = addHidden(video)
    }
  }

  public func filters(_ video: Video) -> Bool {
    if hides(video) { return true }
    return rules.contains { rule in
      switch rule.kind {
      case .primaryPartition: video.partitionID.map { Int64($0) == rule.valueID } == true
      case .subpartition:
        video.subpartitionID.map { Int64($0) == rule.valueID } == true
          || (video.subpartitionID == nil && video.partitionID.map { Int64($0) == rule.valueID } == true)
      case .author: video.authorID == rule.valueID
      }
    }
  }

  public func hides(_ video: Video) -> Bool {
    guard let identity = RecommendationHiddenVideo.identity(bvid: video.bvid, aid: video.aid) else { return false }
    return hiddenVideos.contains { $0.id == identity }
  }

  public func contains(_ kind: RecommendationRuleKind, valueID: Int64) -> Bool {
    rules.contains { $0.kind == kind && $0.valueID == valueID }
  }

  @discardableResult
  public mutating func add(_ rule: RecommendationFilterRule) -> Bool {
    guard rule.valueID > 0, !rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !contains(rule.kind, valueID: rule.valueID) else { return false }
    rules.append(rule)
    return true
  }

  public mutating func remove(id: UUID) {
    rules.removeAll { $0.id == id }
  }

  public mutating func removeAll() {
    rules.removeAll()
  }

  @discardableResult
  public mutating func hide(_ video: Video) -> Bool {
    addHidden(RecommendationHiddenVideo(video: video))
  }

  private mutating func addHidden(_ video: RecommendationHiddenVideo) -> Bool {
    guard !video.id.isEmpty, !hiddenVideos.contains(where: { $0.id == video.id }) else { return false }
    hiddenVideos.append(video)
    return true
  }

  @discardableResult
  public mutating func removeHiddenVideo(id: String) -> Bool {
    let previousCount = hiddenVideos.count
    hiddenVideos.removeAll { $0.id == id }
    return hiddenVideos.count != previousCount
  }

  public mutating func clearVideoFeedback() {
    hiddenVideos.removeAll()
  }
}
