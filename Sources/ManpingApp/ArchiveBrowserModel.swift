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

  private let service: ClientHistoryService?
  private var historyCursor: Int64 = 0
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

  /// Replaces the list with a one-off keyword result. Kept separate from paging so
  /// a search never mixes with "加载更多" rows.
  func applySearchResults(_ items: [ArchiveVideo]) {
    history = items.filter(\.isPlayable)
    hiddenNonVideo = items.count - history.count
    historyCursor = 0
    hasMore = false
    error = nil
    segment = .history
    Task { await resolveStatus(history.map(\.bvid)) }
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
    do { recent = try await recentTask } catch { recent = [] }
    do { summary = try await summaryTask } catch { summary = nil }
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
    error = nil
    await loadOverview()
    await load(segment: segment, reset: true)
  }

  func load(segment: Segment, reset: Bool = false) async {
    guard let service else { return }
    self.segment = segment
    isLoading = true
    error = nil
    defer { isLoading = false }
    do {
      switch segment {
      case .history:
        if reset { history = []; historyCursor = 0; hiddenNonVideo = 0 }
        let page = try await service.history(cursor: historyCursor, limit: 40)
        let playable = page.records.filter(\.isPlayable)
        hiddenNonVideo += page.records.count - playable.count
        history.append(contentsOf: playable)
        historyCursor = page.next
        hasMore = page.next != 0
        await resolveStatus(playable.map(\.bvid))
      case .later:
        if reset { later = []; laterPage = 0 }
        let page = try await service.watchLater(page: laterPage + 1, size: 40)
        later.append(contentsOf: page.records)
        laterPage += 1
        laterHasMore = later.count < page.total && !page.records.isEmpty
        await resolveStatus(page.records.map(\.bvid))
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
    guard let service else { return }
    switch segment {
    case .history where hasMore:
      isLoading = true
      defer { isLoading = false }
      do {
        let page = try await service.history(cursor: historyCursor, limit: 40)
        let playable = page.records.filter(\.isPlayable)
        hiddenNonVideo += page.records.count - playable.count
        history.append(contentsOf: playable)
        historyCursor = page.next
        hasMore = page.next != 0
        await resolveStatus(playable.map(\.bvid))
      } catch { self.error = error.localizedDescription }
    case .later where laterHasMore:
      isLoading = true
      defer { isLoading = false }
      do {
        let page = try await service.watchLater(page: laterPage + 1, size: 40)
        later.append(contentsOf: page.records)
        laterPage += 1
        laterHasMore = later.count < page.total && !page.records.isEmpty
        await resolveStatus(page.records.map(\.bvid))
      } catch { self.error = error.localizedDescription }
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
