import AppKit
import ManpingCore
import SwiftUI

/// The download queue: saved records, running transfers and their identities. Moved out of
/// AppModel, which still decides what to download from the playing video or episode.
@MainActor final class DownloadCoordinator: ObservableObject {
  @Published var records: [DownloadRecord] = []
  private let service: BiliService
  private let store: DownloadStore?
  private let fixtures: Bool
  /// Shows a failure the way the app shows its other errors.
  private let report: (String) -> Void
  private var tasks: [String: Task<Void, Never>] = [:]
  private var identities: [String: AuthSnapshot] = [:]

  init(service: BiliService, store: DownloadStore?, records: [DownloadRecord] = [], fixtures: Bool,
    report: @escaping (String) -> Void) {
    self.service = service; self.store = store; self.records = records; self.fixtures = fixtures; self.report = report
  }

  /// Saves and starts one task per choice, all into `directory`.
  func launch(_ choices: [(source: String, title: String, options: DownloadOptions)], directory: URL) {
    guard let store else { report("没有可下载的分集。"); return }
    for (source, title, var choice) in choices {
      choice.directory = directory.path
      let record = DownloadRecord(bvid: source, title: title, options: choice, createdAt: Date())
      do { try store.save(record); run(record) } catch { report(error.localizedDescription) }
    }
    records = (try? store.records()) ?? records
  }
  var canSave: Bool { store != nil }
  /// Logout and quitting stop every transfer.
  func cancelAll() { for task in tasks.values { task.cancel() } }
  /// Transfers started under another login stop when the identity changes.
  func cancel(notMatching snapshot: AuthSnapshot) {
    for (id, binding) in identities where !binding.sameIdentity(as: snapshot) { tasks[id]?.cancel() }
  }
  func retry(_ record: DownloadRecord) {
    guard !fixtures, tasks[record.id] == nil, record.state != "complete" else { return }
    guard record.options != nil else { report("旧任务缺少分集与画质信息，请从播放页重新建立任务。"); return }
    run(record)
  }
  private func checkIdentity(_ snapshot: AuthSnapshot) async throws {
    try Task.checkCancellation()
    let current = await service.authSnapshot()
    try Task.checkCancellation()
    guard current.epoch == snapshot.epoch, current.identityRevision == snapshot.identityRevision else { throw CancellationError() }
  }
  private func run(_ record: DownloadRecord) {
    guard let options = record.options, store != nil, tasks[record.id] == nil else { return }
    tasks[record.id] = Task { [self] in
      var current = record
      var mediaPublished = false
      let temporary = AppModel.support.appendingPathComponent("Transfers").appendingPathComponent(record.id)
      let checkpoint = AppModel.support.appendingPathComponent("Completion").appendingPathComponent(record.id + ".json")
      defer { tasks[record.id] = nil; identities[record.id] = nil }
      do {
        if current.state == "attachment_failed" {
          guard !current.output.isEmpty, FileManager.default.fileExists(atPath: current.output) else {
            throw BiliError.dependency("媒体文件已不存在，请重新下载视频。")
          }
          let snapshot = await service.authSnapshot()
          identities[record.id] = snapshot
          current.state = "downloading"; current.progress = 0; current.error = ""; try update(current)
          let directory = URL(fileURLWithPath: options.directory).resolvingSymlinksInPath()
          try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
          try await exportDanmaku(cid: options.cid, directory: directory,
            stem: record.bvid + "-" + String(options.cid ?? 0), snapshot: snapshot)
          current.state = "complete"; current.progress = 1; current.error = ""; try update(current)
          try? FileManager.default.removeItem(at: temporary)
          return
        }
        if let recovered = try await DownloadCompletion.recover(checkpoint: checkpoint) {
          current.state = "complete"; current.progress = 1; current.output = recovered.path
          current.error = "已从完成记录恢复媒体；如需要附加弹幕，请单独导出。"
          try update(current); return
        }
        let snapshot = await service.authSnapshot()
        identities[record.id] = snapshot
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        do { try FileManager.default.createDirectory(at: checkpoint.deletingLastPathComponent(), withIntermediateDirectories: true) }
        catch { throw DownloadFailure.disk(operation: "创建完成记录目录", code: (error as NSError).code) }
        current.state = "downloading"; current.error = ""; try update(current)
        let video: Video
        let manifest: PlaybackManifest?
        if let episodeID = options.episodeID {
          let details = try await service.pgcDetails(PGCSelection(episodeID: episodeID), expectedIdentity: snapshot)
          guard let episode = details.episodes.first(where: { $0.id == episodeID }), episode.cid == options.cid else { throw BiliError.invalidResponse("剧集信息已改变，请重新创建任务。") }
          video = Video(bvid: episode.bvid, title: episode.title, cover: episode.cover, cid: episode.cid, aid: episode.aid)
          manifest = [.video, .audio].contains(options.content) ? try await service.pgcPlayback(episode, quality: options.quality, expectedIdentity: snapshot) : nil
        } else {
          let detail = try await service.detail(record.bvid, expectedIdentity: snapshot)
          video = Video(bvid: detail.bvid, title: detail.title, cover: detail.cover, cid: options.cid ?? detail.cid, aid: detail.aid)
          manifest = [.video, .audio].contains(options.content) ? try await service.playback(video, quality: options.quality, expectedIdentity: snapshot) : nil
        }
        try await checkIdentity(snapshot)
        let directory = URL(fileURLWithPath: options.directory).resolvingSymlinksInPath()
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { throw DownloadFailure.disk(operation: "创建下载目录", code: (error as NSError).code) }
        let stem = record.bvid + "-" + String(options.cid ?? 0)
        var output = directory.appendingPathComponent(stem + ".mp4")
        switch options.content {
        case .video:
          guard let manifest else { throw BiliError.invalidResponse("没有播放地址") }
          let codec: PlaybackCodec = options.codec == .avc ? .h264 : options.codec == .hevc ? .hevc : .av1
          let preferences = PlaybackPreferences(codec: codec, quality: options.quality)
          let choice = try PlaybackSelector.select(manifest, preferences: preferences, supportsHardware: { _ in true })
          let audio = choice.audioURL
          let vFile = try await DownloadWorker.resumeTransfer(request: service.request(choice.videoURL), to: temporary.appendingPathComponent("video.m4s"), identity: "aid:\(video.aid ?? 0):cid:\(video.cid ?? 0):video:\(choice.video.quality):codec:\(choice.video.codecID):bw:\(choice.video.bandwidth)") { progress in Task { @MainActor in self.updateProgress(record.id, progress * 0.8) } }
          try await checkIdentity(snapshot)
          let aFile = try await DownloadWorker.resumeTransfer(request: service.request(audio), to: temporary.appendingPathComponent("audio.m4s"), identity: "aid:\(video.aid ?? 0):cid:\(video.cid ?? 0):audio:\(choice.audio.quality):codec:\(choice.audio.codecID):bw:\(choice.audio.bandwidth)") { progress in Task { @MainActor in self.updateProgress(record.id, 0.8 + progress * 0.15) } }
          try await checkIdentity(snapshot); current.state = "merging"; current.progress = 0.95; try update(current)
          let staged = temporary.appendingPathComponent("output.mp4")
          if FileManager.default.fileExists(atPath: staged.path) { try FileManager.default.removeItem(at: staged) }
          try await DownloadWorker.merge(video: vFile, audio: aFile, output: staged, ffmpeg: AppModel.ffmpeg)
          try await checkIdentity(snapshot)
          output = try await DownloadCompletion.publish(staged: staged, to: output, checkpoint: checkpoint)
          mediaPublished = true
        case .audio:
          guard let audio = manifest?.audio.first else { throw BiliError.invalidResponse("没有可下载的音频。") }
          let file = try await DownloadWorker.resumeTransfer(request: service.request(audio.url), to: temporary.appendingPathComponent("audio.m4a"), identity: "aid:\(video.aid ?? 0):cid:\(video.cid ?? 0):audio:\(audio.quality):codec:\(audio.codecID):bw:\(audio.bandwidth)") { progress in Task { @MainActor in self.updateProgress(record.id, progress) } }
          output = directory.appendingPathComponent(stem + ".m4a")
          try await checkIdentity(snapshot)
          output = try await DownloadCompletion.publish(staged: file, to: output, checkpoint: checkpoint)
          mediaPublished = true
        case .cover:
          guard let cover = video.cover else { throw BiliError.invalidResponse("没有可下载的封面。") }
          let file = try await DownloadWorker.resumeTransfer(request: service.request(ImageCache.secured(cover)), to: temporary.appendingPathComponent("cover"))
          output = directory.appendingPathComponent(stem + "." + (["png", "jpeg", "jpg", "webp", "avif"].contains(cover.pathExtension.lowercased()) ? cover.pathExtension.lowercased() : "jpg"))
          try await checkIdentity(snapshot)
          output = try await DownloadCompletion.publish(staged: file, to: output, checkpoint: checkpoint)
          mediaPublished = true
        case .danmaku:
          guard let cid = video.cid else { throw BiliError.invalidResponse("没有弹幕标识") }
          let xml = try await service.exportDanmakuXML(cid: cid, expectedIdentity: snapshot)
          output = directory.appendingPathComponent(stem + ".xml")
          let staged = temporary.appendingPathComponent("danmaku.xml")
          try xml.write(to: staged, options: .atomic)
          try await checkIdentity(snapshot)
          output = try await DownloadCompletion.publish(staged: staged, to: output, checkpoint: checkpoint)
          mediaPublished = true
        case .subtitle:
          guard let aid = video.aid, let cid = video.cid else { throw BiliError.invalidResponse("没有字幕媒体标识") }
          let tracks = DownloadSubtitleTrack.filtered(try await service.downloadSubtitleTracks(aid: aid, cid: cid, expectedIdentity: snapshot), filterAI: options.filterAISubtitle)
          guard let track = tracks.first(where: { $0.id == options.subtitleID }) ?? tracks.first(where: { $0.language == options.subtitleLanguage }) else {
            throw BiliError.invalidResponse("所选字幕已不可用，请重新选择字幕。")
          }
          let cues = try await service.downloadSubtitleCues(track: track, expectedIdentity: snapshot)
          let language = track.language.range(of: "^[A-Za-z0-9-]{1,32}$", options: .regularExpression) != nil ? track.language : "subtitle"
          output = directory.appendingPathComponent(stem + "-" + language + ".srt")
          let staged = temporary.appendingPathComponent("subtitle.srt")
          try DownloadExport.subtitleSRT(cues).write(to: staged, options: .atomic)
          try await checkIdentity(snapshot)
          output = try await DownloadCompletion.publish(staged: staged, to: output, checkpoint: checkpoint)
          mediaPublished = true
        }
        current.output = output.path
        if options.content == .video, options.includeDanmaku, let cid = video.cid {
          try await exportDanmaku(cid: cid, directory: directory,
            stem: record.bvid + "-" + String(options.cid ?? 0), snapshot: snapshot)
        }
        current.state = "complete"; current.progress = 1; current.output = output.path; try update(current)
        try? FileManager.default.removeItem(at: temporary)
        if FileManager.default.fileExists(atPath: output.path), MacSettings.load(from: PerformanceEnvironment.defaults).bool(.openDownloadFolder) { NSWorkspace.shared.activateFileViewerSelecting([output]) }
      } catch {
        current.state = mediaPublished ? "attachment_failed" : Task.isCancelled || error is CancellationError ? "cancelled" : "failed"
        if mediaPublished { current.progress = 1 }
        current.error = mediaPublished ? "媒体已保存；附加弹幕导出或任务记录失败：" + error.localizedDescription : error.localizedDescription
        do { try update(current) } catch {
          if let index = records.firstIndex(where: { $0.id == current.id }) { records[index] = current }
          report("任务记录写入失败；恢复下载时会校验持久完成记录。")
        }
      }
    }
  }
  private func exportDanmaku(cid: Int64?, directory: URL, stem: String, snapshot: AuthSnapshot) async throws {
    guard let cid else { throw BiliError.invalidResponse("没有弹幕标识") }
    let xml = try await service.exportDanmakuXML(cid: cid, expectedIdentity: snapshot)
    try await checkIdentity(snapshot)
    let destination = directory.appendingPathComponent(stem + ".xml")
    if !FileManager.default.fileExists(atPath: destination.path) {
      try DownloadExport.write(xml, to: destination)
    }
  }
  private func update(_ record: DownloadRecord) throws {
    var value = record
    // 完成时间只写一次：重试或补弹幕再次完成时不覆盖首次完成时刻。
    if value.state == "complete", value.completedAt == nil { value.completedAt = Date() }
    try store?.save(value)
    records = try store?.records() ?? []
  }
  /// Progress callbacks arrive per network packet; publish at most every half percent so a
  /// running download does not re-render the whole app (and close menus) hundreds of times a second.
  private func updateProgress(_ id: String, _ progress: Double) {
    if let index = records.firstIndex(where: { $0.id == id && $0.state == "downloading" }),
      progress - records[index].progress >= 0.005 || progress >= 1 {
      records[index].progress = progress
    }
  }
  private static func isActive(_ state: String) -> Bool {
    ["queued", "downloading", "merging"].contains(state)
  }
  var hasFinishedRecords: Bool { records.contains { !Self.isActive($0.state) } }
  /// 只删任务记录，磁盘上已下载的文件保持不动。
  func delete(_ record: DownloadRecord) {
    guard !Self.isActive(record.state) else { return }
    tasks[record.id]?.cancel(); tasks[record.id] = nil
    if let store {
      do { try store.delete(id: record.id) } catch { report(error.localizedDescription); return }
    }
    records.removeAll { $0.id == record.id }
  }
  /// 清空所有已结束的记录；进行中的任务不受影响。
  func clearFinished() {
    for record in records where !Self.isActive(record.state) {
      tasks[record.id]?.cancel(); tasks[record.id] = nil
      if let store {
        do { try store.delete(id: record.id) } catch { report(error.localizedDescription); return }
      }
      records.removeAll { $0.id == record.id }
    }
  }
  func cancel(_ id: String) { tasks[id]?.cancel() }
}
