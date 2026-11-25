import ManpingCore
import SwiftUI

/// 首页: 推荐 / 热门 / 排行榜 (the tabs live in the toolbar). Per-partition rankings are on 分区.
struct PopularPage: View {
  @ObservedObject var model: AppModel
  @StateObject private var feed: BrowseFeedModel
  @StateObject private var history: HistoryPageModel
  @State private var continueAccountID: Int64?
  private var requestKey: String { String(describing: model.popularTab) }
  private var continueItems: [ContinueWatchingItem] { ContinueWatchingItem.entries(from: history.records.map(\.item)) }
  init(model: AppModel) {
    self.model = model
    _feed = StateObject(wrappedValue: BrowseFeedModel(service: model.service))
    let installation = InstallationIdentity.library
    let rpc: LibraryRPCService?
    if let transport = model.libraryRPCTransport {
      rpc = LibraryRPCService(auth: model.service, transport: transport, installationID: installation)
    } else { rpc = try? LibraryRPCService(auth: model.service, installationID: installation) }
    _history = StateObject(wrappedValue: HistoryPageModel(service: model.service, rpc: rpc))
  }
  var body: some View {
    VStack(spacing: 0) {
      continueWatching
      BrowseVideoResults(feed: feed, open: model.open, filtersRecommendations: model.popularTab == .recommended)
    }
      .pageToolbar(title: "首页", refreshing: feed.state.isLoading && !feed.state.items.isEmpty, refresh: { feed.refresh() }) {
        Button { model.playCuratedList() } label: {
          Label("播放精选", systemImage: "play.square.stack")
        }.toolbarActionStyle().disabled(model.curatedLoading)
          .help("把推荐里的精选视频排成一个列表连续播放")
        if model.curatedLoading {
          Button { model.cancelCuratedPlaylist() } label: { ToolbarIcon("xmark") }
            .toolbarIconStyle().help("停止加载精选").accessibilityLabel("停止加载精选")
        }
      }
      .task(id: "\(requestKey):\(model.refreshToken)") {
        let selectedTab = model.popularTab; let service = model.service
        feed.activate(key: requestKey, refreshToken: model.refreshToken) { [model, selectedTab, service] cursor in
          if PerformanceOptions.requested {
            return BrowseVideoPage(items: PerformanceFixtures.videos, nextCursor: nil)
          }
          switch selectedTab {
          case .recommended: return try await service.recommend(cursor: cursor)
          case .popular:
            return try await RPCBrowseSource(rpc: model.standardRPCService()).popularFeed(cursor: cursor)
          case .ranking:
            return try await RPCBrowseSource(rpc: model.standardRPCService()).rankingFeed(region: 0)
          }
        }
      }
      .task(id: "continue:\(model.accountMID ?? 0):\(model.refreshToken)") {
        continueAccountID = model.accountMID
        guard model.accountMID != nil else { return }
        await history.load(business: .archive)
      }
      .onDisappear { feed.deactivate(); history.cancelRequests() }
  }
  @ViewBuilder private var continueWatching: some View {
    if model.accountMID != nil, continueAccountID == model.accountMID,
      history.isLoading || !continueItems.isEmpty || history.error != nil {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Text("继续观看").font(Theme.Font.headline)
          Spacer()
          if let error = history.error {
            InlineErrorText(message: error)
            Button("重试") { Task { await history.refresh() } }.buttonStyle(AppButtonStyle(size: .small))
          } else if history.isLoading {
            ProgressView().controlSize(.small)
          }
        }
        if !continueItems.isEmpty {
          ScrollView(.horizontal) {
            HStack(spacing: 14) {
              ForEach(continueItems) { item in
                VideoCard(video: item.video, action: { model.open(item.video, startAt: Double(item.progress)) })
                  .frame(width: 240)
              }
            }.padding(.vertical, 4)
          }.scrollIndicators(.hidden)
        }
      }.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)
    }
  }
}

struct PartitionSymbol: View {
  let partition: VideoPartition
  private var symbol: String {
    switch partition.id {
    case 1: "play.square.fill"
    case 3: "headphones"
    case 129: "fan.fill"
    case 4: "gamecontroller.fill"
    case 36: "lightbulb.fill"
    case 188: "cloud.fill"
    case 223: "car.fill"
    case 234: "figure.run"
    case 160: "duffle.bag.fill"
    case 211: "fork.knife"
    case 217: "pawprint.fill"
    case 119: "face.smiling.fill"
    case 155: "tshirt.fill"
    default: "play.rectangle.fill"
    }
  }
  private var color: Color {
    Theme.partitionPalette[abs(partition.id) % Theme.partitionPalette.count]
  }
  var body: some View {
    Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
      .frame(width: 18, height: 18).background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous))
  }
}
