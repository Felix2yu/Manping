import ManpingCore
import SwiftUI

struct M3SearchPage: View {
  @ObservedObject var model: AppModel
  let term: String
  @StateObject private var library: LibraryModel
  @StateObject private var suggestions: SearchSuggestionModel
  @State private var type: LibrarySearchType = .video
  @State private var order: LibrarySearchOrder = .relevance
  @State private var userOrder: LibraryUserSearchOrder = .relevance
  @State private var filters = LibraryVideoSearchFilters()
  @Environment(\.colorScheme) private var scheme
  private let types: [LibrarySearchType] = [.video, .anime, .cinema, .live, .user, .article]
  init(model: AppModel, term: String) {
    self.model = model; self.term = term
    _library = StateObject(wrappedValue: LibraryModel(model: model))
    _suggestions = StateObject(wrappedValue: SearchSuggestionModel(model: model))
  }
  private var query: LibrarySearchQuery {
    LibrarySearchQuery(term: term, type: type, order: order, userOrder: userOrder, filters: filters)
  }
  private var queryID: String { query.queryID(refreshToken: model.refreshToken) }
  var body: some View {
    HStack(spacing: 0) {
      VStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 2) {
          SidebarSectionTitle(title: "搜索范围")
          ForEach(types, id: \.self) { item in
            Button { type = item } label: {
              Text(item.title).font(Theme.Font.body).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).frame(height: Theme.rowHeight)
            }.buttonStyle(SidebarRowStyle(selected: type == item))
          }
          Spacer()
        }.padding(.horizontal, 10).padding(.bottom, 12)
      }.frame(width: Theme.secondarySidebarWidth)
      Hairline(axis: .vertical)
      VStack(spacing: 0) {
        if term.isEmpty { discovery }
        else {
          if type == .video || type == .user { filterBar }
          LibraryResults(library: library, model: model) { type = .user }
        }
      }
    }
      .pageToolbar(title: term.isEmpty ? "搜索" : "「\(term)」", subtitle: library.total > 0 ? "\(library.total) 个结果" : nil,
        refresh: { if term.isEmpty { suggestions.loadTrending() } else { Task { await library.refresh() } } })
      .task(id: queryID) {
        if term.isEmpty { suggestions.update(""); suggestions.loadTrending() }
        else {
          let request = query
          await library.load(.filteredSearch(request))
        }
      }.onDisappear { library.cancel(); suggestions.cancel() }
  }

  private var filterBar: some View {
    PageFilterBar {
      Menu {
        if type == .user {
          Picker("排序", selection: $userOrder) {
            ForEach(LibraryUserSearchOrder.allCases, id: \.self) { Text($0.title).tag($0) }
          }.pickerStyle(.inline).labelsHidden()
        } else {
          Picker("排序", selection: $order) {
            ForEach(LibrarySearchOrder.allCases, id: \.self) { Text($0.title).tag($0) }
          }.pickerStyle(.inline).labelsHidden()
        }
      } label: {
        MenuLabel(title: type == .user ? userOrder.title : order.title)
      }.appMenuStyle()
      if type == .video {
        Menu {
          Picker("时长", selection: $filters.duration) {
            ForEach(LibrarySearchDuration.allCases, id: \.rawValue) { option in
              Text(option.title).tag(option.rawValue)
            }
          }.pickerStyle(.inline).labelsHidden()
        } label: {
          MenuLabel(title: LibrarySearchDuration(rawValue: filters.duration)?.title ?? "全部时长", symbol: "clock")
        }.appMenuStyle()
        Menu {
          Picker("发布时间", selection: $filters.pubtime) {
            ForEach(LibrarySearchPubtime.allCases, id: \.rawValue) { option in
              Text(option.title).tag(option.rawValue)
            }
          }.pickerStyle(.inline).labelsHidden()
        } label: {
          MenuLabel(title: LibrarySearchPubtime(rawValue: filters.pubtime)?.title ?? "全部发布时间", symbol: "calendar")
        }.appMenuStyle()
        VideoPartitionMenu(service: model.service, tid: $filters.tid)
        if filters.isActive {
          Button("重置筛选") { filters = LibraryVideoSearchFilters() }
            .buttonStyle(AppButtonStyle(size: .small))
        }
      }
      Spacer(minLength: 0)
    }
  }
  private var discovery: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Text("搜索推荐").font(Theme.Font.headline).foregroundStyle(Theme.secondaryText(scheme))
        if suggestions.isLoading { ProgressView().controlSize(.small) }
        FlowChips(items: suggestions.choices.map { ($0.id, $0.title, $0.keyword) }) { submit($0) }
        Label("热搜榜单", systemImage: "flame").font(Theme.Font.headline).foregroundStyle(Theme.secondaryText(scheme)).padding(.top, 8)
        VStack(spacing: 0) {
          ForEach(suggestions.trending) { item in
            Button { submit(item.keyword) } label: {
              HStack(spacing: 12) {
                Text("\(item.position)").font(Theme.Font.body.monospacedDigit()).fontWeight(item.position <= 3 ? .bold : .regular)
                  .foregroundStyle(item.position <= 3 ? Theme.accentText(scheme) : Theme.tertiaryText(scheme)).frame(width: 24)
                Text(item.title).font(Theme.Font.body).lineLimit(1)
                if let icon = item.icon { CachedImage(url: icon).frame(width: 16, height: 16) }
                Spacer()
              }.padding(.horizontal, 12).frame(height: 40)
            }.buttonStyle(SidebarRowStyle())
          }
        }.padding(6).frame(maxWidth: 640).cardSurface(scheme)
        if let error = suggestions.error {
          InlineErrorText(message: error)
          Button("重试") { suggestions.update(""); suggestions.loadTrending() }.buttonStyle(AppButtonStyle(size: .small))
        }
      }.padding(Theme.gridPadding).foregroundStyle(Theme.text(scheme))
    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
  private func submit(_ keyword: String) { model.search = keyword; model.submitSearch() }
}
