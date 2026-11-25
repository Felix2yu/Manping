import Foundation
import ManpingCore
import SwiftUI

/// The 归档 source of the history page: what bili-history kept after Bilibili's
/// own list scrolled away. Everything here is read-only — the account list stays
/// the place where history is deleted, and this view never pretends otherwise.
@MainActor final class ArchiveBrowserModel: ObservableObject {
  enum Segment: String, CaseIterable, Identifiable {
    case history = "历史"
    case later = "稍后再看"
    case favorites = "收藏"
    var id: String { rawValue }
  }

  @Published var segment: Segment = .history
  /// Rows still on their way to the last page of 继续观看. Loaded once per launch
  /// because a "resume" strip that reorders itself mid-scroll is disorienting.
  @Published private(set) var recent: [ArchiveVideo] = []
  @Published private(set) var summary: ArchiveSummary?
  @Published private(set) var history: [ArchiveVideo] = []
  @Published private(set) var later: [ArchiveWatchLaterItem] = []
  @Published private(set) var folders: [ArchiveFavoriteFolder] = []
  @Published private(set) var favoriteContents: [ArchiveFavoriteItem] = []
  @Published private(set) var selectedFolder: ArchiveFavoriteFolder?
  /// bvids the archive has marked as deleted; only ever filled from the server's
  /// cache, never from a guess.
  @Published private(set) var deleted: Set<String> = []
  @Published private(set) var isLoading = false
  @Published private(set) var error: String?
  @Published private(set) var hasMore = false
  @Published private(set) var laterHasMore = false
  @Published private(set) var contentsHaveMore = false
  /// Archive rows 满屏 cannot open (直播、专栏): the ids in those rows are not a
  /// bvid, so they are counted for an honest footnote instead of being shown as
  /// cards that do nothing when clicked.
  @Published private(set) var hiddenNonVideo = 0
  @Published var filter = ArchiveHistoryFilter()
  @Published var laterFilter = ArchiveHistoryFilter()
  @Published private(set) var keyword = ""
  @Published private(set) var categories: [ArchiveCategory] = []
  @Published private(set) var categoryError: String?
  @Published private(set) var supportsFiltering = false
  @Published private(set) var laterSupportsFiltering = false

  private let service: ClientHistoryService?
  private var historyCursor: Int64 = 0
  private var historyGeneration = UUID()
  private var laterGeneration = UUID()
  private var laterPage = 0
  private var contentsPage = 0
  private var statusAsked: Set<String> = []
  private var loadedOverview = false

  /// Nil service means the user never filled in a bili-history address: every
  /// load becomes a no-op instead of an error banner.
  init(service: ClientHistoryService?) {
    self.service = service
  }

  func isDeleted(_ bvid: String) -> Bool { !bvid.isEmpty && deleted.contains(bvid) }

  /// True while another page is waiting for the current segment.
  var canLoadMore: Bool {
    switch segment {
    case .history: hasMore
    case .later: laterHasMore
    case .favorites: selectedFolder != nil && contentsHaveMore
    }
  }

  var hasCriteria: Bool { !keyword.isEmpty || !filter.isEmpty }
  var laterHasCriteria: Bool { !laterFilter.isEmpty }

  /// One section per day, newest first, in the same shape the account list uses.
  struct HistorySection: Identifiable {
    let id: Int64
    let title: String
    let items: [ArchiveVideo]
  }
  var historySections: [HistorySection] {
    var order: [Int64] = []
    var grouped: [Int64: [ArchiveVideo]] = [:]
    for item in history {
      let day = Calendar(identifier: .gregorian).startOfDay(for: Date(timeIntervalSince1970: TimeInterval(item.viewAt))).timeIntervalSince1970
      let key = Int64(day)
      if grouped[key] == nil { order.append(key) }
      grouped[key, default: []].append(item)
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "M月d日 EEEE"
    return order.map { key in
      HistorySection(id: key, title: formatter.string(from: Date(timeIntervalSince1970: TimeInterval(key))),
        items: grouped[key] ?? [])
    }
  }

  func search(keyword: String) async {
    self.keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    await loadHistory(reset: true)
  }

  func setFilter(_ filter: ArchiveHistoryFilter, segment: Segment = .history) async {
    switch segment {
    case .history:
      guard self.filter != filter else { return }
      self.filter = filter
      await loadHistory(reset: true)
    case .later:
      guard laterFilter != filter else { return }
      laterFilter = filter
      await loadLater(reset: true)
    case .favorites:
      break
    }
  }

  /// 继续观看 and the summary are independent requests; a failure in one must not
  /// blank the other.
  func loadOverview() async {
    guard let service, !loadedOverview else { return }
    loadedOverview = true
    let month = Calendar(identifier: .gregorian).component(.month, from: Date())
    let year = Calendar(identifier: .gregorian).component(.year, from: Date())
    async let recentTask = service.recent(limit: 30)
    async let summaryTask = service.summary(year: year, month: month)
    async let categoriesTask = service.categories()
    do { recent = try await recentTask } catch { recent = [] }
    do { summary = try await summaryTask } catch { summary = nil }
    do {
      let loaded = try await categoriesTask
      categories = loaded.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
      categoryError = nil
    }
    catch { categoryError = error.localizedDescription }
  }

  func loadCategories() async {
    guard let service else { return }
    do {
      categories = try await service.categories().sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
      categoryError = nil
    } catch {
      categoryError = error.localizedDescription
    }
  }

  func refresh() async {
    loadedOverview = false
    history = []
    later = []
    folders = []
    favoriteContents = []
    selectedFolder = nil
    deleted = []
    statusAsked = []
    historyCursor = 0
    laterPage = 0
    contentsPage = 0
    hasMore = false
    laterHasMore = false
    contentsHaveMore = false
    hiddenNonVideo = 0
    historyGeneration = UUID()
    laterGeneration = UUID()
    error = nil
    await loadOverview()
    await load(segment: segment, reset: true)
  }

  func load(segment: Segment, reset: Bool = false) async {
    guard let service else { return }
    self.segment = segment
    if segment == .history {
      laterGeneration = UUID()
      await loadHistory(reset: reset)
      return
    }
    if segment == .later {
      historyGeneration = UUID()
      await loadLater(reset: reset)
      return
    }
    historyGeneration = UUID()
    laterGeneration = UUID()
    isLoading = true
    error = nil
    defer { isLoading = false }
    do {
      switch segment {
      case .history, .later: break
      case .favorites:
        if reset {
          folders = try await service.favorites()
          favoriteContents = []
          selectedFolder = nil
          contentsPage = 0
          contentsHaveMore = false
        }
      }
    } catch {
      self.error = error.localizedDescription
    }
  }

  private func loadHistory(reset: Bool) async {
    guard let service else { return }
    if reset {
      historyGeneration = UUID()
      history = []
      historyCursor = 0
      hiddenNonVideo = 0
      hasMore = false
    }
    if !reset, isLoading { return }
    let generation = historyGeneration
    let requestedFilter = filter
    let requestedKeyword = keyword
    isLoading = true
    error = nil
    defer { if historyGeneration == generation { isLoading = false } }
    do {
      let page = try await service.history(cursor: historyCursor, limit: 40,
        keyword: requestedKeyword, filter: requestedFilter)
      try Task.checkCancellation()
      guard historyGeneration == generation else { return }
      supportsFiltering = page.supportsFiltering == true
      let playable = page.records.filter(\.isPlayable)
      hiddenNonVideo += page.records.count - playable.count
      history.append(contentsOf: playable)
      historyCursor = page.next
      hasMore = page.next != 0
      await resolveStatus(playable.map(\.bvid))
    } catch is CancellationError {
    } catch {
      guard historyGeneration == generation else { return }
      self.error = error.localizedDescription
    }
  }

  private func loadLater(reset: Bool) async {
    guard let service else { return }
    if reset {
      laterGeneration = UUID()
      later = []
      laterPage = 0
      laterHasMore = false
    }
    if !reset, isLoading { return }
    let generation = laterGeneration
    let requestedFilter = laterFilter
    isLoading = true
    error = nil
    defer { if laterGeneration == generation { isLoading = false } }
    do {
      let page = try await service.watchLater(page: laterPage + 1, size: 40, filter: requestedFilter)
      try Task.checkCancellation()
      guard laterGeneration == generation else { return }
      laterSupportsFiltering = page.supportsFiltering == true
      later.append(contentsOf: page.records)
      laterPage += 1
      laterHasMore = later.count < page.total && !page.records.isEmpty
      await resolveStatus(page.records.map(\.bvid))
    } catch is CancellationError {
    } catch {
      guard laterGeneration == generation else { return }
      self.error = error.localizedDescription
    }
  }

  func open(_ folder: ArchiveFavoriteFolder) async {
    guard let service else { return }
    selectedFolder = folder
    favoriteContents = []
    contentsPage = 0
    contentsHaveMore = false
    isLoading = true
    error = nil
    defer { isLoading = false }
    do {
      let page = try await service.favoriteContents(mediaID: folder.mediaID, page: 1, size: 40)
      favoriteContents = page.records
      contentsPage = 1
      contentsHaveMore = favoriteContents.count < page.total && !page.records.isEmpty
      await resolveStatus(page.records.map(\.bvid))
    } catch {
      self.error = error.localizedDescription
    }
  }

  func closeFolder() {
    selectedFolder = nil
    favoriteContents = []
    error = nil
  }

  func loadMore() async {
    guard let service, !isLoading else { return }
    switch segment {
    case .history where hasMore:
      await loadHistory(reset: false)
    case .later where laterHasMore:
      await loadLater(reset: false)
    case .favorites where contentsHaveMore:
      guard let folder = selectedFolder else { break }
      isLoading = true
      defer { isLoading = false }
      do {
        let page = try await service.favoriteContents(mediaID: folder.mediaID, page: contentsPage + 1, size: 40)
        favoriteContents.append(contentsOf: page.records)
        contentsPage += 1
        contentsHaveMore = favoriteContents.count < page.total && !page.records.isEmpty
        await resolveStatus(page.records.map(\.bvid))
      } catch { self.error = error.localizedDescription }
    default:
      break
    }
  }

  /// One batched status request per screenful of new bvids. A failure leaves the
  /// badges off; a missing badge is honest, a wrong one is not.
  private func resolveStatus(_ bvids: [String]) async {
    guard let service else { return }
    let unknown = bvids.filter { !$0.isEmpty && !statusAsked.contains($0) }
    guard !unknown.isEmpty else { return }
    guard let found = try? await service.deletedVideos(unknown) else { return }
    // Only after the answer: a failed request must not mark these rows as asked,
    // or one network hiccup would leave them unbadged for the rest of the session.
    statusAsked.formUnion(unknown)
    deleted.formUnion(found)
  }
}
