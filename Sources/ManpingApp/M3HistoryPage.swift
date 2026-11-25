import AppKit
import ManpingCore
import SwiftUI

/// 历史的两个来源。账号是 Bilibili 自己的列表，会随官方保留期滚动消失；归档是
/// 用户自己的 bili-history 永久副本，两者不混排，因为两套排序和两套删除语义放在
/// 一个列表里只会互相矛盾。
private enum HistorySource: Hashable {
  case account, archive
}

struct M3HistoryPage: View {
  @ObservedObject var model: AppModel
  @StateObject private var history: HistoryPageModel
  @StateObject private var archive: ArchiveBrowserModel
  @State private var tab: HistoryBusiness = .archive
  @State private var source: HistorySource = .account
  @State private var searchText = ""
  @State private var archiveSearchText = ""
  @State private var consumedScopeRequest: UUID?
  @State private var loadedIdentityVersion = 0
  @Environment(\.colorScheme) private var scheme
  @Environment(\.browsingPageActive) private var browsingPageActive
  init(model: AppModel) {
    self.model = model
    _history = StateObject(wrappedValue: HistoryPageModel(service: model.service, rpc: Self.makeRPC(model)))
    _archive = StateObject(wrappedValue: ArchiveBrowserModel(service: model.clientHistory))
  }
  private static func makeRPC(_ model: AppModel) -> LibraryRPCService? {
    let installation = InstallationIdentity.library
    if let transport = model.libraryRPCTransport {
      return LibraryRPCService(auth: model.service, transport: transport, installationID: installation)
    } else {
      return try? LibraryRPCService(auth: model.service, installationID: installation)
    }
  }
  var body: some View {
    VStack(spacing: 0) {
      if source == .archive {
        archiveBody
      } else {
        accountBody
      }
    }
      .pageToolbar(title: "历史记录", subtitle: subtitle,
        refreshing: isRefreshing, refresh: { Task { await refresh() } }) { headerControls }
      .task(id: "\(tab.rawValue):\(model.refreshToken)") {
        loadedIdentityVersion = history.identityVersion
        if let request = model.regionalSearchRequest, request.route == .history,
          consumedScopeRequest != request.revision {
          consumedScopeRequest = request.revision; searchText = request.keyword
          await history.load(business: tab, keyword: request.keyword)
        } else { await history.load(business: tab, keyword: "") }
      }
      .task(id: source) {
        // 归档只在用户切过去时加载一次；概览（继续观看 + 摘要）自带幂等，重复切换不重复请求。
        guard source == .archive else { return }
        await archive.loadOverview()
        await archive.load(segment: archive.segment, reset: true)
      }
      .onChange(of: model.regionalSearchRequest?.revision) { _, _ in
        guard let request = model.regionalSearchRequest, request.route == .history else { return }
        consumedScopeRequest = request.revision; searchText = request.keyword
        Task { await history.load(business: tab, keyword: request.keyword) }
      }
      .onChange(of: browsingPageActive, initial: true) { _, _ in reloadIdentityIfNeeded() }
      .onChange(of: model.hasArchiveServer) { _, available in
        // 关掉 bili-history 后归档的入口已经消失，这里把来源收回账号，避免继续请求。
        if !available { source = .account }
      }
      .onChange(of: history.identityVersion) { _, _ in reloadIdentityIfNeeded() }
      .onDisappear { history.cancelRequests() }
      .confirmationDialog(confirmationTitle, isPresented: Binding(
        get: { history.confirmation != nil }, set: { if !$0 { history.cancelConfirmation() } }
      ), titleVisibility: .visible) {
        Button(confirmationTitle, role: .destructive) { history.confirmInBackground() }
        Button("取消", role: .cancel) { history.cancelConfirmation() }
      } message: { Text("此操作会影响当前账号，无法撤销。") }
  }

  private var subtitle: String? {
    if source == .archive {
      return archive.summary.map { Self.periodTitle($0) } ?? "来自你的 bili-history"
    }
    return history.keyword.isEmpty ? nil : "搜索「\(history.keyword)」"
  }

  private var isRefreshing: Bool {
    source == .archive ? archive.isLoading : (history.isLoading && !history.records.isEmpty)
  }

  private func refresh() async {
    if source == .archive { await archive.refresh() } else { await history.refresh() }
  }

  private func reloadIdentityIfNeeded() {
    guard browsingPageActive, loadedIdentityVersion != history.identityVersion else { return }
    // History already publishes invalidation; a retained source consumes it only when visible.
    loadedIdentityVersion = history.identityVersion
    Task { await history.refresh() }
  }

  private var confirmationTitle: String {
    if case .remove? = history.confirmation { return "删除这条历史记录" }
    return "清空\(history.business.title)历史"
  }

  @ViewBuilder private var headerControls: some View {
    if model.hasArchiveServer {
      SegmentedTabs(options: [(HistorySource.account, "账号"), (.archive, "归档")], selection: $source)
        .help("归档来自你自己的 bili-history，清空官方历史也不会丢。")
    }
    if source == .account {
      accountHeaderControls
    } else {
      archiveHeaderControls
    }
  }

  // MARK: 账号（原样保留）

  @ViewBuilder private var accountHeaderControls: some View {
    if history.keyword.isEmpty {
      SegmentedTabs(options: HistoryBusiness.allCases.map { ($0, $0.title) }, selection: $tab)
    } else {
      Button { searchText = ""; Task { await history.exitSearch() } } label: { Label("退出搜索", systemImage: "xmark") }
        .toolbarActionStyle()
    }
    TextField("在历史记录中搜索", text: $searchText, prompt: Text("在历史记录中搜索")).labelsHidden().textFieldStyle(AppTextFieldStyle(height: Theme.toolbarControlHeight)).frame(width: 150)
      .onSubmit { Task { await history.load(business: tab, keyword: searchText) } }
    if history.keyword.isEmpty {
      Button { history.requestClear() } label: { Label("清空", systemImage: "trash") }
        .toolbarActionStyle(.destructive).disabled(history.records.isEmpty || history.busy || history.isLoading)
    }
  }

  private var accountBody: some View {
    Group {
      if history.records.isEmpty && history.isLoading {
        PageStateView(.loading, title: "正在加载历史记录…")
      } else if history.records.isEmpty, let error = history.error {
        PageStateView(.error, title: "没能加载历史记录", message: error, icon: "wifi.exclamationmark", actionTitle: "重试") {
          Task { await history.refresh() }
        }
      } else if history.records.isEmpty {
        PageStateView(title: history.keyword.isEmpty ? "历史记录是空的" : "没有找到匹配的记录",
          message: history.keyword.isEmpty ? "看过的视频会出现在这里。" : "换个关键词试试。", icon: "clock.arrow.circlepath")
      } else {
        results
      }
    }
  }

  private var results: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 20) {
        ForEach(HistoryDateSection.grouped(history.records)) { section in
          Text(section.title()).font(Theme.Font.headline).foregroundStyle(Theme.secondaryText(scheme)).padding(.top, 4)
          LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.gridMinimum), spacing: Theme.gridSpacing)], spacing: Theme.gridSpacing) {
            ForEach(section.records) { record in historyCard(record) }
          }
        }
        if let error = history.error {
          InlineErrorText(message: error)
          Button("重试") { Task { await history.loadNext() } }.buttonStyle(AppButtonStyle(size: .small))
        } else if history.isLoading || history.hasMore {
          LoadMoreFooter(isLoading: history.isLoading, autoLoad: false) { Task { await history.loadNext() } }
        }
      }.cardGridContent().padding(Theme.gridPadding).performanceScrollTarget(target: "history")
    }.cardGrid().performanceScrollProbe(page: "history").prefetchOnScroll(enabled: history.hasMore && !history.isLoading && !history.busy && history.error == nil) {
      Task { await history.loadNext() }
    }
  }

  @ViewBuilder private func historyCard(_ record: HistoryRecord) -> some View {
    let remove = Button("从历史记录中删除", role: .destructive) { history.requestRemove(record) }
      .disabled(history.busy || history.isLoading)
    if case .video(let video) = record.entry.destination {
      VideoCard(video: video, action: { model.open(video) }, menuExtra: AnyView(remove)).help(record.entry.subtitle)
    } else {
      LibraryEntryCard(entry: record.entry) { model.open(record.entry) }.contextMenu { remove }
    }
  }

  // MARK: 归档

  @ViewBuilder private var archiveHeaderControls: some View {
    SegmentedTabs(options: ArchiveBrowserModel.Segment.allCases.map { ($0, $0.rawValue) }, selection: Binding(
      get: { archive.segment }, set: { segment in Task { await archive.load(segment: segment, reset: true) } }
    ))
    if archive.segment == .favorites, let folder = archive.selectedFolder {
      Button { archive.closeFolder() } label: { Label("所有收藏夹", systemImage: "chevron.left") }
        .toolbarActionStyle()
        .help("返回收藏夹列表（当前：\(folder.title)）")
    }
    if archive.segment == .history {
      TextField("在归档中搜索", text: $archiveSearchText, prompt: Text("在归档中搜索"))
        .labelsHidden().textFieldStyle(AppTextFieldStyle(height: Theme.toolbarControlHeight)).frame(width: 150)
        .onSubmit { Task { await searchArchive() } }
    }
    if let url = Self.reportURL(model) {
      Button { ExternalWebLink.open(url) } label: { Label("完整报告", systemImage: "chart.bar.doc.horizontal") }
        .toolbarActionStyle()
        .help("在浏览器里打开 bili-history 的年度与月度报告")
    }
  }

  private func searchArchive() async {
    let keyword = archiveSearchText
    guard !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      await archive.load(segment: .history, reset: true)
      return
    }
    // ArchiveBrowserModel 的游标接口不带关键词；这里用一次性搜索并清空游标，避免
    // 搜索结果和"加载更多"混在一起（服务器对关键词分页的支持尚未暴露给客户端）。
    if let found = try? await model.clientHistory.search(keyword, limit: 40) {
      archive.applySearchResults(found)
    }
  }

  private var archiveBody: some View {
    Group {
      if !model.hasArchiveServer {
        PageStateView(title: "还没有连接 bili-history",
          message: "在 设置 › 隐私 › bili-history 里填上服务器地址，归档的历史、稍后再看和收藏就会出现在这里。",
          icon: "archivebox")
      } else if archive.isLoading && archive.history.isEmpty && archive.segment == .history && archive.summary == nil {
        PageStateView(.loading, title: "正在读取归档…")
      } else if archive.segment == .history && archive.history.isEmpty, let error = archive.error {
        PageStateView(.error, title: "没能读取归档", message: error, icon: "wifi.exclamationmark", actionTitle: "重试") {
          Task { await archive.refresh() }
        }
      } else {
        archiveScroll
      }
    }
  }

  private var archiveScroll: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 20) {
        if archive.segment == .history {
          if !archive.recent.isEmpty { resumeSection }
          if let summary = archive.summary { summaryStrip(summary) }
        }
        switch archive.segment {
        case .history: archiveHistorySection
        case .later: archiveLaterSection
        case .favorites: archiveFavoritesSection
        }
        if archive.isLoading {
          LoadMoreFooter(isLoading: true, autoLoad: false) {}
        } else if archive.canLoadMore {
          LoadMoreFooter(isLoading: false, autoLoad: false) { Task { await archive.loadMore() } }
        }
        if let error = archive.error, !archive.isLoading {
          InlineErrorText(message: error)
        }
      }.cardGridContent().padding(Theme.gridPadding).performanceScrollTarget(target: "archive-history")
    }.cardGrid().performanceScrollProbe(page: "archive-history")
      .prefetchOnScroll(enabled: archive.canLoadMore && !archive.isLoading && archive.error == nil) {
        Task { await archive.loadMore() }
      }
  }

  private var resumeSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Text("接着看").font(Theme.Font.headline).foregroundStyle(Theme.secondaryText(scheme))
        Text("\(archive.recent.count)").font(Theme.Font.caption.monospacedDigit()).foregroundStyle(Theme.tertiaryText(scheme))
      }
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(alignment: .top, spacing: Theme.gridSpacing) {
          ForEach(archive.recent) { item in
            VideoCard(video: item.video, action: { model.open(item.video) })
              .frame(width: 240)
              .overlay(alignment: .topLeading) {
                if archive.isDeleted(item.bvid) { ArchiveDeletedBadge() }
              }
          }
        }.padding(.vertical, 2)
      }
    }
  }

  private func summaryStrip(_ summary: ArchiveSummary) -> some View {
    HStack(spacing: 10) {
      Image(systemName: "chart.bar.xaxis").font(.system(size: 12)).foregroundStyle(Theme.secondaryText(scheme))
      Text(Self.summaryText(summary)).font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme))
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12).padding(.vertical, 8)
    .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  @ViewBuilder private var archiveHistorySection: some View {
    if archive.history.isEmpty {
      if !archive.isLoading {
        PageStateView(title: archiveSearchText.isEmpty ? "归档里还没有记录" : "没有找到匹配的记录",
          message: archiveSearchText.isEmpty
            ? "bili-history 每小时抓取一次，抓到的记录会永久留在这里。" : "换个关键词试试。",
          icon: "archivebox")
      }
    } else {
      ForEach(archive.historySections) { section in
        Text(section.title).font(Theme.Font.headline).foregroundStyle(Theme.secondaryText(scheme)).padding(.top, 4)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.gridMinimum), spacing: Theme.gridSpacing)], spacing: Theme.gridSpacing) {
          ForEach(section.items) { item in
            VideoCard(video: item.video, action: { model.open(item.video) })
              .overlay(alignment: .topLeading) {
                if archive.isDeleted(item.bvid) { ArchiveDeletedBadge() }
              }
              .opacity(archive.isDeleted(item.bvid) ? 0.55 : 1)
              .help("\(Self.dayText(item.viewAt)) · \(Self.positionText(item))")
          }
        }
      }
      if archive.hiddenNonVideo > 0 {
        Text("另外 \(archive.hiddenNonVideo) 条直播、专栏记录只能在 bili-history 网页里查看。")
          .font(Theme.Font.caption2).foregroundStyle(Theme.tertiaryText(scheme))
      }
    }
  }

  @ViewBuilder private var archiveLaterSection: some View {
    if archive.later.isEmpty {
      if !archive.isLoading { PageStateView(title: "归档里没有稍后再看", message: "在 bili-history 同步过后，删稿的视频也还在这里。", icon: "clock") }
    } else {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.gridMinimum), spacing: Theme.gridSpacing)], spacing: Theme.gridSpacing) {
        ForEach(archive.later) { item in
          VideoCard(video: item.video, action: { model.open(item.video) })
            .overlay(alignment: .topLeading) {
              if archive.isDeleted(item.bvid) { ArchiveDeletedBadge() }
            }
            .opacity(archive.isDeleted(item.bvid) ? 0.55 : 1)
        }
      }
    }
  }

  @ViewBuilder private var archiveFavoritesSection: some View {
    if archive.selectedFolder == nil {
      if archive.folders.isEmpty {
        if !archive.isLoading {
          PageStateView(title: "归档里没有收藏夹", message: "在 bili-history 同步过收藏夹后，这里会列出它们。", icon: "star")
        }
      } else {
        VStack(spacing: 8) {
          ForEach(archive.folders) { folder in
            Button { Task { await archive.open(folder) } } label: {
              HStack(spacing: 10) {
                Image(systemName: "folder").font(.system(size: 13)).foregroundStyle(Theme.secondaryText(scheme))
                Text(folder.title).font(Theme.Font.body).lineLimit(1)
                Spacer(minLength: 8)
                Text("\(folder.mediaCount)").font(Theme.Font.caption.monospacedDigit()).foregroundStyle(Theme.tertiaryText(scheme))
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.tertiaryText(scheme))
              }
              .padding(.horizontal, 12).frame(height: 40)
              .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
              .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }.buttonStyle(.plain)
          }
        }
      }
    } else if archive.favoriteContents.isEmpty {
      if !archive.isLoading {
        PageStateView(title: "这个收藏夹是空的", icon: "star")
      }
    } else {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.gridMinimum), spacing: Theme.gridSpacing)], spacing: Theme.gridSpacing) {
        ForEach(archive.favoriteContents) { item in
          VideoCard(video: item.video, action: { model.open(item.video) })
            .overlay(alignment: .topLeading) {
              if archive.isDeleted(item.bvid) { ArchiveDeletedBadge() }
            }
            .opacity(archive.isDeleted(item.bvid) ? 0.55 : 1)
        }
      }
    }
  }

  // MARK: 文案

  static func reportURL(_ model: AppModel) -> URL? {
    guard let base = BiliHistoryConfig.normalizedBaseURL(model.appSettings.text(.historyServer)),
      !base.isEmpty else { return nil }
    return URL(string: base + "/report")
  }

  static func periodTitle(_ summary: ArchiveSummary) -> String {
    summary.month == 0 ? "\(summary.year) 年归档" : "\(summary.year) 年 \(summary.month) 月归档"
  }

  /// 与 bili-history 月报同口径：seconds 是视频总长，不是实际观看用时。
  static func summaryText(_ summary: ArchiveSummary) -> String {
    guard summary.videos > 0 else { return "本月还没有观看记录。" }
    let hours = Double(summary.seconds) / 3600
    let length = hours >= 10 ? String(format: "%.0f", hours) : String(format: "%.1f", hours)
    let finished = Int((summary.finishedRate * 100).rounded())
    let night = Int((summary.lateNightRatio * 100).rounded())
    return "本月 \(summary.videos) 个视频 · \(length) 小时 · \(summary.uniqueAuthors) 位 UP 主 · 完播 \(finished)% · 深夜 \(night)%"
  }

  static func dayText(_ timestamp: Int64) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "M月d日 EEEE"
    return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
  }

  static func positionText(_ item: ArchiveVideo) -> String {
    if item.finished { return "已看完" }
    guard item.duration > 0 else { return "已看" }
    return "看到 \(item.progress / 60):" + String(format: "%02d", item.progress % 60)
  }
}

/// 失效标记只来自 bili-history 的缓存，查不到时不显示——少一个标记好过标错。
private struct ArchiveDeletedBadge: View {
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    Text("已失效")
      .font(Theme.Font.caption2.weight(.semibold))
      .foregroundStyle(.white)
      .padding(.horizontal, 6).padding(.vertical, 2)
      .background(.black.opacity(0.6), in: Capsule())
      .padding(6)
      .allowsHitTesting(false)
  }
}
