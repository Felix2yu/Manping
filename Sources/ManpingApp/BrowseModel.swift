import ManpingCore
import SwiftUI

struct BrowseFeedState {
  var items: [Video] = []
  var nextCursor: String?
  var isLoading = false
  var hasMore = true
  var error: String?
  var consecutiveEmptyPages = 0
}

/// Keeps each section's cursor while rejecting responses from a previous selection.
@MainActor final class BrowseFeedModel: ObservableObject {
  typealias Loader = (String?) async throws -> BrowseVideoPage

  @Published private(set) var state = BrowseFeedState()
  private var states: [String: BrowseFeedState] = [:]
  private var refreshTokens: [String: Int] = [:]
  private var key: String?
  private var loader: Loader?
  private var request: Task<Void, Never>?
  private var identityTask: Task<Void, Never>?
  private var identity: AuthIdentityEvent?
  private var generation = UUID()
  private final class WeakFeed {
    weak var value: BrowseFeedModel?
    init(_ value: BrowseFeedModel) { self.value = value }
  }
  private static var diagnosticFeeds: [WeakFeed] = []
  init(service: BiliService) {
    if PerformanceOptions.requested { Self.diagnosticFeeds.append(WeakFeed(self)) }
    identityTask = Task { [weak self, service] in
      for await event in await service.identityEvents() {
        guard let self, !Task.isCancelled else { return }
        let previous = self.identity; self.identity = event
        let changed = previous.map { $0.epoch != event.epoch || $0.identityRevision != event.identityRevision }
          ?? (self.key != nil)
        if changed {
          self.states = [:]; self.refreshTokens = [:]
          self.reset()
        }
      }
    }
  }
  deinit { identityTask?.cancel(); request?.cancel() }
  static var diagnosticLiveCount: Int {
    diagnosticFeeds.removeAll { $0.value == nil }
    return diagnosticFeeds.count
  }

  func activate(key newKey: String, refreshToken: Int, loader newLoader: @escaping Loader) {
    if key != newKey {
      cancel()
      if let key { states[key] = state }
      key = newKey
      state = states[newKey] ?? BrowseFeedState()
    }
    loader = newLoader
    if refreshTokens[newKey] != refreshToken {
      refreshTokens[newKey] = refreshToken
      reset()
    } else if state.items.isEmpty && state.error == nil && state.hasMore {
      loadNext()
    }
  }

  func refresh() {
    reset()
  }

  func remove(videoID: String) {
    guard let key else { return }
    state.items.removeAll { $0.id == videoID }
    states[key] = state
  }

  func cancel() {
    generation = UUID()
    request?.cancel()
    request = nil
    state.isLoading = false
  }
  /// A disappearing view must release its saved request closure as well as its task.
  /// reset() still uses cancel() so refreshing keeps the active loader.
  func deactivate() {
    cancel()
    loader = nil
  }

  func loadNext() {
    guard !state.isLoading, state.hasMore, let key, let loader else { return }
    let revision = generation
    let cursor = state.nextCursor
    state.isLoading = true
    state.error = nil
    request = Task { @MainActor [weak self] in
      do {
        let page = try await loader(cursor)
        try Task.checkCancellation()
        guard let self, self.generation == revision, self.key == key else { return }
        var known = Set(self.state.items.map(\.id))
        let additions = page.items.filter { known.insert($0.id).inserted }
        self.state.items.append(contentsOf: additions)
        self.state.consecutiveEmptyPages = additions.isEmpty ? self.state.consecutiveEmptyPages + 1 : 0
        let next = page.nextCursor?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.state.nextCursor = next
        self.state.hasMore = next != nil && next != "" && next != cursor
        if self.state.hasMore && self.state.consecutiveEmptyPages >= 3 {
          self.state.error = "连续分页没有返回新视频，可重试继续加载。"
          self.state.consecutiveEmptyPages = 0
        }
      } catch is CancellationError {
      } catch {
        guard let self, self.generation == revision, self.key == key else { return }
        self.state.error = error.localizedDescription
      }
      guard let self, self.generation == revision, self.key == key else { return }
      self.state.isLoading = false
      self.request = nil
      self.states[key] = self.state
      if self.state.items.isEmpty && self.state.hasMore && self.state.error == nil {
        self.loadNext()
      }
    }
  }

  private func reset() {
    cancel()
    state = BrowseFeedState()
    if let key { states[key] = state }
    loadNext()
  }
}

@MainActor final class BrowsePartitionDirectory: ObservableObject {
  @Published private(set) var partitions: [VideoPartition] = []
  @Published private(set) var isLoading = false
  @Published private(set) var error: String?
  private var loaded = false
  private var request: Task<Void, Never>?
  private var generation = UUID()

  func loadIfNeeded(service: BiliService) {
    guard !loaded, !isLoading else { return }
    load(service: service)
  }

  func load(service: BiliService) {
    cancel()
    let revision = generation
    isLoading = true
    error = nil
    request = Task { @MainActor [weak self] in
      do {
        let result = try await service.videoPartitions()
        try Task.checkCancellation()
        guard let self, self.generation == revision else { return }
        self.partitions = result
        self.loaded = true
      } catch is CancellationError {
      } catch {
        guard let self, self.generation == revision else { return }
        self.error = error.localizedDescription
      }
      guard let self, self.generation == revision else { return }
      self.isLoading = false
      self.request = nil
    }
  }

  func cancel() {
    generation = UUID()
    request?.cancel()
    request = nil
    isLoading = false
  }
}

/// Search and other filters share the partition browser's directory and visual language.
struct VideoPartitionMenu: View {
  let service: BiliService
  @Binding var tid: Int
  @StateObject private var directory = BrowsePartitionDirectory()
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    Menu {
      Button { tid = 0 } label: { Label("全部分区", systemImage: "rectangle.grid.2x2") }
      if directory.isLoading && directory.partitions.isEmpty {
        Text("正在加载分区…")
      }
      ForEach(directory.partitions, id: \.id) { parent in
        if parent.children.isEmpty {
          partitionButton(parent)
        } else {
          Menu {
            partitionButton(parent)
            Divider()
            ForEach(parent.children, id: \.id) { child in partitionButton(child) }
          } label: { partitionLabel(parent) }
        }
      }
      if let error = directory.error {
        Divider()
        Text("没能加载分区：\(error)").foregroundStyle(Theme.danger(scheme))
        Button("重试") { directory.load(service: service) }
      }
    } label: {
      if let selected = partition(id: tid, in: directory.partitions) {
        HStack(spacing: 6) {
          PartitionSymbol(partition: selected); Text(selected.title)
          Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).opacity(0.7)
        }
      } else {
        MenuLabel(title: tid > 0 ? "分区 \(tid)" : "全部分区", symbol: "rectangle.grid.2x2")
      }
    }.appMenuStyle()
      .accessibilityLabel("视频分区")
      .task { directory.loadIfNeeded(service: service) }
      .onDisappear { directory.cancel() }
  }

  private func partitionButton(_ partition: VideoPartition) -> some View {
    Button { tid = partition.id } label: {
      HStack(spacing: 6) {
        PartitionSymbol(partition: partition)
        Text(partition.title)
        if tid == partition.id { Spacer(); Image(systemName: "checkmark") }
      }
    }
  }
  private func partitionLabel(_ partition: VideoPartition) -> some View {
    HStack(spacing: 6) { PartitionSymbol(partition: partition); Text(partition.title) }
  }
  private func partition(id: Int, in partitions: [VideoPartition]) -> VideoPartition? {
    for partition in partitions {
      if partition.id == id { return partition }
      if let child = self.partition(id: id, in: partition.children) { return child }
    }
    return nil
  }
}
