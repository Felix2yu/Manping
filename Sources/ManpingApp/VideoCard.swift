import AppKit
import ManpingCore
import SwiftUI

// Source: Controls/Components/VideoCardControl/VideoCardControl.xaml at UI 896a062, restyled to the
// borderless 流光玻璃 card: cover, two-line title, one metadata line; the surface appears on hover.
/// What a card's context menu can do beyond its own tap action, provided once by the main
/// window. Cards outside it (no value in the environment) show only the link items.
struct CardActions {
  var play: @MainActor (Video) -> Void
  var playCompact: @MainActor (Video) -> Void
  var playDetached: @MainActor (Video) -> Void
  var openSpace: @MainActor (Int64) -> Void
  var playLiveCompact: @MainActor (Int64) -> Void
  var addViewLater: @MainActor (Video) -> Void
  var openWeb: @MainActor (URL) -> Void
  var copyWebLink: @MainActor (URL) -> Void

  @MainActor init(model: AppModel) {
    play = { model.open($0) }
    // The menu's choice is this open's mode; 设置 › 打开视频时 does not override it on load.
    playCompact = { model.open($0, mode: .compact) }
    playDetached = { model.open($0, mode: .detached) }
    openSpace = { model.openOverlay(.userSpace($0)) }
    playLiveCompact = { model.openLive($0, mode: .compact) }
    addViewLater = { video in
      guard let aid = video.aid, aid > 0 else { return }
      Task { await model.viewLaterActions.add(aid) { model.showingLogin = true } }
    }
    openWeb = { model.openWebURL($0) }
    copyWebLink = { url in
      NSPasteboard.general.clearContents()
      guard NSPasteboard.general.setString(url.absoluteString, forType: .string) else {
        model.error = "没能把链接写入剪贴板，请重试。"; return
      }
      model.actionNotice = "链接已复制。"
    }
  }

  static func webURL(_ video: Video) -> URL? {
    let id = video.bvid.hasPrefix("BV") ? video.bvid : video.aid.map { "av\($0)" } ?? ""
    return id.isEmpty ? nil : URL(string: "https://www.bilibili.com/video/\(id)")
  }
}

extension EnvironmentValues {
  @Entry var cardActions: CardActions? = nil
  @Entry var viewLaterActions: ViewLaterActionsModel? = nil
}

/// The shared video context menu: 播放 / 小窗播放 / 在独立窗口播放 — 拷贝链接 / 在浏览器中打开 —
/// 进入 UP 主空间. `extra` items (such as 删除记录) follow at the end.
struct VideoContextMenu: View {
  let video: Video
  var extra: AnyView?
  var filterRecommendation: ((RecommendationRuleKind) -> Void)?
  var hideRecommendation: (() -> Void)?
  @Environment(\.cardActions) private var actions
  @Environment(\.viewLaterActions) private var viewLater
  var body: some View {
    if let actions {
      Button("播放") { actions.play(video) }
      Button("小窗播放") { actions.playCompact(video) }
      Button("在独立窗口播放") { actions.playDetached(video) }
      if let aid = video.aid, aid > 0 {
        Button { actions.addViewLater(video) } label: {
          Label("加入稍后再看", systemImage: "clock")
        }.disabled(viewLater?.isBusy(aid) == true)
      }
      Divider()
    }
    if let viewLater, let aid = video.aid, let error = viewLater.error(for: aid) {
      Text(error).foregroundStyle(.red)
    }
    if let notice = viewLater?.notice { Text(notice).foregroundStyle(Theme.accent) }
    if let actions, let url = CardActions.webURL(video) {
      Button("拷贝链接") { actions.copyWebLink(url) }
      Button("在浏览器中打开") { actions.openWeb(url) }
    }
    if let actions, let mid = video.authorID, mid > 0 {
      Divider()
      Button("进入 UP 主空间") { actions.openSpace(mid) }
    }
    if let filterRecommendation {
      Divider()
      RecommendationFilterMenu(video: video, onFilter: filterRecommendation, onHide: hideRecommendation)
    }
    if let extra {
      Divider()
      extra
    }
  }
}

struct VideoCoverImage: View {
  let url: URL?

  var body: some View {
    Color.clear.aspectRatio(16 / 9, contentMode: .fit)
      .overlay { CachedImage(url: url).clipped() }
      .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
  }
}

struct VideoCover: View {
  let url: URL?
  var duration: Int? = nil
  var views: Int? = nil
  var viewsText: String? = nil
  var recommendationReason: String? = nil
  var bvid: String? = nil
  var watchedCompact = false
  @Environment(\.watchHistory) private var watchHistory

  var body: some View {
    VideoCoverImage(url: url)
      .overlay(alignment: .topLeading) {
        if let recommendationReason, !recommendationReason.isEmpty {
          RecommendBadge(text: recommendationReason).padding(8).padding(.trailing, 40)
        }
      }
      .overlay(alignment: .bottomTrailing) {
        HStack(spacing: 6) {
          if let duration, duration > 0 { MediaBadge(text: Self.durationText(duration)) }
          if let playText { MediaBadge(text: playText, systemImage: "play") }
        }.padding(8)
      }
      .overlay(alignment: .bottomLeading) {
        if let watchHistory, let bvid { WatchedBadge(store: watchHistory, bvid: bvid, compact: watchedCompact) }
      }
      .overlay(alignment: .bottom) {
        if let watchHistory, let bvid { WatchProgressBar(store: watchHistory, bvid: bvid) }
      }
      .onAppear { if let bvid { watchHistory?.request(bvid) } }
  }

  private var playText: String? {
    if let viewsText, !viewsText.isEmpty { return viewsText }
    guard let views, views > 0 else { return nil }
    return Self.count(views)
  }

  static func durationText(_ seconds: Int) -> String {
    String(format: "%02d:%02d", max(0, seconds) / 60, max(0, seconds) % 60)
  }

  static func count(_ value: Int) -> String {
    if value >= 100_000_000 { return String(format: "%.1f亿", Double(value) / 100_000_000) }
    if value >= 10_000 { return String(format: "%.1f万", Double(value) / 10_000) }
    return String(value)
  }
}

struct VideoCard: View {
  let video: Video
  var action: () -> Void
  /// Page-specific items appended to the context menu.
  var menuExtra: AnyView? = nil
  var filterRecommendation: ((RecommendationRuleKind) -> Void)?
  var hideRecommendation: (() -> Void)?
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    // Cover and title play; the UP 主 name opens their space, as on Bilibili.
    VStack(alignment: .leading, spacing: 4) {
      Button(action: action) {
        VStack(alignment: .leading, spacing: Theme.cardTitleGap) {
          VideoCover(url: video.cover, duration: video.duration, views: video.views, viewsText: video.viewsText,
            recommendationReason: video.recommendationReason, bvid: video.bvid)
          Text(video.title).font(Theme.Font.headline).foregroundStyle(Theme.text(scheme))
            .lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }.contentShape(Rectangle())
      }.buttonStyle(CardPressStyle()).accessibilityLabel("播放 \(video.title)，\(video.author)")
        .demoAnchor("card.\(video.title)")
      CardMetadataLine(author: video.author, authorID: video.authorID, rest: metadata, action: action)
    }.cardHover()
      .contextMenu {
        VideoContextMenu(video: video, extra: menuExtra,
          filterRecommendation: filterRecommendation, hideRecommendation: hideRecommendation)
      }
  }

  /// The subtitle stands in for the time when the feed gives one.
  private var metadata: String {
    var parts: [String] = []
    if let subtitle = video.subtitle, !subtitle.isEmpty {
      parts.append(subtitle)
    } else if let publishedAt = video.publishedAt, publishedAt > 0 {
      parts.append(Self.relative.localizedString(for: Date(timeIntervalSince1970: Double(publishedAt)), relativeTo: .now))
    }
    return parts.joined(separator: " · ")
  }

  private static let relative: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.unitsStyle = .short
    return formatter
  }()
}

private struct RecommendationFilterMenu: View {
  let video: Video
  let onFilter: (RecommendationRuleKind) -> Void
  let onHide: (() -> Void)?
  @ObservedObject private var store = RecommendationFilterStore.shared

  var body: some View {
    Menu("不再推荐") {
      if let onHide {
        Button {
          onHide()
        } label: {
          if store.filter.hides(video) { Label("这个视频", systemImage: "checkmark") }
          else { Text("这个视频") }
        }
        .disabled(store.filter.hides(video)
          || RecommendationHiddenVideo.identity(bvid: video.bvid, aid: video.aid) == nil)
        Divider()
      }
      if let id = video.partitionID, let name = video.partitionName, !name.isEmpty {
        filterButton("一级分区：\(name)", kind: .primaryPartition, id: Int64(id))
      }
      if let id = video.subpartitionID, let name = video.subpartitionName, !name.isEmpty {
        filterButton("二级分区：\(name)", kind: .subpartition, id: Int64(id))
      }
      if let id = video.authorID, id > 0, !video.author.isEmpty {
        filterButton("UP 主：\(video.author)", kind: .author, id: id)
      }
    }
  }

  private func filterButton(_ title: String, kind: RecommendationRuleKind, id: Int64) -> some View {
    Button { onFilter(kind) } label: {
      if store.filter.contains(kind, valueID: id) { Label(title, systemImage: "checkmark") }
      else { Text(title) }
    }
  }
}

/// 已看 marker on a cover. Follows the store so a video marked after playback updates
/// when the user returns to the list, without reloading the page.
struct WatchedBadge: View {
  @ObservedObject var store: WatchHistoryStore
  let bvid: String
  /// The small thumbnails in the moments feed only have room for the checkmark.
  var compact = false
  var body: some View {
    if let record = store.record(bvid), record.watched {
      Group {
        if compact {
          Image(systemName: "checkmark.circle.fill").font(.system(size: 11, weight: .semibold))
            .padding(4).background(.black.opacity(0.58), in: Circle()).padding(6)
        } else {
          HStack(spacing: 3) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 9, weight: .semibold))
            Text("已看").font(.system(size: 10, weight: .medium))
          }.padding(.horizontal, 6).padding(.vertical, 3)
            .background(.black.opacity(0.58), in: Capsule()).padding(8)
        }
      }.foregroundStyle(.white).accessibilityLabel("已看")
    }
  }
}

/// The thin bar a half-watched video leaves at the bottom of its cover. Completed
/// videos are covered by the 已看 marker alone.
struct WatchProgressBar: View {
  @ObservedObject var store: WatchHistoryStore
  let bvid: String
  var body: some View {
    if let record = store.record(bvid), record.watched, !record.finished, record.fraction > 0 {
      GeometryReader { proxy in
        ZStack(alignment: .leading) {
          Color.white.opacity(0.3)
          Rectangle().fill(Theme.accent).frame(width: proxy.size.width * record.fraction)
        }
      }.frame(height: 3).accessibilityLabel("观看进度 \(Int(record.fraction * 100))%")
    }
  }
}

/// A card's 「UP 主 · 播放 · 时间」 line. The name opens the UP 主's space (when the card knows
/// who it is and the main window can open spaces); the rest of the line plays like the card.
struct CardMetadataLine: View {
  let author: String
  let authorID: Int64?
  let rest: String
  let action: () -> Void
  @Environment(\.cardActions) private var actions
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    HStack(spacing: 0) {
      if !author.isEmpty {
        if let actions, let mid = authorID, mid > 0 {
          Button(author) { actions.openSpace(mid) }.buttonStyle(CardAuthorLinkStyle())
            .help("进入 \(author) 的空间").accessibilityLabel("进入 UP 主空间：\(author)")
        } else {
          Text(author).foregroundStyle(Theme.tertiaryText(scheme))
        }
      }
      Button(action: action) {
        Text((author.isEmpty || rest.isEmpty ? "" : " · ") + rest).foregroundStyle(Theme.tertiaryText(scheme))
          .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
      }.buttonStyle(.plain).accessibilityHidden(true)
    }.font(Theme.Font.caption.monospacedDigit()).lineLimit(1)
  }
}

/// The UP 主 name on a card: card metadata colour, accent with an underline while hovered.
struct CardAuthorLinkStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View { AuthorLink(configuration: configuration) }
  private struct AuthorLink: View {
    let configuration: Configuration
    @State private var hovered = false
    @Environment(\.colorScheme) private var scheme
    var body: some View {
      configuration.label
        .foregroundStyle(hovered ? Theme.accentText(scheme) : Theme.tertiaryText(scheme))
        .underline(hovered)
        .opacity(configuration.isPressed ? 0.7 : 1)
        .onHover { hovered = $0 }
        .layoutPriority(1)
    }
  }
}

/// Cards dim slightly while pressed; hover lift comes from `cardHover()`.
struct CardPressStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.opacity(configuration.isPressed ? 0.86 : 1)
      .animation(Theme.hoverAnimation, value: configuration.isPressed)
  }
}

/// Whole-page states in three styles (DesignSystem.md section 9): loading shows the 流光 streak,
/// empty shows the page's symbol, error shows an amber triangle and defaults its action to 「重试」.
struct PageStateView: View {
  enum Style { case loading, empty, error }
  let style: Style
  let title: String
  let message: String
  let icon: String
  let actionTitle: String?
  let action: (() -> Void)?
  @Environment(\.colorScheme) private var scheme

  init(_ style: Style = .empty, title: String, message: String = "", icon: String = "tray",
    actionTitle: String? = nil, action: (() -> Void)? = nil) {
    self.style = style
    self.title = title
    self.message = message
    self.icon = icon
    self.actionTitle = actionTitle ?? (style == .error && action != nil ? "重试" : nil)
    self.action = action
  }

  var body: some View {
    VStack(spacing: 10) {
      symbol.padding(.bottom, 4)
      Text(title).font(Theme.Font.section).foregroundStyle(Theme.text(scheme))
      if !message.isEmpty {
        Text(message).font(Theme.Font.body).foregroundStyle(Theme.secondaryText(scheme))
          .multilineTextAlignment(.center).frame(maxWidth: 420).textSelection(.enabled)
      }
      if let actionTitle, let action {
        Button(actionTitle, action: action).buttonStyle(AppButtonStyle()).padding(.top, 6)
      }
    }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder private var symbol: some View {
    switch style {
    case .loading:
      StreakLoadingView().frame(height: 48)
    case .empty:
      Image(systemName: icon).font(.system(size: 20, weight: .medium)).foregroundStyle(Theme.accentText(scheme))
        .frame(width: 48, height: 48).background(Theme.selectedFill(scheme), in: Circle())
    case .error:
      Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 20, weight: .medium))
        .foregroundStyle(Theme.highlight)
        .frame(width: 48, height: 48).background(Theme.highlight.opacity(0.16), in: Circle())
    }
  }
}
