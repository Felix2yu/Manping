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

/// Local recommendation rules. They only hide matching rows from 首页推荐; the server's
/// recommendation cursor is untouched so filtered pages still advance normally.
public struct RecommendationFilter: Codable, Equatable, Sendable {
  public private(set) var rules: [RecommendationFilterRule] = []

  public init() {}

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init()
    for rule in try container.decode([RecommendationFilterRule].self, forKey: .rules) { add(rule) }
  }

  public func filters(_ video: Video) -> Bool {
    rules.contains { rule in
      switch rule.kind {
      case .primaryPartition: video.partitionID.map { Int64($0) == rule.valueID } == true
      case .subpartition:
        video.subpartitionID.map { Int64($0) == rule.valueID } == true
          || (video.subpartitionID == nil && video.partitionID.map { Int64($0) == rule.valueID } == true)
      case .author: video.authorID == rule.valueID
      }
    }
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
}
