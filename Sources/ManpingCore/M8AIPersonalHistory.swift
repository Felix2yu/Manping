import Foundation

/// The user's own viewing record, shaped for the AI panel. It is a material like
/// any other: shown in the context popover with its size, switchable, and never
/// sent unless a preset asks for it and the user allows that kind.
public struct AIPersonalHistoryDigest: Sendable, Equatable {
  public struct Entry: Sendable, Equatable {
    public let bvid: String
    public let title: String
    public let author: String
    public let watchedOn: String
    public let position: String
    public let finished: Bool
  }

  public let entries: [Entry]
  /// How many records the server offered; `entries` may be shorter after trimming.
  public let total: Int

  /// Twenty rows is roughly 600 tokens: enough for the model to notice a topic or
  /// an uploader, small enough not to crowd out the video itself.
  public static func make(_ items: [ArchiveVideo], limit: Int = 20) -> AIPersonalHistoryDigest? {
    let playable = items.filter { $0.isPlayable && !$0.title.isEmpty }
    guard !playable.isEmpty else { return nil }
    let date = DateFormatter()
    date.locale = Locale(identifier: "zh_CN")
    date.timeZone = TimeZone(identifier: "Asia/Shanghai")
    date.dateFormat = "yyyy-MM-dd"

    let entries = playable.prefix(limit).map { item -> Entry in
      let position: String
      if item.finished {
        position = "已看完"
      } else if item.duration > 0, item.progress > 0 {
        position = "看到 \(AITimecode.format(Double(item.progress)))（\(Int((item.fraction * 100).rounded()))%）"
      } else {
        position = "看过"
      }
      return Entry(bvid: item.bvid, title: item.title, author: item.author,
        watchedOn: date.string(from: Date(timeIntervalSince1970: TimeInterval(item.viewAt))),
        position: position, finished: item.finished)
    }
    return AIPersonalHistoryDigest(entries: entries, total: playable.count)
  }

  public func render() -> String {
    let header = "以下是我自己 bili-history 里最近看过的视频，共 \(total) 条，按观看时间从新到旧；时间是观看日期，不是发布时间。"
    let rows = entries.map { entry in
      "- \(entry.watchedOn) 《\(entry.title)》UP：\(entry.author.isEmpty ? "未知" : entry.author) · \(entry.position)"
    }
    return ([header] + rows).joined(separator: "\n")
  }
}
