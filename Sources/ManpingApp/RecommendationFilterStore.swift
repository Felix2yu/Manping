import Combine
import Foundation
import ManpingCore

@MainActor final class RecommendationFilterStore: ObservableObject {
  static let shared = RecommendationFilterStore()
  static let key = "Manping.recommendationFilter"

  @Published private(set) var filter = RecommendationFilter()
  private let defaults: any PreferencesStore

  init(defaults: any PreferencesStore? = nil) {
    self.defaults = defaults ?? PerformanceEnvironment.defaults
    if let data = self.defaults.data(forKey: Self.key),
      let stored = try? JSONDecoder().decode(RecommendationFilter.self, from: data) {
      filter = stored
    }
  }

  func add(_ rule: RecommendationFilterRule) -> Bool {
    var next = filter
    guard next.add(rule) else { return false }
    filter = next
    save()
    return true
  }

  func add(video: Video, kind: RecommendationRuleKind) -> Bool {
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
    guard let id, id > 0, !name.isEmpty else { return false }
    return add(RecommendationFilterRule(kind: kind, valueID: id, name: name))
  }

  func remove(id: UUID) {
    var next = filter
    next.remove(id: id)
    guard next != filter else { return }
    filter = next
    save()
  }

  func filters(_ video: Video) -> Bool { filter.filters(video) }

  private func save() {
    if let data = try? JSONEncoder().encode(filter) { defaults.set(data, forKey: Self.key) }
  }
}
