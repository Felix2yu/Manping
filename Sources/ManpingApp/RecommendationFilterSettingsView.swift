import ManpingCore
import SwiftUI

struct RecommendationFilterSettingsView: View {
  @ObservedObject var model: AppModel
  @ObservedObject private var store = RecommendationFilterStore.shared
  @StateObject private var directory = BrowsePartitionDirectory()
  @State private var kind: RecommendationRuleKind = .primaryPartition
  @State private var parentID: Int?
  @State private var childID: Int?
  @State private var authorID = ""
  @State private var authorName = ""
  @State private var message: String?
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    ScrollView {
      Form {
        Section {
          Picker("规则类型", selection: $kind) {
            ForEach(RecommendationRuleKind.allCases, id: \.self) { Text($0.title).tag($0) }
          }
          partitionEditor
          authorEditor
          HStack {
            Spacer()
            Button("新增规则", action: addRule).buttonStyle(AppButtonStyle(role: .primary, size: .small))
              .disabled(!canAdd)
          }
          if let message {
            Text(message).font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme))
          }
          if let error = directory.error, directory.partitions.isEmpty {
            Text("没能加载分区：\(error)").font(Theme.Font.caption).foregroundStyle(Theme.danger(scheme))
            Button("重试") { directory.load(service: model.service) }
          }
        } header: {
          Text("新增规则")
        } footer: {
          Text("规则只影响首页推荐；收藏、稍后再看、历史记录、搜索和分区页不受影响。")
        }

        Section("已有规则（\(store.filter.rules.count)）") {
          if store.filter.rules.isEmpty {
            Text("还没有推荐过滤规则。可在首页推荐视频的右键菜单中快速添加。")
              .foregroundStyle(Theme.secondaryText(scheme))
          } else {
            ForEach(store.filter.rules) { rule in
              HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                  Text(rule.name).font(Theme.Font.body).lineLimit(1)
                  Text("\(rule.kind.title) · ID \(rule.valueID)").font(Theme.Font.caption2)
                    .foregroundStyle(Theme.tertiaryText(scheme))
                }
                Spacer(minLength: 0)
                Button { store.remove(id: rule.id) } label: {
                  Image(systemName: "trash").font(.system(size: 12))
                }.buttonStyle(AppButtonStyle(role: .plain, size: .small, iconOnly: true))
                  .help("删除规则").accessibilityLabel("删除 \(rule.kind.title) \(rule.name) 规则")
              }
            }
          }
        }
      }.formStyle(.grouped).scrollContentBackground(.hidden)
        .padding(.horizontal, 30).padding(.top, 16).padding(.bottom, 24)
    }
    .task { directory.loadIfNeeded(service: model.service) }
    .onDisappear { directory.cancel() }
    .onChange(of: parentID) { _, _ in childID = nil; message = nil }
    .onChange(of: kind) { _, _ in message = nil }
  }

  @ViewBuilder private var partitionEditor: some View {
    if kind == .primaryPartition || kind == .subpartition {
      Picker("一级分区", selection: $parentID) {
        Text("请选择一级分区").tag(Int?.none)
        ForEach(directory.partitions, id: \.id) { partition in
          Text(partition.title).tag(Optional(partition.id))
        }
      }
      if kind == .subpartition {
        Picker("二级分区", selection: $childID) {
          Text("请选择二级分区").tag(Int?.none)
          ForEach(parent?.children ?? [], id: \.id) { child in
            Text(child.title).tag(Optional(child.id))
          }
        }.disabled(parentID == nil)
      }
      if directory.isLoading && directory.partitions.isEmpty {
        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在加载分区…").foregroundStyle(.secondary) }
      }
    }
  }

  @ViewBuilder private var authorEditor: some View {
    if kind == .author {
      TextField("UP 主 UID", text: $authorID, prompt: Text("例如 208259")).labelsHidden()
      TextField("显示名称（可选）", text: $authorName, prompt: Text("留空显示为 UID")).labelsHidden()
    }
  }

  private var parent: VideoPartition? { directory.partitions.first { $0.id == parentID } }

  private var canAdd: Bool {
    switch kind {
    case .primaryPartition: parentID != nil
    case .subpartition: childID != nil
    case .author: (Int64(authorID.trimmingCharacters(in: .whitespaces)) ?? 0) > 0
    }
  }

  private func addRule() {
    let name: String
    let id: Int64
    switch kind {
    case .primaryPartition:
      guard let parent, let parentID else { return }
      name = parent.title; id = Int64(parentID)
    case .subpartition:
      guard let childID, let child = parent?.children.first(where: { $0.id == childID }) else { return }
      name = child.title; id = Int64(childID)
    case .author:
      guard let parsed = Int64(authorID.trimmingCharacters(in: .whitespaces)), parsed > 0 else { return }
      id = parsed
      let trimmed = authorName.trimmingCharacters(in: .whitespacesAndNewlines)
      name = trimmed.isEmpty ? "UID \(parsed)" : trimmed
    }
    if store.add(RecommendationFilterRule(kind: kind, valueID: id, name: name)) {
      message = "已添加：\(name)"
      authorID = ""; authorName = ""
    } else {
      message = "这条规则已经存在。"
    }
  }
}
