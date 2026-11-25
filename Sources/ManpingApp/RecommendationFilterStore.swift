import Combine
import Foundation
import ManpingCore

@MainActor final class RecommendationFilterStore: ObservableObject {
  enum AddResult: Equatable {
    case added, duplicate, invalid, persistenceFailed
    var succeeded: Bool { self == .added }
  }

  static let shared = RecommendationFilterStore()
  static let key = "Manping.recommendationFilter"

  @Published private(set) var filter = RecommendationFilter()
  /// Session-only undo state; the hidden record itself is persisted in `filter`.
  @Published private(set) var lastHide: RecommendationHiddenVideo?
  private let defaults: any PreferencesStore

  init(defaults: any PreferencesStore? = nil) {
    self.defaults = defaults ?? PerformanceEnvironment.defaults
    if let data = self.defaults.data(forKey: Self.key),
      let stored = try? JSONDecoder().decode(RecommendationFilter.self, from: data) {
      filter = stored
    }
  }

  func add(_ rule: RecommendationFilterRule) -> AddResult {
    var next = filter
    guard rule.valueID > 0, !rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .invalid }
    guard !next.contains(rule.kind, valueID: rule.valueID) else { return .duplicate }
    guard next.add(rule) else { return .invalid }
    let previous = filter
    filter = next
    guard save() else { filter = previous; return .persistenceFailed }
    return .added
  }

  func add(video: Video, kind: RecommendationRuleKind) -> AddResult {
    let name: String
    let id: Int64?
    switch kind {
    case .primaryPartition:
      name = video.partitionName ?? ""
      id = video.partitionID.map(Int64.init)
    case .subpartition:
      name = video.subpartitionName ?? ""
      id = video.subpartitionID.map(Int64.init)
    case .author:
      name = video.author
      id = video.authorID
    }
    guard let id, id > 0, !name.isEmpty else { return .invalid }
    return add(RecommendationFilterRule(kind: kind, valueID: id, name: name))
  }

  func remove(id: UUID) {
    var next = filter
    next.remove(id: id)
    guard next != filter else { return }
    let previous = filter
    filter = next
    if !save() { filter = previous }
  }

  @discardableResult
  func hide(video: Video) -> Bool {
    var next = filter
    guard next.hide(video) else { return false }
    let previous = filter
    let previousUndo = lastHide
    filter = next
    lastHide = next.hiddenVideos.last
    guard save() else {
      filter = previous
      lastHide = previousUndo
      return false
    }
    return true
  }

  @discardableResult
  func undoLastHide() -> Bool {
    guard let lastHide else { return false }
    var next = filter
    guard next.removeHiddenVideo(id: lastHide.id) else { return false }
    let previous = filter
    filter = next
    self.lastHide = nil
    guard save() else {
      filter = previous
      self.lastHide = lastHide
      return false
    }
    return true
  }

  @discardableResult
  func clearVideoFeedback() -> Bool {
    guard !filter.hiddenVideos.isEmpty || lastHide != nil else { return true }
    var next = filter
    next.clearVideoFeedback()
    let previous = filter
    let previousUndo = lastHide
    filter = next
    lastHide = nil
    guard save() else {
      filter = previous
      lastHide = previousUndo
      return false
    }
    return true
  }

  func filters(_ video: Video) -> Bool { filter.filters(video) }

  func visibleRecommendations(_ videos: [Video]) -> [Video] {
    videos.filter { !filters($0) }
  }

  @discardableResult
  private func save() -> Bool {
    guard let data = try? JSONEncoder().encode(filter) else { return false }
    defaults.set(data, forKey: Self.key)
    return defaults.data(forKey: Self.key) == data
  }
}
