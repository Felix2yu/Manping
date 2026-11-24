import ManpingCore
import SwiftUI

/// Presentation state for the bookmark editor. Kept separately so opening it does not re-render
/// the control bar on every clock tick.
struct PlaybackBookmarkDraft: Identifiable, Equatable {
  enum Mode: Equatable {
    case add
    case edit(UUID)
    var editID: UUID? {
      if case .edit(let id) = self { return id }
      return nil
    }
  }
  let id = UUID()
  let mode: Mode
  let mediaKey: PlaybackBookmarkMediaKey?
  let time: Double
  var note: String
}

/// One-click add plus an optional note editor. The timestamp stays fixed while the sheet is open.
@MainActor struct PlaybackBookmarkEditor: View {
  @ObservedObject var model: AppModel
  let draft: PlaybackBookmarkDraft
  let time: Double
  let delete: (() -> Void)?
  let dismiss: () -> Void
  var currentTime: (() -> Double)? = nil
  @State private var note = ""
  @State private var timeText = ""
  @State private var editingSeconds: Double?
  @State private var currentSeconds: Double?
  @State private var error: String?
  @FocusState private var focused: Bool

  private var isEditing: Bool {
    if case .edit = draft.mode { return true }
    return false
  }
  private var matchesCurrentMedia: Bool {
    guard let mediaKey else { return false }
    return mediaKey == model.playbackBookmarkMediaKey
  }
  private var title: String { isEditing ? "编辑书签" : "添加书签" }
  private var timeBinding: Binding<String> {
    Binding {
      timeText
    } set: { value in
      timeText = value
      editingSeconds = nil
      currentSeconds = nil
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 5) {
        Text(title).font(Theme.Font.headline)
        Text("书签和笔记仅保存在这台设备上。").font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(.light))
      }
      HStack(spacing: 10) {
        Text("时间点").font(Theme.Font.body)
        TextField("00:00", text: timeBinding).textFieldStyle(AppTextFieldStyle()).frame(width: 110)
          .focused($focused)
        Spacer()
        Button("使用当前时间") {
          let seconds = currentTime?() ?? model.currentBookmarkTime
          currentSeconds = seconds
          editingSeconds = nil
          timeText = PlaybackTimeline.format(seconds)
        }
        .buttonStyle(AppButtonStyle(size: .small))
      }
      VStack(alignment: .leading, spacing: 7) {
        HStack {
          Text("笔记（可选）").font(Theme.Font.body)
          Spacer()
          Text("\(note.count)/\(PlaybackBookmark.maximumNoteLength)")
            .font(Theme.Font.caption2.monospacedDigit()).foregroundStyle(Theme.tertiaryText(.light))
        }
        TextEditor(text: $note).font(Theme.Font.body).scrollContentBackground(.hidden)
          .frame(minHeight: 110, maxHeight: 180)
          .padding(8).background(Theme.fill(.light), in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
          .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm).strokeBorder(Theme.separator(.light), lineWidth: 0.5))
          .accessibilityLabel("书签笔记")
      }
      if let error {
        Text(error).font(Theme.Font.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
      }
      HStack(spacing: 10) {
        if let delete {
          Button("删除", role: .destructive) {
            delete(); dismiss()
          }.buttonStyle(AppButtonStyle(size: .small))
        }
        Spacer()
        Button("取消", action: dismiss).buttonStyle(AppButtonStyle(size: .small))
        Button(isEditing ? "保存修改" : "添加书签", action: save)
          .buttonStyle(AppButtonStyle(role: .primary, size: .small))
          .disabled(!matchesCurrentMedia)
      }
    }
    .padding(20).frame(width: 440)
    .background(Theme.background(.light))
    .onAppear {
      note = draft.note
      editingSeconds = nil
      currentSeconds = nil
      timeText = PlaybackTimeline.format(time)
      focused = draft.note.isEmpty
    }
  }

  private func save() {
    guard matchesCurrentMedia, let parsed = Self.parse(timeText) else {
      error = matchesCurrentMedia ? "请输入有效的时间，例如 01:23 或 1:02:03。" : "播放内容已切换，请关闭后重新添加书签。"
      return
    }
    let seconds: Double
    if let currentSeconds, timeText == PlaybackTimeline.format(currentSeconds) {
      seconds = currentSeconds
    } else if timeText == PlaybackTimeline.format(draft.time) {
      seconds = draft.time
    } else {
      seconds = parsed
    }
    if isEditing, editingSeconds == nil, abs(seconds - draft.time) >= 0.001 {
      editingSeconds = seconds
      error = "时间点已改变。再次点击「保存修改」即可保存。"
      return
    }
    if isEditing, let confirmed = editingSeconds, abs(seconds - confirmed) >= 0.001 {
      editingSeconds = seconds
      error = "时间点又改变了。请再次确认。"
      return
    }
    do {
      switch draft.mode {
      case .add:
        _ = try model.addPlaybackBookmark(at: seconds, note: note)
      case .edit(let id):
        _ = try model.updatePlaybackBookmark(id: id, time: seconds, note: note)
      }
      dismiss()
    } catch {
      self.error = error.localizedDescription
    }
  }

  static func parse(_ text: String) -> Double? {
    let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
    guard (1...3).contains(parts.count) else { return nil }
    let values = parts.compactMap { Int32($0) }
    guard values.count == parts.count, values.allSatisfy({ $0 >= 0 }), values.dropFirst().allSatisfy({ $0 < 60 }) else { return nil }
    let seconds: Double
    switch values.count {
    case 1: seconds = Double(values[0])
    case 2: seconds = Double(values[0]) * 60 + Double(values[1])
    default: seconds = Double(values[0]) * 3600 + Double(values[1]) * 60 + Double(values[2])
    }
    return seconds.isFinite && seconds >= 0 ? seconds : nil
  }
}

@MainActor struct PlaybackBookmarkNotice: View {
  @ObservedObject var model: AppModel

  var body: some View {
    if let notice = model.bookmarkNotice {
      HStack(spacing: 6) {
        Image(systemName: "bookmark.fill").font(.system(size: 11))
        Text(notice).font(Theme.Font.caption).lineLimit(2)
        Spacer(minLength: 6)
        Button { model.dismissPlaybackBookmarkNotice() } label: { Image(systemName: "xmark") }
          .buttonStyle(PlayerControlButtonStyle(size: 22)).help("关闭").accessibilityLabel("关闭书签提示")
      }.foregroundStyle(.white.opacity(0.8)).frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

/// Bookmark section shared by the chapter popover and the information sidebar. It remains useful
/// on videos without Bilibili chapters and never mixes with AI citations.
@MainActor struct PlaybackBookmarkList: View {
  @ObservedObject var model: AppModel
  @ObservedObject var clock: PlaybackClock
  var override: Double? = nil
  var compact = false
  let seek: (Double) -> Void
  @State private var draft: PlaybackBookmarkDraft?
  @Environment(\.colorScheme) private var scheme

  private var time: Double { override ?? clock.time }
  private var bookmarks: [PlaybackBookmark] { model.bookmarksForCurrentMedia }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Label("我的书签", systemImage: "bookmark.fill")
          .font(Theme.Font.headline).foregroundStyle(Theme.accentText(scheme))
        Spacer()
        Button {
          draft = PlaybackBookmarkDraft(
            mode: .add, mediaKey: model.playbackBookmarkMediaKey, time: time, note: "")
        } label: {
          Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
        }
        .buttonStyle(AppButtonStyle(size: .small)).help("在当前时间添加书签").accessibilityLabel("添加书签")
        .disabled(model.playbackBookmarkMediaKey == nil)
      }
      Button("在当前时间添加书签") {
        do { _ = try model.addPlaybackBookmark(at: time) }
        catch { model.bookmarkNotice = error.localizedDescription }
      }
      .buttonStyle(AppButtonStyle(size: .small)).disabled(model.playbackBookmarkMediaKey == nil)
      if bookmarks.isEmpty {
        Text("还没有书签。在「更多」中添加时间点和笔记。")
          .font(Theme.Font.caption).foregroundStyle(Theme.tertiaryText(scheme))
          .fixedSize(horizontal: false, vertical: true)
      } else {
        ForEach(bookmarks) { bookmark in row(bookmark) }
      }
    }
    .sheet(item: $draft) { editor in
      let bookmark = editor.mode.editID.flatMap { id in bookmarks.first { $0.id == id } }
      PlaybackBookmarkEditor(
        model: model, draft: editor, time: editor.time,
        delete: bookmark.map { item in { model.deletePlaybackBookmark(item) } },
        dismiss: { draft = nil }, currentTime: { time }
      )
    }
  }

  private func row(_ bookmark: PlaybackBookmark) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Button { seek(bookmark.time) } label: {
        HStack(alignment: .top, spacing: 10) {
          Image(systemName: "bookmark.fill").font(.system(size: 10)).foregroundStyle(Theme.accentText(scheme))
            .padding(.top, 3)
          VStack(alignment: .leading, spacing: 3) {
            Text(PlaybackTimeline.format(bookmark.time)).font(Theme.Font.caption.monospacedDigit())
              .foregroundStyle(Theme.secondaryText(scheme))
            if !bookmark.note.isEmpty {
              Text(bookmark.note).font(Theme.Font.body).lineLimit(compact ? 2 : nil)
                .foregroundStyle(Theme.text(scheme)).multilineTextAlignment(.leading)
                .textSelection(.enabled)
            } else {
              Text("书签").font(Theme.Font.body).foregroundStyle(Theme.tertiaryText(scheme))
            }
          }
          Spacer(minLength: 0)
        }.padding(.horizontal, 10).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
      }
      .buttonStyle(SidebarRowStyle(selected: abs(time - bookmark.time) < 1))
      .help("跳转到 \(PlaybackTimeline.format(bookmark.time))")
      .accessibilityLabel("书签 \(PlaybackTimeline.format(bookmark.time))" + (bookmark.note.isEmpty ? "" : "，\(bookmark.note)"))
      HStack(spacing: 2) {
        Button {
          draft = PlaybackBookmarkDraft(
            mode: .edit(bookmark.id), mediaKey: bookmark.mediaKey,
            time: bookmark.time, note: bookmark.note)
        } label: { Image(systemName: "pencil") }
          .buttonStyle(AppButtonStyle(size: .small)).help("编辑书签").accessibilityLabel("编辑书签")
        Button { model.deletePlaybackBookmark(bookmark) } label: { Image(systemName: "trash") }
          .buttonStyle(AppButtonStyle(size: .small)).help("删除书签").accessibilityLabel("删除书签")
      }.padding(.top, 4)
    }
  }
}

/// Compact host for the chapter popover; shows bookmarks even when the media has no chapters.
@MainActor struct PlaybackChapterAndBookmarkList: View {
  @ObservedObject var model: AppModel
  @ObservedObject var clock: PlaybackClock
  let chapters: [PlaybackChapter]
  var override: Double? = nil
  let seek: (Double) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      if !chapters.isEmpty {
        PlaybackChapterList(clock: clock, chapters: chapters, override: override, seek: seek)
      }
      PlaybackBookmarkList(model: model, clock: clock, override: override, compact: true, seek: seek)
    }.padding(14)
  }
}
