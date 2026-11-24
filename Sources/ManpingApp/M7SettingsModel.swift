import AppKit
import ManpingCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class M7SettingsModel: ObservableObject {
  @Published private(set) var values: MacSettings
  @Published private(set) var clearing = false
  @Published private(set) var status: String?
  let capabilities: Set<MacSettingKey>
  private let defaults: any PreferencesStore
  private let apply: (MacSettings) -> Void
  private let clearImages: (() async throws -> Void)?
  private let screenshot: (() -> Void)?
  init(
    defaults: any PreferencesStore = PerformanceEnvironment.defaults,
    capabilities: Set<MacSettingKey>,
    apply: @escaping (MacSettings) -> Void,
    clearImageCache: (() async throws -> Void)? = nil, takeScreenshot: (() -> Void)? = nil) {
    self.defaults = defaults; self.capabilities = capabilities
    self.apply = apply; clearImages = clearImageCache; screenshot = takeScreenshot; values = MacSettings.load(from: defaults)
  }
  var canClearImages: Bool { clearImages != nil && !clearing }
  func takeScreenshot() { screenshot?() }
  func reason(_ descriptor: MacSettingDescriptor) -> String? {
    capabilities.contains(descriptor.key) ? nil : "这个功能暂时还不能在 Mac 上使用。"
  }
  /// The one path for preference changes (settings window, player menus, danmaku panel). The
  /// field is merged into what is stored now, so a value saved elsewhere since this model last
  /// read the store is kept rather than overwritten by an old copy.
  func set(_ key: MacSettingKey, _ value: MacSettingValue) {
    guard let merged = MacSettings.committing(key, value, capabilities: capabilities, to: defaults) else {
      status = "此项不可用，或输入值无效。"; return
    }
    values = merged; apply(merged); status = nil
  }
  func reload() { values = MacSettings.load(from: defaults) }
  func exportSettings() {
    do {
      let data = try MacSettingsBackup(settings: MacSettings.load(from: defaults)).encodedData()
      let panel = NSSavePanel()
      panel.allowedContentTypes = [.json]
      panel.canCreateDirectories = true
      let date = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
      panel.nameFieldStringValue = "Manping-Settings-\(date).json"
      panel.message = "只包含非敏感设置，不包含登录信息、AI 密钥、代理密码或自建历史服务器地址。"
      panel.prompt = "导出"
      panel.begin { [weak self] response in
        guard response == .OK, let url = panel.url else { return }
        do { try data.write(to: url, options: .atomic); self?.status = "设置已导出。" }
        catch { self?.status = "导出失败：\(error.localizedDescription)" }
      }
    } catch { status = "导出失败：\(error.localizedDescription)" }
  }
  func importSettings() {
    status = nil
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.message = "导入前会验证整个文件；验证失败时不会更改任何设置。"
    panel.prompt = "导入"
    panel.begin { [weak self] response in
      guard response == .OK, let url = panel.url, let self else { return }
      do {
        let backup = try MacSettingsBackup.read(from: url)
        let entries = backup.settingValues
        guard entries.allSatisfy({ capabilities.contains($0.key) }) else {
          status = "备份包含当前 Mac 版本不支持的设置项；任何设置都未更改。"; return
        }
        // Build and validate the complete batch in memory first. No store write or runtime apply
        // happens until every entry has passed, and keys absent from the backup stay untouched.
        var imported = MacSettings.load(from: defaults)
        for entry in entries {
          guard imported.set(entry.key, entry.value, capabilities: capabilities) else {
            throw MacSettingsBackupError.invalidSettingValue(entry.key.rawValue)
          }
        }
        for entry in entries { imported.save(entry.key, to: defaults) }
        reload(); apply(values)
        status = "已导入 \(entries.count) 项非敏感设置。"
      } catch {
        let message = (error as? LocalizedError)?.errorDescription ?? "文件不是有效的 Manping 设置 JSON。"
        status = "导入失败，未更改任何设置：\(message)"
      }
    }
  }
  func choosePath(_ descriptor: MacSettingDescriptor) {
    guard reason(descriptor) == nil else { return }
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
    if case .executable = descriptor.control { panel.canChooseDirectories = false; panel.canChooseFiles = true }
    else { panel.canChooseDirectories = true; panel.canChooseFiles = false }
    let current = values.text(descriptor.key)
    if current.hasPrefix("/") { panel.directoryURL = URL(fileURLWithPath: current).deletingLastPathComponent() }
    panel.prompt = "选择"
    panel.begin { [weak self] response in
      guard response == .OK, let url = panel.url else { return }
      self?.set(descriptor.key, .text(url.path))
    }
  }
  func openFolder(_ key: MacSettingKey) {
    let path = values.text(key)
    var directory: ObjCBool = false
    guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else {
      status = "目录尚不存在，请先选择一个目录。"; return
    }
    NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
  }
  func clearImageCache() async {
    guard let clearImages, !clearing else { return }
    clearing = true; status = nil
    defer { clearing = false }
    do { try await clearImages(); status = "图片缓存已清除。" }
    catch { status = "清除失败：\(error.localizedDescription)" }
  }
}
